-- Alterra Audit — HUD showing the resources stored across every locker in
-- the base the player is currently inside.
--
-- Hotkeys:
--   Ctrl+F9            toggle HUD on/off (hardcoded fallback)
--   <configurable>     toggle HUD; set via SN2ModSettings → "Alterra Audit"
--   Left mouse click   on a group header (while cursor is visible) toggles
--                      that group's collapse state
--
-- Console: audit on|off|rebuild|status
-- Log:     Subnautica2/Binaries/Win64/ue4ss/UE4SS.log
--
-- This file is the entry point. The work is split across modules:
--   config.lua   — tunable constants
--   util.lua     — Lua + UE helpers (pcall wrappers, is_valid, player accessors)
--   items.lua    — UWEItemType cache + per-locker aggregation
--   base.lua     — gather lockers/supports + scan_lockers
--   hud.lua      — UMG overlay + per-tick body
--   settings.lua — SN2ModSettings registration + live values

local Config   = require("config")
local U        = require("util")
local Items    = require("items")
local Base     = require("base")
local Hud      = require("hud")
local Settings = require("settings")

local ENABLED = true

local function toggle()
    ExecuteInGameThread(function()
        ENABLED = not ENABLED
        U.logf(ENABLED and "enabled" or "disabled")
        if not ENABLED then Hud.hide_overlay() end
    end)
end

-- Hardcoded Ctrl+F9 fallback so the mod is usable even when SN2ModSettings
-- isn't installed (or hasn't been opened to confirm the default key).
RegisterKeyBind(Key.F9, { ModifierKey.CONTROL }, toggle)

-- Left-mouse-button: ask the HUD if a group header is currently under the
-- cursor and, if so, toggle that group. UE4SS's RegisterKeyBind observes
-- input at the OS level rather than via UE's input system, so it doesn't
-- consume the click — the game still receives it (attacks, inventory
-- interaction, etc.). The HUD-side check uses Widget:IsHovered(), which
-- returns false when no cursor exists, so during normal gameplay
-- (camera-locked mouse) this fires but does nothing.
RegisterKeyBind(Key.LEFT_MOUSE_BUTTON, {}, function()
    ExecuteInGameThread(function() Hud.toggle_hovered_group() end)
end)

-- User-configurable plain-key binding. SN2ModSettings stores keybinds as
-- modifier-less name strings ("F9", "G", etc.), so we pre-register every
-- letter+F-key without modifiers and let the callback decide whether the
-- pressed key matches the current setting.
local keyMap = {}
for ch = string.byte("A"), string.byte("Z") do
    local name = string.char(ch)
    if Key[name] then keyMap[name] = Key[name] end
end
for i = 1, 12 do
    local name = "F" .. i
    if Key[name] then keyMap[name] = Key[name] end
end

local function key_matches(captured)
    local v = Settings.values
    if captured == v.KeyToggle then return true end
    if v.KeyToggle_Alt ~= "" and captured == v.KeyToggle_Alt then return true end
    return false
end

for keyName, keyConst in pairs(keyMap) do
    local captured = keyName
    RegisterKeyBind(keyConst, {}, function()
        if key_matches(captured) then toggle() end
    end)
end

-- Tick loop. We also pull fresh settings every SETTINGS_REFRESH_MS so a key
-- change in the SN2ModSettings menu takes effect without a mod reload.
local SETTINGS_REFRESH_MS = 3000
local LAST_SETTINGS_MS    = 0
local TICK_ERR_LOGGED     = false

-- Exiting to main menu and loading a save tears down all UObjects from the
-- old level. UI.widget and cached UWEItemType references survive in Lua but
-- point at dead objects (sometimes still passing IsValid). Watch for the
-- player pawn's identity changing and reset both modules when it does.
local LAST_PAWN_KEY = nil
local function check_level_reload()
    local pawn = U.get_pawn()
    if not U.is_valid(pawn) then return end
    local key = U.try(function() return pawn:GetFullName() end)
    if not key then return end
    if LAST_PAWN_KEY and LAST_PAWN_KEY ~= key then
        U.logf("level reload detected — resetting state")
        Items.invalidate()
        Base.reset()
        Hud.rebuild()
    end
    LAST_PAWN_KEY = key
end

local function schedule_next()
    ExecuteWithDelay(Config.POLL_MS, function()
        check_level_reload()
        local ok, err = pcall(function() Hud.tick(ENABLED) end)
        if not ok and not TICK_ERR_LOGGED then
            TICK_ERR_LOGGED = true
            U.logf("tick error (first occurrence): %s", tostring(err))
        end
        local now = U.now_ms()
        if now - LAST_SETTINGS_MS > SETTINGS_REFRESH_MS then
            LAST_SETTINGS_MS = now
            Settings.refresh()
        end
        schedule_next()
    end)
end

RegisterConsoleCommandHandler("audit", function(FullCommand, Parameters, OutputDevice)
    local arg = (Parameters and Parameters[1] or ""):lower()
    if arg == "on" or arg == "enable" then
        ENABLED = true; U.logf("enabled")
    elseif arg == "off" or arg == "disable" then
        ENABLED = false; Hud.hide_overlay(); U.logf("disabled")
    elseif arg == "rebuild" then
        Hud.rebuild()
        U.logf("rebuilding")
    elseif arg == "status" then
        local shown, has_widget, n_rows = Hud.status()
        U.logf("v%s enabled=%s widget=%s shown=%s rows=%d KeyToggle=%q KeyToggle_Alt=%q",
            Config.VERSION, tostring(ENABLED), tostring(has_widget), tostring(shown), n_rows,
            tostring(Settings.values.KeyToggle), tostring(Settings.values.KeyToggle_Alt))
    else
        U.logf("usage: audit on | off | rebuild | status   (Ctrl+F9 toggles)")
    end
    return true
end)

U.logf("loaded v%s — Ctrl+F9 toggles HUD; configurable via SN2ModSettings → 'Alterra Audit'", Config.VERSION)
schedule_next()
