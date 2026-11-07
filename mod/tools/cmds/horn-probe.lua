-- The car horn: HORN_DO = 'start' / 'stop' honks through the car manager like the player's horn key (instigator
-- "Probe"); returns the manager's horn state.
local m = FindFirstOf("BP_CarManager_C")
if HORN_DO == "start" then m:StartHornHonk(FName("Probe")) elseif HORN_DO == "stop" then m:EndHornHonk(FName("Probe")) end
HORN_DO = nil
local o = {}
m:GetHornState(o)
return "horn=" .. tostring(o.HornState)
