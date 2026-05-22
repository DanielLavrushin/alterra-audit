-- SN2ModSettings integration.
--
-- At load time we drop a small manifest into SN2ModSettings/registrations/
-- so users get an in-game settings page for the mod. From then on we read
-- the current values via ModRef:GetSharedVariable. If SN2ModSettings isn't
-- installed (ModRef is nil), every getter falls back to the default and
-- the mod still works.
--
-- Public API:
--   values.KeyToggle      — string, name of the user-chosen toggle key
--   values.KeyToggle_Alt  — string, optional secondary toggle key
--   refresh()             — pull latest values from SharedVariable

local Config = require("config")
local U      = require("util")

local M = {}

local MOD_NAME      = "AlterraAudit"
local MANIFEST_PATH = "./ue4ss/Mods/SN2ModSettings/registrations/" .. MOD_NAME .. ".lua"
local MANIFEST_BODY = string.format([=[
return {
    name    = "AlterraAudit",
    display = "Alterra Audit",
    version = "%s",
    settings = {
        { key="KeyToggle", title="Toggle HUD",
          description="Press to toggle the resources overlay on/off. Ctrl+F9 keeps working regardless of what you set here.",
          type="keybind", default="F10" },
    },
}
]=], Config.VERSION)

-- io.open against the registrations file is Windows-shaped because UE4SS
-- runs inside the game process. Under Proton this still works fine.
local function write_manifest()
    local f = io.open(MANIFEST_PATH, "r")
    if f then
        local cur = f:read("*a"); f:close()
        if cur == MANIFEST_BODY then return end
    end
    local w = io.open(MANIFEST_PATH, "w")
    if not w then
        U.logf("settings: manifest write FAILED at %s", MANIFEST_PATH)
        return
    end
    w:write(MANIFEST_BODY); w:close()
    U.logf("settings: manifest written")
end
pcall(write_manifest)

-- Defaults; refresh() overwrites these from SharedVariable when available.
M.values = {
    KeyToggle     = "F9",
    KeyToggle_Alt = "",
}

local function read_shared(key)
    if not ModRef then return nil end
    return U.try(function()
        return ModRef:GetSharedVariable("SN2ModSettings/" .. MOD_NAME .. "/" .. key)
    end)
end

function M.refresh()
    if not ModRef then return false end
    local changed = false
    for k, cur in pairs(M.values) do
        local v = read_shared(k)
        if v ~= nil and type(v) == type(cur) and v ~= cur then
            M.values[k] = v
            changed = true
            U.logf("settings: %s = %q", k, tostring(v))
        end
    end
    return changed
end
M.refresh()   -- initial load

return M
