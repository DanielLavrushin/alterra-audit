-- The HUD overlay: a top-left vertical list of (icon, count) rows. The
-- per-tick body lives here too, so that main.lua just wires the modules
-- together and owns the on/off flag.
--
-- Public API:
--   tick(enabled)        — run one poll cycle; hides HUD when disabled
--   hide_overlay()       — explicit hide, used by the keybind / "off" cmd
--   rebuild()            — wipe and re-create the widget (for "rebuild")
--   status() -> shown, has_widget, n_rows

local Config = require("config")
local U      = require("util")
local Base   = require("base")

local M = {}

local UI = {
    widget    = nil,
    canvas    = nil,
    vbox      = nil,
    title     = nil,
    info      = nil,
    rows      = nil,   -- { { hbox, img, txt }, ... }
    last_key  = nil,   -- signature of last rendered item set
    last_info = nil,
    shown     = false,
}

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

    -- Tag the widget so cleanup_orphan_overlays can find it after a Lua
    -- reload (UE appends _N for duplicates).
    pcall(function() widget:Rename(Config.WIDGET_NAME_PREFIX) end)

    local tree = U.try(function() return StaticConstructObject(C_WidgetTree, widget) end)
    if not U.is_valid(tree) then return false end
    pcall(function() widget.WidgetTree = tree end)

    local canvas = U.try(function() return StaticConstructObject(C_CanvasPanel, tree) end)
    if not U.is_valid(canvas) then return false end
    pcall(function() tree.RootWidget = canvas end)

    local vbox = U.try(function() return StaticConstructObject(C_VerticalBox, tree) end)
    if not U.is_valid(vbox) then return false end

    -- Anchor and align so the panel sits at the chosen screen edge. For
    -- right-side: anchor X=1.0 (right edge), alignment X=1.0 (the vbox's
    -- right edge sits at the anchor), position X=-margin (offset inward).
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

    local function add_text(color)
        local txt = U.try(function() return StaticConstructObject(C_TextBlock, tree) end)
        if not U.is_valid(txt) then return nil end
        pcall(function() vbox:AddChildToVerticalBox(txt) end)
        pcall(function() txt:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end)
        return txt
    end

    -- TextBlock.Font is an FSlateFontInfo struct. Mutating its Size in
    -- place and writing back is the standard "shrink the text" trick.
    local function set_text_size(txt, size)
        if not U.is_valid(txt) then return end
        pcall(function()
            local f = txt.Font
            if f then f.Size = size; txt.Font = f end
        end)
    end

    UI.widget = widget
    UI.canvas = canvas
    UI.vbox   = vbox

    if Config.SHOW_HEADER then
        UI.title = add_text(Config.TITLE_COLOR)
        UI.info  = add_text(Config.DIM_COLOR)
        if U.is_valid(UI.title) then
            pcall(function() UI.title:SetText(FText(Config.TITLE)) end)
        end
    end

    UI.rows = {}
    for _ = 1, Config.ROW_POOL do
        local row = U.try(function() return StaticConstructObject(C_HorizontalBox, tree) end)
        if not U.is_valid(row) then break end
        local row_slot = U.try(function() return vbox:AddChildToVerticalBox(row) end)
        if U.is_valid(row_slot) then
            pcall(function() row_slot:SetPadding({ Left = 0, Top = Config.ROW_GAP_PX,
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
            set_text_size(txt, Config.TEXT_SIZE)
        end

        table.insert(UI.rows, { hbox = row, img = img, txt = txt })
    end

    pcall(function() widget:AddToViewport(1000) end)
    pcall(function() widget:SetVisibility(Config.VIS_COLLAPSED) end)
    return true
end

-- totals comes in keyed by type FullName. Collapse types sharing a display
-- name into a single row (pick the highest-count type as the representative
-- for thumbnail purposes), then sort by count desc.
local function build_items_list(totals, locker_count)
    local by_name = {}
    for _, e in pairs(totals) do
        local agg = by_name[e.name]
        if not agg then
            by_name[e.name] = {
                name = e.name, count = e.count, type = e.type, _best = e.count,
            }
        else
            agg.count = agg.count + e.count
            if e.count > agg._best then
                agg._best = e.count
                agg.type  = e.type
            end
        end
    end

    local list = {}
    for _, e in pairs(by_name) do
        table.insert(list, { name = e.name, count = e.count, type = e.type })
    end
    table.sort(list, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)

    local total = 0
    for _, e in ipairs(list) do total = total + e.count end

    local info
    if #list == 0 then
        info = string.format("%d locker%s · 0 items",
            locker_count, locker_count == 1 and "" or "s")
    else
        info = string.format("%d locker%s · %d type%s · %d total",
            locker_count, locker_count == 1 and "" or "s",
            #list, #list == 1 and "" or "s",
            total)
    end
    return list, info
end

local function hide_overlay()
    if not U.is_valid(UI.widget) then return end
    if UI.shown then
        pcall(function() UI.widget:SetVisibility(Config.VIS_COLLAPSED) end)
        UI.shown = false
        UI.last_key  = nil
        UI.last_info = nil
    end
end
M.hide_overlay = hide_overlay

local function items_key(items)
    local n = math.min(#items, Config.ROW_POOL)
    local parts = { tostring(n) }
    for i = 1, n do
        parts[#parts + 1] = items[i].name .. ":" .. tostring(items[i].count)
    end
    return table.concat(parts, "|")
end

local function render_row(row, item)
    if not row or not U.is_valid(row.hbox) then return end
    if U.is_valid(row.img) then
        pcall(function() row.img:SetVisibility(Config.VIS_DRAW) end)
        local thumb = item.type and U.try(function() return item.type.Thumbnail end)
        if thumb then
            pcall(function() row.img:SetBrushFromSoftTexture(thumb, false) end)
            pcall(function() row.img:SetDesiredSizeOverride({ X = Config.ICON_SIZE, Y = Config.ICON_SIZE }) end)
        end
    end
    if U.is_valid(row.txt) then
        pcall(function() row.txt:SetText(FText("x " .. tostring(item.count))) end)
        pcall(function() row.txt:SetColorAndOpacity({ SpecifiedColor = Config.TEXT_COLOR, ColorUseRule = 0 }) end)
    end
    pcall(function() row.hbox:SetVisibility(Config.VIS_DRAW) end)
end

local function clear_row(row)
    if not row or not U.is_valid(row.hbox) then return end
    pcall(function() row.hbox:SetVisibility(Config.VIS_COLLAPSED) end)
end

local function show_overlay(items, info_text)
    if not U.is_valid(UI.widget) then return end
    if not UI.shown then
        pcall(function() UI.widget:SetVisibility(Config.VIS_DRAW) end)
        UI.shown = true
    end

    if Config.SHOW_HEADER and UI.last_info ~= info_text and U.is_valid(UI.info) then
        pcall(function() UI.info:SetText(FText(info_text)) end)
        UI.last_info = info_text
    end

    local key = items_key(items)
    if key == UI.last_key then return end
    UI.last_key = key

    local n = math.min(#items, #(UI.rows or {}))
    for i = 1, n do
        render_row(UI.rows[i], items[i])
    end
    for i = n + 1, #(UI.rows or {}) do
        clear_row(UI.rows[i])
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
    local items, info = build_items_list(totals, locker_count)
    show_overlay(items, info)
end

function M.rebuild()
    destroy_widget(UI.widget)
    UI = {
        widget = nil, canvas = nil, vbox = nil, title = nil, info = nil,
        rows = nil, last_key = nil, last_info = nil, shown = false,
    }
    CLEANUP_DEADLINE_MS = U.now_ms() + Config.CLEANUP_DURATION_MS
    cleanup_orphan_overlays()
end

function M.status()
    return UI.shown, U.is_valid(UI.widget), UI.rows and #UI.rows or 0
end

return M
