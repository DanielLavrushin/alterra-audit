-- The HUD overlay: a vertical list of collapsible group sections. Each
-- group has a header row (top item icon + label + total count + state
-- indicator) and up to ROW_POOL_PER_GROUP item rows beneath it.
--
-- Collapse: M.toggle_group(key) flips the per-group expanded/collapsed
-- state and re-renders immediately. main.lua wires Ctrl+1..5 to call it
-- for the keys in Config.GROUP_ORDER. We do NOT use clickable UMG.Buttons:
-- constructing UButton from scratch via StaticConstructObject leaves its
-- WidgetStyle brushes uninitialised and the engine crashes on render.
--
-- The root widget uses SelfHitTestInvisible so the overlay never grabs
-- input from gameplay.
--
-- Public API:
--   tick(enabled)        — run one poll cycle; hides HUD when disabled
--   hide_overlay()       — explicit hide, used by the keybind / "off" cmd
--   rebuild()            — wipe and re-create the widget (for "rebuild")
--   toggle_group(key)    — collapse/expand a single group by name
--   status() -> shown, has_widget, n_rows_total

local Config = require("config")
local U      = require("util")
local Base   = require("base")

local M = {}

local UI = {
    widget   = nil,
    canvas   = nil,
    vbox     = nil,
    title    = nil,
    info     = nil,
    -- groups[key] = {
    --   button, hbox, header_icon, header_label, header_count, header_caret,
    --   rows = { {hbox, img, txt}, ... },
    --   overflow_row = { hbox, txt },
    -- }
    groups   = nil,
    last_key = nil,
    shown    = false,
}

-- Collapse state survives widget rebuilds and the per-tick render loop.
-- Persisted in-process only. Default is "all collapsed" so the HUD is
-- compact on first sight; the player expands the groups they care about.
local GROUPS_COLLAPSED = {}
for _, key in ipairs(Config.GROUP_ORDER) do
    GROUPS_COLLAPSED[key] = true
end

-- The most recent grouped scan, kept so a header click can re-render
-- immediately without waiting for the next tick.
local LAST_GROUPS       = nil
local LAST_INFO_TEXT    = nil

-- Sweep orphan overlays from a previous Lua reload (the widget survives
-- "Restart All Mods" but Lua loses its reference). Active for the first
-- CLEANUP_DURATION_MS after module load.
local CLEANUP_DEADLINE_MS = U.now_ms() + Config.CLEANUP_DURATION_MS

local function widget_is_ours(w)
    if not U.is_valid(w) then return false end
    local n = U.try(function() return w:GetName() end)
        or  U.try(function() return w:GetFName():ToString() end)
    if not n then return false end
    return string.sub(n, 1, #Config.WIDGET_NAME_PREFIX) == Config.WIDGET_NAME_PREFIX
end

local function destroy_widget(w)
    if not U.is_valid(w) then return end
    pcall(function() w:SetVisibility(Config.VIS_COLLAPSED) end)
    pcall(function() w:RemoveFromParent() end)
    pcall(function() w:RemoveFromViewport() end)
end

local function cleanup_orphan_overlays()
    if not U.world_is_ready() then return end
    local widgets = U.try(function() return FindAllOf("UserWidget") end)
    if not widgets then return end
    for _, w in pairs(widgets) do
        if U.is_valid(w) and w ~= UI.widget and widget_is_ours(w) then
            destroy_widget(w)
        end
    end
end

-- EVerticalAlignment: Fill=0, Top=1, Center=2, Bottom=3
local VALIGN_CENTER = 2

-- Forward declarations so the toggle handler can call render without a
-- dependency cycle in declaration order.
local render_layout

-- Public: flip the collapse state of a single group key and re-render
-- without waiting for the next tick. Called by toggle_hovered_group when
-- the player clicks a group header in inventory mode.
-- Calling with an unknown key is a no-op.
function M.toggle_group(key)
    if not key then return end
    GROUPS_COLLAPSED[key] = not GROUPS_COLLAPSED[key]
    UI.last_key = nil
    if LAST_GROUPS then
        render_layout(LAST_GROUPS, LAST_INFO_TEXT)
    end
end

-- Public: called by main.lua on every left-mouse-button press. Walks the
-- group headers and toggles the one currently under the cursor, if any.
-- Widget:IsHovered() returns false when no cursor exists, so during normal
-- gameplay (camera-locked mouse) this is a fast no-op — we never toggle on
-- attack/interact clicks because the cursor isn't visually present.
function M.toggle_hovered_group()
    if not UI.groups or not UI.shown then return end
    for _, key in ipairs(Config.GROUP_ORDER) do
        local s = UI.groups[key]
        if s and U.is_valid(s.header) then
            local hovered = U.try(function() return s.header:IsHovered() end)
            if hovered then
                M.toggle_group(key)
                return
            end
        end
    end
end

-- Construct one group section (header HBox + item row pool). Earlier
-- iterations wrapped the header in a UMG.Button to make it clickable,
-- but constructing UButton via StaticConstructObject leaves its
-- WidgetStyle FSlateBrushes uninitialised and the engine crashes during
-- the first render. We use a plain HorizontalBox now and expose
-- collapse via keybinds (Ctrl+1..5) in main.lua. Future work may revisit
-- clickable headers via UBorder + pointer events.
local function build_group_section(tree, vbox, classes)
    local C_HorizontalBox = classes.hbox
    local C_Image         = classes.img
    local C_TextBlock     = classes.txt

    local hbox = U.try(function() return StaticConstructObject(C_HorizontalBox, tree) end)
    if not U.is_valid(hbox) then return nil end

    local hbox_slot = U.try(function() return vbox:AddChildToVerticalBox(hbox) end)
    if U.is_valid(hbox_slot) then
        pcall(function() hbox_slot:SetPadding({ Left = 0, Top = Config.GROUP_GAP_PX,
                                                Right = 0, Bottom = 0 }) end)
    end
    pcall(function() hbox:SetVisibility(Config.VIS_COLLAPSED) end)

    local function add_image()
        local img = U.try(function() return StaticConstructObject(C_Image, tree) end)
        if not U.is_valid(img) then return nil end
        local sl = U.try(function() return hbox:AddChildToHorizontalBox(img) end)
        if U.is_valid(sl) then
            pcall(function() sl:SetPadding({ Left = 0, Top = 0,
                                             Right = Config.ICON_GAP_PX, Bottom = 0 }) end)
            pcall(function() sl:SetVerticalAlignment(VALIGN_CENTER) end)
        end
        pcall(function() img:SetDesiredSizeOverride({ X = Config.HEADER_ICON_SIZE, Y = Config.HEADER_ICON_SIZE }) end)
        return img
    end

    local function add_text(color, size)
        local txt = U.try(function() return StaticConstructObject(C_TextBlock, tree) end)
        if not U.is_valid(txt) then return nil end
        local sl = U.try(function() return hbox:AddChildToHorizontalBox(txt) end)
        if U.is_valid(sl) then
            pcall(function() sl:SetPadding({ Left = 0, Top = 0,
                                             Right = Config.ICON_GAP_PX, Bottom = 0 }) end)
            pcall(function() sl:SetVerticalAlignment(VALIGN_CENTER) end)
        end
        pcall(function() txt:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end)
        pcall(function()
            local f = txt.Font
            if f then f.Size = size; txt.Font = f end
        end)
        return txt
    end

    local section = {
        header       = hbox,
        header_icon  = add_image(),
        header_label = add_text(Config.GROUP_LABEL_COLOR, Config.HEADER_TEXT_SIZE),
        header_count = add_text(Config.TEXT_COLOR,        Config.HEADER_TEXT_SIZE),
        header_caret = add_text(Config.DIM_COLOR,         Config.HEADER_TEXT_SIZE),
        rows         = {},
    }

    -- Item-row pool — siblings of the button in the parent vbox, so
    -- they sit visually beneath the header. Collapse hides all of them.
    for _ = 1, Config.ROW_POOL_PER_GROUP do
        local row = U.try(function() return StaticConstructObject(C_HorizontalBox, tree) end)
        if not U.is_valid(row) then break end
        local row_slot = U.try(function() return vbox:AddChildToVerticalBox(row) end)
        if U.is_valid(row_slot) then
            pcall(function() row_slot:SetPadding({ Left = Config.HEADER_ICON_SIZE,
                                                   Top = Config.ROW_GAP_PX,
                                                   Right = 0, Bottom = Config.ROW_GAP_PX }) end)
        end
        pcall(function() row:SetVisibility(Config.VIS_COLLAPSED) end)

        local img = U.try(function() return StaticConstructObject(C_Image, tree) end)
        if U.is_valid(img) then
            local img_slot = U.try(function() return row:AddChildToHorizontalBox(img) end)
            if U.is_valid(img_slot) then
                pcall(function() img_slot:SetPadding({ Left = 0, Top = 0,
                                                       Right = Config.ICON_GAP_PX, Bottom = 0 }) end)
                pcall(function() img_slot:SetVerticalAlignment(VALIGN_CENTER) end)
            end
            pcall(function() img:SetDesiredSizeOverride({ X = Config.ICON_SIZE, Y = Config.ICON_SIZE }) end)
        end

        local txt = U.try(function() return StaticConstructObject(C_TextBlock, tree) end)
        if U.is_valid(txt) then
            local txt_slot = U.try(function() return row:AddChildToHorizontalBox(txt) end)
            if U.is_valid(txt_slot) then
                pcall(function() txt_slot:SetVerticalAlignment(VALIGN_CENTER) end)
            end
            pcall(function() txt:SetColorAndOpacity({ SpecifiedColor = Config.TEXT_COLOR, ColorUseRule = 0 }) end)
            pcall(function()
                local f = txt.Font
                if f then f.Size = Config.TEXT_SIZE; txt.Font = f end
            end)
        end

        table.insert(section.rows, { hbox = row, img = img, txt = txt })
    end

    -- One overflow row at the bottom for "+ N more".
    local ovr = U.try(function() return StaticConstructObject(C_HorizontalBox, tree) end)
    if U.is_valid(ovr) then
        local sl = U.try(function() return vbox:AddChildToVerticalBox(ovr) end)
        if U.is_valid(sl) then
            pcall(function() sl:SetPadding({ Left = Config.HEADER_ICON_SIZE,
                                             Top = Config.ROW_GAP_PX,
                                             Right = 0, Bottom = Config.ROW_GAP_PX }) end)
        end
        pcall(function() ovr:SetVisibility(Config.VIS_COLLAPSED) end)
        local txt = U.try(function() return StaticConstructObject(C_TextBlock, tree) end)
        if U.is_valid(txt) then
            pcall(function() ovr:AddChildToHorizontalBox(txt) end)
            pcall(function() txt:SetColorAndOpacity({ SpecifiedColor = Config.DIM_COLOR, ColorUseRule = 0 }) end)
            pcall(function()
                local f = txt.Font
                if f then f.Size = Config.TEXT_SIZE; txt.Font = f end
            end)
        end
        section.overflow_row = { hbox = ovr, txt = txt }
    end

    return section
end

local function build_overlay()
    if U.is_valid(UI.widget) then return true end

    local C_UserWidget    = U.try(function() return StaticFindObject("/Script/UMG.UserWidget")    end)
    local C_WidgetTree    = U.try(function() return StaticFindObject("/Script/UMG.WidgetTree")    end)
    local C_CanvasPanel   = U.try(function() return StaticFindObject("/Script/UMG.CanvasPanel")   end)
    local C_VerticalBox   = U.try(function() return StaticFindObject("/Script/UMG.VerticalBox")   end)
    local C_HorizontalBox = U.try(function() return StaticFindObject("/Script/UMG.HorizontalBox") end)
    local C_Image         = U.try(function() return StaticFindObject("/Script/UMG.Image")         end)
    local C_TextBlock     = U.try(function() return StaticFindObject("/Script/UMG.TextBlock")     end)
    if not (U.is_valid(C_UserWidget) and U.is_valid(C_WidgetTree)
            and U.is_valid(C_CanvasPanel) and U.is_valid(C_VerticalBox)
            and U.is_valid(C_HorizontalBox) and U.is_valid(C_Image)
            and U.is_valid(C_TextBlock)) then
        U.logf("UMG classes not loaded yet")
        return false
    end

    local pc = U.get_pc()
    if not U.is_valid(pc) then return false end

    local widget
    local lib = U.try(function() return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary") end)
    if U.is_valid(lib) then
        widget = U.try(function() return lib:Create(pc, C_UserWidget, pc) end)
    end
    if not U.is_valid(widget) then
        widget = U.try(function() return StaticConstructObject(C_UserWidget, pc) end)
    end
    if not U.is_valid(widget) then return false end

    pcall(function() widget:Rename(Config.WIDGET_NAME_PREFIX) end)

    local tree = U.try(function() return StaticConstructObject(C_WidgetTree, widget) end)
    if not U.is_valid(tree) then return false end
    pcall(function() widget.WidgetTree = tree end)

    local canvas = U.try(function() return StaticConstructObject(C_CanvasPanel, tree) end)
    if not U.is_valid(canvas) then return false end
    pcall(function() tree.RootWidget = canvas end)

    local vbox = U.try(function() return StaticConstructObject(C_VerticalBox, tree) end)
    if not U.is_valid(vbox) then return false end

    local right_side = (Config.HUD_SIDE == "right")
    local anchor_x   = right_side and 1.0 or 0.0
    local align_x    = right_side and 1.0 or 0.0
    local pos_x      = right_side and -Config.MARGIN_X or Config.MARGIN_X

    local slot = U.try(function() return canvas:AddChild(vbox) end)
    if U.is_valid(slot) then
        pcall(function() slot:SetAnchors({ Minimum = { X = anchor_x, Y = 0.0 },
                                           Maximum = { X = anchor_x, Y = 0.0 } }) end)
        pcall(function() slot:SetAlignment({ X = align_x, Y = 0.0 }) end)
        pcall(function() slot:SetAutoSize(true) end)
        pcall(function() slot:SetPosition({ X = pos_x, Y = Config.MARGIN_Y }) end)
    end

    UI.widget = widget
    UI.canvas = canvas
    UI.vbox   = vbox

    if Config.SHOW_HEADER then
        local function add_text(color)
            local txt = U.try(function() return StaticConstructObject(C_TextBlock, tree) end)
            if not U.is_valid(txt) then return nil end
            pcall(function() vbox:AddChildToVerticalBox(txt) end)
            pcall(function() txt:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end)
            return txt
        end
        UI.title = add_text(Config.TITLE_COLOR)
        UI.info  = add_text(Config.DIM_COLOR)
        if U.is_valid(UI.title) then
            pcall(function() UI.title:SetText(FText(Config.TITLE)) end)
        end
    end

    local classes = {
        hbox = C_HorizontalBox,
        img  = C_Image,
        txt  = C_TextBlock,
    }
    UI.groups = {}
    for _, key in ipairs(Config.GROUP_ORDER) do
        UI.groups[key] = build_group_section(tree, vbox, classes)
    end

    pcall(function() widget:AddToViewport(1000) end)
    -- Root visible-but-not-hit-testable so gameplay input passes through.
    -- Group headers don't grab input themselves (collapse is via keybind).
    pcall(function() widget:SetVisibility(Config.VIS_ROOT) end)
    return true
end

-- Bucket totals into ordered groups, sort items within each by count desc,
-- and pick a top item per group for the header icon.
local function build_groups(totals, locker_count)
    local buckets = {}
    for _, key in ipairs(Config.GROUP_ORDER) do
        buckets[key] = { key = key, label = key, total = 0, items = {} }
    end

    local other_bucket = nil
    for _, e in pairs(totals) do
        local key = e.group or "Crafted"
        local b = buckets[key]
        if not b then
            other_bucket = other_bucket or { key = "Other", label = "Other", total = 0, items = {} }
            b = other_bucket
        end
        b.total = b.total + e.count
        table.insert(b.items, { name = e.name, count = e.count, type = e.type })
    end

    local groups = {}
    for _, key in ipairs(Config.GROUP_ORDER) do
        if #buckets[key].items > 0 then table.insert(groups, buckets[key]) end
    end
    if other_bucket and #other_bucket.items > 0 then
        table.insert(groups, other_bucket)
    end

    for _, g in ipairs(groups) do
        table.sort(g.items, function(a, b)
            if a.count ~= b.count then return a.count > b.count end
            return (a.name or "") < (b.name or "")
        end)
        g.top_item = g.items[1]
    end

    local total_types, total_count = 0, 0
    for _, g in ipairs(groups) do
        total_types = total_types + #g.items
        total_count = total_count + g.total
    end
    local info
    if total_types == 0 then
        info = string.format("%d locker%s · 0 items",
            locker_count, locker_count == 1 and "" or "s")
    else
        info = string.format("%d locker%s · %d type%s · %d total",
            locker_count, locker_count == 1 and "" or "s",
            total_types, total_types == 1 and "" or "s",
            total_count)
    end
    return groups, info
end

local function hide_overlay()
    if not U.is_valid(UI.widget) then return end
    if UI.shown then
        pcall(function() UI.widget:SetVisibility(Config.VIS_COLLAPSED) end)
        UI.shown = false
        UI.last_key  = nil
    end
end
M.hide_overlay = hide_overlay

-- Cache key includes collapse state so a header click triggers a redraw.
local function items_key(groups)
    local parts = {}
    for _, g in ipairs(groups) do
        parts[#parts + 1] = g.key
        parts[#parts + 1] = tostring(g.total)
        parts[#parts + 1] = GROUPS_COLLAPSED[g.key] and "c" or "o"
        for i = 1, math.min(#g.items, Config.ROW_POOL_PER_GROUP) do
            parts[#parts + 1] = g.items[i].name .. ":" .. tostring(g.items[i].count)
        end
        if #g.items > Config.ROW_POOL_PER_GROUP then
            parts[#parts + 1] = "+" .. tostring(#g.items - Config.ROW_POOL_PER_GROUP)
        end
    end
    return table.concat(parts, "|")
end

local function set_image_thumb(img, item_type)
    if not U.is_valid(img) or not item_type then return end
    local thumb = U.try(function() return item_type.Thumbnail end)
    if thumb then
        pcall(function() img:SetBrushFromSoftTexture(thumb, false) end)
    end
end

-- Definition of the forward-declared render_layout. Updates all group
-- sections in place based on the supplied groups data and the live
-- GROUPS_COLLAPSED state.
render_layout = function(groups, info_text)
    if not U.is_valid(UI.widget) or not UI.groups then return end

    if not UI.shown then
        pcall(function() UI.widget:SetVisibility(Config.VIS_ROOT) end)
        UI.shown = true
    end

    if Config.SHOW_HEADER and info_text and U.is_valid(UI.info) then
        pcall(function() UI.info:SetText(FText(info_text)) end)
    end

    -- First pass: hide everything. Second pass: show what we need.
    for _, key in ipairs(Config.GROUP_ORDER) do
        local s = UI.groups[key]
        if s then
            pcall(function() s.header:SetVisibility(Config.VIS_COLLAPSED) end)
            for _, row in ipairs(s.rows) do
                pcall(function() row.hbox:SetVisibility(Config.VIS_COLLAPSED) end)
            end
            if s.overflow_row then
                pcall(function() s.overflow_row.hbox:SetVisibility(Config.VIS_COLLAPSED) end)
            end
        end
    end

    for _, g in ipairs(groups) do
        local s = UI.groups[g.key]
        if s and U.is_valid(s.header) then
            -- Header is Visible (not HitTestInvisible) so IsHovered() can
            -- detect the cursor for click-to-collapse. Item rows stay
            -- HitTestInvisible since they aren't click targets.
            pcall(function() s.header:SetVisibility(Config.VIS_CLICKABLE) end)
            set_image_thumb(s.header_icon, g.top_item and g.top_item.type)
            if U.is_valid(s.header_label) then
                pcall(function() s.header_label:SetText(FText(g.label)) end)
            end
            if U.is_valid(s.header_count) then
                pcall(function() s.header_count:SetText(FText(string.format("(%d)", g.total))) end)
            end
            local collapsed = GROUPS_COLLAPSED[g.key]
            if U.is_valid(s.header_caret) then
                pcall(function() s.header_caret:SetText(FText(collapsed and "[+]" or "[-]")) end)
            end

            if not collapsed then
                local n = math.min(#g.items, Config.ROW_POOL_PER_GROUP)
                for i = 1, n do
                    local row, item = s.rows[i], g.items[i]
                    if row and U.is_valid(row.hbox) then
                        pcall(function() row.hbox:SetVisibility(Config.VIS_DRAW) end)
                        if U.is_valid(row.img) then
                            pcall(function() row.img:SetVisibility(Config.VIS_DRAW) end)
                            set_image_thumb(row.img, item.type)
                            pcall(function() row.img:SetDesiredSizeOverride({ X = Config.ICON_SIZE, Y = Config.ICON_SIZE }) end)
                        end
                        if U.is_valid(row.txt) then
                            pcall(function() row.txt:SetText(FText("x " .. tostring(item.count))) end)
                        end
                    end
                end
                local extra = #g.items - n
                if extra > 0 and s.overflow_row and U.is_valid(s.overflow_row.hbox) then
                    pcall(function() s.overflow_row.hbox:SetVisibility(Config.VIS_DRAW) end)
                    if U.is_valid(s.overflow_row.txt) then
                        pcall(function() s.overflow_row.txt:SetText(FText(string.format("+ %d more", extra))) end)
                    end
                end
            end
        end
    end
end

function M.tick(enabled)
    if not enabled then hide_overlay(); return end
    if not U.world_is_ready() then return end
    if U.now_ms() < CLEANUP_DEADLINE_MS then
        cleanup_orphan_overlays()
    end

    local pawn = U.get_pawn()
    if not U.is_valid(pawn) then hide_overlay(); return end

    local totals, locker_count = Base.scan_lockers(pawn)
    if not totals then hide_overlay(); return end

    if not build_overlay() then return end

    local groups, info = build_groups(totals, locker_count)
    LAST_GROUPS    = groups
    LAST_INFO_TEXT = info

    local key = items_key(groups)
    if key == UI.last_key then return end
    UI.last_key = key

    render_layout(groups, info)
end

function M.rebuild()
    destroy_widget(UI.widget)
    UI = {
        widget = nil, canvas = nil, vbox = nil, title = nil, info = nil,
        groups = nil, last_key = nil, shown = false,
    }
    CLEANUP_DEADLINE_MS = U.now_ms() + Config.CLEANUP_DURATION_MS
    cleanup_orphan_overlays()
end

function M.status()
    local n = 0
    if UI.groups then
        for _, key in ipairs(Config.GROUP_ORDER) do
            local s = UI.groups[key]
            if s and s.rows then n = n + #s.rows end
        end
    end
    return UI.shown, U.is_valid(UI.widget), n
end

return M
