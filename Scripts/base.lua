-- Base detection and per-scan locker aggregation.
--
-- Public API:
--   scan_lockers(pawn) -> (totals, locker_count, parsed_pairs)
--     totals[full] = { count, type, name }
--     Returns (nil, 0, 0) when the player isn't recognised as "in a base".
--
-- Detection strategy:
--   1. Find every UWEBaseSupportActor in the world. The one nearest to the
--      player (within SUPPORT_MAX_DIST_M) reveals which base we're in via
--      its .base WeakObjectProperty.
--   2. Each candidate locker is assigned to the base that owns its nearest
--      support actor (also gated by LOCKER_TO_SUPPORT_M).
--   3. If supports can't be reached or .base doesn't resolve, fall back to
--      the plain radius proxy.

local Config = require("config")
local U      = require("util")
local Items  = require("items")

local M = {}

local function gather_supports_and_lockers()
    local supports = U.try(function() return FindAllOf("UWEBaseSupportActor") end)
    local lockers  = U.try(function() return FindAllOf("SN2InventoryActor") end)
    local needs_fallback =
        (not supports or not next(supports)) or
        (not lockers  or not next(lockers))
    if needs_fallback then
        supports, lockers = {}, {}
        local all = U.try(function() return FindAllOf("Actor") end)
        if all then
            for _, a in pairs(all) do
                if U.is_valid(a) then
                    if U.class_is(a, "uwebasesupportactor") then
                        table.insert(supports, a)
                    elseif U.class_is(a, "sn2inventoryactor") then
                        table.insert(lockers, a)
                    end
                end
            end
        end
    end
    return lockers or {}, supports or {}
end

-- FGuid is {A,B,C,D} int32s. Used by both UWEBaseSupportActor.BaseGUID
-- and UWESculpturalBaseActor.BaseNetworkGUID — same struct type.
local function read_guid(g)
    if g == nil then return nil end
    local a = U.try(function() return g.A end)
    local b = U.try(function() return g.B end)
    local c = U.try(function() return g.C end)
    local d = U.try(function() return g.D end)
    if type(a) ~= "number" or type(b) ~= "number"
        or type(c) ~= "number" or type(d) ~= "number" then
        return nil
    end
    return string.format("%08x-%08x-%08x-%08x", a, b, c, d)
end

-- Stable string identifier for the base a support actor belongs to. We
-- prefer support.BaseGUID — hopefully shared across every support in the
-- same connected base network. Falls back to .base.BaseNetworkGUID, then to
-- the .base actor's full name (per-room).
local function support_base_id(support)
    if not U.is_valid(support) then return nil end
    -- 1) Direct FGuid on the support
    local g = U.try(function() return support.BaseGUID end)
    local key = read_guid(g)
    if key then return "G:" .. key end
    -- 2) BaseNetworkGUID on the base actor pointed at by .base
    local b = U.try(function() return support.base end)
    b = U.deref_weak(b)
    if U.is_valid(b) then
        local ng = U.try(function() return b.BaseNetworkGUID end)
        key = read_guid(ng)
        if key then return "N:" .. key end
        -- 3) Worst case: per-room full name (the original key)
        return "F:" .. (U.try(function() return b:GetFullName() end) or "?")
    end
    return nil
end

-- For a location, find the closest support actor and return its base id
-- plus the squared distance to the support. Returns nil if the closest
-- support is beyond max_dist_uu or has no resolvable base.
local function nearest_support_base(loc, supports, max_dist_uu)
    if not loc then return nil end
    local closest, dmin
    for _, s in pairs(supports) do
        if U.is_valid(s) then
            local sloc = U.actor_location(s)
            if sloc then
                local d2 = U.vec_dist_sq(loc, sloc)
                if d2 and (not dmin or d2 < dmin) then
                    closest, dmin = s, d2
                end
            end
        end
    end
    if not closest or not dmin then return nil end
    if dmin > max_dist_uu * max_dist_uu then return nil end
    local id = support_base_id(closest)
    if not id then return nil end
    return id, dmin
end

-- One-shot diagnostics so we can confirm both detection paths engage at
-- least once per session.
local SCAN_ENTRY_LOGGED     = false
local BASE_DETECT_DIAG_DONE = false
local LAST_SUMMARY_LOG_MS   = 0
local STABILITY_MS          = 3000
local LAST_LOCKER_COUNT     = -1
local LAST_SUPPORT_COUNT    = -1
local STABLE_SINCE_MS       = 0
local DEFER_LOGGED          = false

function M.scan_lockers(pawn)
    local ploc = U.actor_location(pawn)
    if not ploc then return nil, 0, 0 end

    local lockers_world, supports = gather_supports_and_lockers()

    if not SCAN_ENTRY_LOGGED then
        SCAN_ENTRY_LOGGED = true
        U.logf("scan-entry: gather returned %d lockers, %d supports",
            #lockers_world, #supports)
    end

    local lc, sc = #lockers_world, #supports
    local now = U.now_ms()
    if lc ~= LAST_LOCKER_COUNT or sc ~= LAST_SUPPORT_COUNT then
        if LAST_LOCKER_COUNT >= 0 then
            U.logf("locker set changed (%d->%d lockers, %d->%d supports) — deferring scans %d ms",
                LAST_LOCKER_COUNT, lc, LAST_SUPPORT_COUNT, sc, STABILITY_MS)
        end
        LAST_LOCKER_COUNT  = lc
        LAST_SUPPORT_COUNT = sc
        STABLE_SINCE_MS    = now
        DEFER_LOGGED       = true
        return nil, 0, 0
    end
    if now - STABLE_SINCE_MS < STABILITY_MS then
        return nil, 0, 0
    end
    if DEFER_LOGGED then
        DEFER_LOGGED = false
        U.logf("locker set stable for %d ms — resuming scans", STABILITY_MS)
    end

    -- Smart base detection first. Now returns a string id (BaseGUID-based
    -- when possible) rather than a UObject — see support_base_id.
    local pb_key = nearest_support_base(ploc, supports, Config.SUPPORT_MAX_DIST_M * 100)

    local accepted, detection_mode

    if pb_key then
        detection_mode = "base"
        accepted = {}
        local max_locker_to_support_uu = Config.LOCKER_TO_SUPPORT_M * 100
        for _, locker in pairs(lockers_world) do
            if U.is_valid(locker) then
                local lbase_id = nearest_support_base(U.actor_location(locker),
                                                     supports,
                                                     max_locker_to_support_uu)
                if lbase_id == pb_key then
                    table.insert(accepted, locker)
                end
            end
        end
        if not BASE_DETECT_DIAG_DONE then
            BASE_DETECT_DIAG_DONE = true
            -- Count distinct base ids across all supports so we can tell
            -- whether BaseGUID is network-wide (1 id per multi-room base)
            -- or per-piece (many ids in a single base).
            local seen, distinct = {}, 0
            for _, s in pairs(supports) do
                local id = support_base_id(s)
                if id and not seen[id] then
                    seen[id] = true; distinct = distinct + 1
                end
            end
            U.logf("base-detect: player_base=%s, %d lockers claimed, %d distinct base ids across all %d supports",
                tostring(pb_key), #accepted, distinct, #supports)
        end
    else
        -- Fallback: radius. Player is "in a base" if any locker is within
        -- BASE_DETECT_RADIUS_M; aggregate lockers within LOCKER_RADIUS_M.
        local detect_r2 = (Config.BASE_DETECT_RADIUS_M * 100) ^ 2
        local locker_r2 = (Config.LOCKER_RADIUS_M       * 100) ^ 2
        local detected = false
        accepted = {}
        for _, locker in pairs(lockers_world) do
            if U.is_valid(locker) then
                local d2 = U.vec_dist_sq(ploc, U.actor_location(locker))
                if d2 then
                    if d2 <= detect_r2 then detected = true end
                    if d2 <= locker_r2 then table.insert(accepted, locker) end
                end
            end
        end
        if not detected then return nil, 0, 0 end
        detection_mode = "radius"
    end

    if #accepted == 0 then return nil, 0, 0 end

    local totals      = {}
    local added_items = 0
    local sum_counts  = 0
    local nonempty    = 0
    local sum_n       = 0
    for _, l in ipairs(accepted) do
        local inv = U.try(function() return l.Inventory end)
        local n   = inv and U.try(function() return inv:NumItems() end) or 0
        if type(n) == "number" and n > 0 then
            nonempty = nonempty + 1
            sum_n    = sum_n + n
        end
        local a, s = Items.aggregate_locker(l, totals)
        added_items = added_items + a
        sum_counts  = sum_counts + s
    end

    local t = U.now_ms()
    if t - LAST_SUMMARY_LOG_MS > Config.SCAN_LOG_PERIOD_MS then
        LAST_SUMMARY_LOG_MS = t
        -- U.logf("scan[%s]: lockers=%d nonempty=%d numitems=%d count_sum=%d parsed=%d cache=%d",
        --     detection_mode, #accepted, nonempty, sum_n, sum_counts, added_items,
        --     Items.cache_size())
    end

    return totals, #accepted, added_items
end

-- Reset the one-shot diagnostic flags so they re-fire after a level reload.
function M.reset()
    SCAN_ENTRY_LOGGED     = false
    BASE_DETECT_DIAG_DONE = false
    LAST_SUMMARY_LOG_MS   = 0
    LAST_LOCKER_COUNT     = -1
    LAST_SUPPORT_COUNT    = -1
    STABLE_SINCE_MS       = 0
    DEFER_LOGGED          = false
end

return M
