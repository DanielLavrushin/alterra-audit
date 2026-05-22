-- Item-type cache plus the per-locker aggregator.
--
-- Why this is its own module: it owns nontrivial state that's easy to get
-- wrong if duplicated.
--   * ITEM_TYPES_CACHE — full set of UWEItemType instances + their resolved
--     display names. Built lazily, refreshed every CACHE_REFRESH_MS, also
--     invalidated by a NotifyOnNewObject hook.
--   * The localization race fallback (see is_placeholder_name).
--   * CDO filter so generic parent UWEItemType objects don't return
--     aggregate counts that collapse the HUD.
--
-- Public API:
--   ensure_item_types() -> array of { type, name, full, fallback, type_tag, group }
--   aggregate_locker(locker, totals) -> (added_pairs, sum_counts)
--   invalidate()       — force cache rebuild (called on level reload)
--   cache_size()       — current cached entry count

local Config = require("config")
local U      = require("util")

local M = {}

-- Treat unloaded-localization fallbacks as "no name yet" so we drop back
-- to a per-instance FName rather than collapsing many types into one
-- shared bucket.
local function is_placeholder_name(s)
    if not s or s == "" then return true end
    if s == "Unknown" then return true end
    if string.find(s, "^<MISSING") then return true end       -- "<MISSING STRING TABLE ENTRY>"
    if string.find(s, "%[Missing")  then return true end      -- "[Missing localization]" etc.
    return false
end

-- Returns (name, was_fallback). was_fallback=true means localization
-- wasn't loaded yet and we used the per-instance FName as a placeholder.
local function item_name_from_type(item_type)
    if not U.is_valid(item_type) then return nil, false end
    local txt = U.try(function() return item_type.Name end)
    if txt then
        local s = U.try(function() return txt:ToString() end)
        if s and not is_placeholder_name(s) then return s, false end
    end
    local cn = U.try(function() return item_type:GetFName():ToString() end)
    if cn and cn ~= "" then
        cn = string.gsub(cn, "^Default__", "")
        cn = string.gsub(cn, "_C$", "")
        return cn, true
    end
    return "Unknown", true
end

-- Derive a presentation group from a UWEItemType's TypeTag string.
--
-- Empirically (logged via the `audit tags` debug command) all raw resources
-- have TypeTag = "ItemType.<Category>[.<Subtype>]" — e.g. ItemType.Mineral,
-- ItemType.Flora.PlateCoral, ItemType.Fuel (food/consumables), ItemType.Fauna.
-- Crafted/processed items (ingots, wire, glass, medkits, ...) have no
-- TypeTag at all. So: first dotted segment after "ItemType." is the group,
-- and "no tag" means crafted.
--
-- We pretty-print the well-known categories but fall back to the raw segment
-- so new game-side categories appear in the HUD without code changes.
local GROUP_PRETTY = {
    Mineral = "Minerals",
    Flora   = "Flora",
    Fauna   = "Fauna",
    Fuel    = "Fuel",
}

local function group_from_tag(tag)
    if not tag or tag == "" then return "Crafted" end
    local cat = string.match(tag, "^[^%.]+%.([^%.]+)")
    if not cat or cat == "" then return "Crafted" end
    return GROUP_PRETTY[cat] or cat
end

-- Read a single FGameplayTag's TagName as a dotted string (e.g.
-- "ItemType.Mineral"). Returns nil for unset/empty/None tags.
local function read_single_tag(t)
    if t == nil then return nil end
    local name = nil
    pcall(function() name = t.TagName end)
    if not name then return nil end
    local s = nil
    pcall(function() s = name:ToString() end)
    if not s or s == "" or s == "None" then return nil end
    return s
end

-- CDOs (Class Default Objects, named "Default__<ClassName>") can make
-- GetItemCountByType return aggregate counts that match every subclass
-- item, which collapses the HUD to a handful of huge counts. Skip them.
local function is_class_default_object(t)
    local full  = U.try(function() return t:GetFullName() end) or ""
    local fname = U.try(function() return t:GetFName():ToString() end) or ""
    if string.find(fname, "^Default__")    then return true end
    if string.find(full,  ":Default__", 1, true) then return true end
    if string.find(full,  ".Default__", 1, true) then return true end
    return false
end

local ITEM_TYPES_CACHE       = nil
local ITEM_TYPES_CACHE_TS_MS = 0

local function refresh_raw()
    local all = U.try(function() return FindAllOf("UWEItemType") end)
    if not all then return nil end
    local out, seen = {}, {}
    local skipped_cdos, fallback_names = 0, 0
    for _, t in pairs(all) do
        if U.is_valid(t) then
            if is_class_default_object(t) then
                skipped_cdos = skipped_cdos + 1
            else
                local full = U.try(function() return t:GetFullName() end)
                if full and not seen[full] then
                    seen[full] = true
                    local name, was_fallback = item_name_from_type(t)
                    if name and name ~= "" then
                        if was_fallback then fallback_names = fallback_names + 1 end
                        local type_tag = read_single_tag(U.try(function() return t.TypeTag end))
                        table.insert(out, {
                            type     = t,
                            name     = name,
                            full     = full,
                            fallback = was_fallback,
                            type_tag = type_tag,
                            group    = group_from_tag(type_tag),
                        })
                    end
                end
            end
        end
    end
    out._skipped_cdos   = skipped_cdos
    out._fallback_names = fallback_names
    return out
end

function M.ensure_item_types()
    local t = U.now_ms()
    if ITEM_TYPES_CACHE and (t - ITEM_TYPES_CACHE_TS_MS < Config.CACHE_REFRESH_MS) then
        return ITEM_TYPES_CACHE
    end

    local fresh = refresh_raw()
    ITEM_TYPES_CACHE_TS_MS = t
    if not fresh or #fresh == 0 then return ITEM_TYPES_CACHE end

    -- Always adopt the fresh snapshot — even when size is unchanged the
    -- localized Names may have matured (fewer items stuck on the FName
    -- fallback), and we want those better names live as soon as possible.
    local prev_n  = ITEM_TYPES_CACHE and #ITEM_TYPES_CACHE or 0
    local prev_fb = ITEM_TYPES_CACHE and ITEM_TYPES_CACHE._fallback_names or -1
    ITEM_TYPES_CACHE = fresh

    if prev_fb < 0 then
        U.logf("ItemType cache: initial size %d (skipped %d CDOs, %d names using FName fallback)",
            #fresh, fresh._skipped_cdos or 0, fresh._fallback_names or 0)
    elseif #fresh ~= prev_n or (fresh._fallback_names or 0) ~= prev_fb then
        U.logf("ItemType cache: refreshed size %d (fallback names %d -> %d)",
            #fresh, prev_fb, fresh._fallback_names or 0)
    end
    return ITEM_TYPES_CACHE
end

function M.cache_size()
    return ITEM_TYPES_CACHE and #ITEM_TYPES_CACHE or 0
end

-- Have the engine wake us up whenever a new UWEItemType is loaded so we
-- don't have to wait up to CACHE_REFRESH_MS to discover it.
do
    local ok, err = pcall(function()
        NotifyOnNewObject("/Script/UWEInventory.UWEItemType", function(_)
            ITEM_TYPES_CACHE_TS_MS = 0   -- mark stale; next scan will rebuild
        end)
    end)
    if ok then
        U.logf("NotifyOnNewObject(UWEItemType) installed")
    else
        U.logf("NotifyOnNewObject(UWEItemType) failed: %s", tostring(err))
    end
end

-- Force-invalidate the cache. Called on level reload, where any cached
-- UWEItemType references would point to UObjects from the previous level.
function M.invalidate()
    ITEM_TYPES_CACHE       = nil
    ITEM_TYPES_CACHE_TS_MS = 0
end

-- Adds the locker's contents into `totals`, keyed by type FullName so
-- distinct UWEItemType objects never get accidentally bucketed together.
--   totals[full] = { count, type, name }
-- Returns (pairs_added, sum_of_counts).
function M.aggregate_locker(locker, totals)
    local inv = U.try(function() return locker.Inventory end)
    if not U.is_valid(inv) then return 0, 0 end

    local n = U.try(function() return inv:NumItems() end) or 0
    if type(n) ~= "number" or n <= 0 then return 0, 0 end

    local types = M.ensure_item_types()
    if not types then return 0, 0 end

    local added, sum = 0, 0
    for _, e in ipairs(types) do
        local c = U.try(function() return inv:GetItemCountByType(e.type) end)
        if type(c) == "number" and c > 0 then
            local key = e.full or e.name
            local cur = totals[key]
            if not cur then
                cur = { count = 0, type = e.type, name = e.name, group = e.group }
                totals[key] = cur
            end
            cur.count = cur.count + c
            sum   = sum + c
            added = added + 1
        end
    end
    return added, sum
end

return M
