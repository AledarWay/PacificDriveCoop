-- The instability timer step by step (2026-11-08: which call moves which field, and what it calls next): the storm
-- manager's fields after each of STEP_CALLS (default the timer's own functions); the calls hooked meanwhile are logged.
local P = "/Game/Systems/Managers/BP_StormManager.BP_StormManager_C:"
local Hook = CoopSyncHook or dofile("C:/PacificDriveCoop/mod/CoopSync/Scripts/hooks.lua").hook
STP_LOG = STP_LOG or {}
if not STP_HOOKED then
    STP_HOOKED = true
    for _, fn in ipairs({ "ChangeStormTimerState", "SpawnRoyaleStorm", "SpawnInstabilityStorm", "SetupInstabilityTimer",
        "Check Instability", "CalculateInstabilityTimer", "IncrementStormInstability", "InstabilityTimerTick",
        "TickStormStabilityTimer", "ClearInstability", "CalculateFinalInstabilityTollerance", "SpawnExitTriggeredStorm" }) do
        Hook(P .. fn, function(_, a)
            local s = fn
            pcall(function() local v = a:get() s = s .. "(" .. tostring(type(v) == "userdata" and "obj" or v) .. ")" end)
            STP_LOG[#STP_LOG + 1] = s
        end)
    end
end
local m = FindFirstOf("BP_StormManager_C")
local function snap()
    local it, tk, tol = {}, {}, {}
    pcall(function() m:GetCurrentInstabilityTime(it) end)
    pcall(function() m:ShouldTickInstability(tk) end)
    pcall(function() m:GetInstabilityTollerance(tol) end)
    local s = m.SpawnedStormIfValid
    return string.format("state=%s timer=%s before=%.1f insttime=%.2f tick=%s tol=%.1f final=%.1f left=%s storm=%s",
        tostring(m.CurrentStormState), tostring(m.NewInstabilityTimerActive), m.TimeBeforeInstabilityStarts,
        tonumber(it.CurrentInstabilityTime) or -1, tostring(tk.ShouldTick), tonumber(tol.InstabilityTollerance) or -1,
        m.FinalInstabilityTollerance, tostring(m.PlayerLeftStartingArea), tostring(s and s:IsValid()))
end
local out = { "start " .. snap() }
for _, c in ipairs(STEP_CALLS or { "InstabilityTimerTick", "TickStormStabilityTimer", "Check Instability" }) do
    local n0 = #STP_LOG
    local name, arg = c:match("^(.-)%((.*)%)$")
    name = name or c
    local ok, e = pcall(function()
        if arg then m[name](m, tonumber(arg)) else m[name](m) end
    end)
    local calls = {}
    for i = n0 + 1, #STP_LOG do calls[#calls + 1] = STP_LOG[i] end
    out[#out + 1] = c .. (ok and "" or (" ERR " .. tostring(e))) .. " -> " .. snap() .. " calls: " .. table.concat(calls, ",")
end
return table.concat(out, " || ")
