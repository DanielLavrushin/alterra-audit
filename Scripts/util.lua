-- Small helpers used everywhere: error-swallowing pcalls, validity probes
-- that survive FWeakObjectPtr, weak-ptr deref, class-chain inspection,
-- and the UEHelpers-backed player accessors.

local Config = require("config")

local M = {}

function M.logf(fmt, ...)
    print(string.format(Config.LOG_PREFIX .. " " .. fmt, ...))
end

function M.try(fn)
    local ok, r = pcall(fn)
    if ok then return r end
end

-- Resilient to weird userdata (FWeakObjectPtr etc.) where IsValid isn't a
-- regular UFunction. pcall everything so we never propagate an error.
function M.is_valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o.IsValid and o:IsValid() end)
    return ok and v == true
end

-- FWeakObjectPtr.Get() returns the underlying UObject (or nil if the weak
-- ref has expired). If `v` is already a normal UObject :Get() either
-- doesn't exist or returns the same userdata back; handle both.
function M.deref_weak(v)
    if v == nil then return nil end
    local r = M.try(function() return v:Get() end)
    if r ~= nil and r ~= v then return r end
    return v
end

local UEHelpers = (function()
    local ok, mod = pcall(require, "UEHelpers")
    if ok and type(mod) == "table" then return mod end
    return {}
end)()

function M.get_pc()
    if UEHelpers.GetPlayerController then
        local pc = M.try(function() return UEHelpers:GetPlayerController() end)
        if M.is_valid(pc) then return pc end
    end
    return M.try(function() return FindFirstOf("PlayerController") end)
end

function M.get_pawn()
    local pc = M.get_pc()
    if not M.is_valid(pc) then return nil end
    return M.try(function() return pc:K2_GetPawn() end)
        or M.try(function() return pc.Pawn end)
end

function M.actor_location(a)
    return M.try(function() return a:K2_GetActorLocation() end)
end

-- True if obj's class chain contains a class with the given (lowercased)
-- name. Cheaper than calling FindAllOf for every subclass we want to match.
function M.class_is(obj, target_low)
    local c = M.try(function() return obj:GetClass() end)
    while M.is_valid(c) do
        local n = M.try(function() return c:GetFName():ToString() end)
        if n and string.lower(n) == target_low then return true end
        c = M.try(function() return c:GetSuperStruct() end)
         or M.try(function() return c:GetSuperClass() end)
    end
    return false
end

function M.vec_dist_sq(a, b)
    if not a or not b then return nil end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

function M.world_is_ready()
    return M.is_valid(M.get_pawn())
end

-- Coarse but cheap monotonic clock used to throttle log lines and time the
-- cache refresh interval.
function M.now_ms()
    return math.floor(os.clock() * 1000)
end

return M
