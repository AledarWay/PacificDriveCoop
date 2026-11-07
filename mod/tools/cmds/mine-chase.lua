-- Single-player baseline of a chasing hazard: MINE_OP "put" puts the own car MINE_DIST from the nearest MINE_CLASS
-- (default the supercharger malfunction mine) and remembers it; "sample" reports where that hazard is and its state.
local cls = MINE_CLASS or "BP_Hazard_MalfunctionMine_SuperCharger_C"
local car = FindFirstOf("BP_CarManager_C").NewCarActor
local cl = car:K2_GetActorLocation()
if MINE_OP == "put" then
    local best, bd
    for _, a in ipairs(FindAllOf(cls) or {}) do
        local l = a:K2_GetActorLocation()
        if a:IsValid() and not (l.X == 0 and l.Y == 0) then
            local d = (l.X - cl.X) ^ 2 + (l.Y - cl.Y) ^ 2
            if not bd or d < bd then best, bd = a, d end
        end
    end
    if not best then return "none" end
    MINE_PICKED = best:GetFullName():gsub("^%S+%s+", "")
    local l = best:K2_GetActorLocation()
    car:K2_SetActorLocationAndRotation({ X = l.X - (MINE_DIST or 1500), Y = l.Y, Z = l.Z + 150 }, { Pitch = 0, Yaw = 0, Roll = 0 }, false, {}, true)
    return string.format("picked %s at %.0f,%.0f,%.0f", MINE_PICKED, l.X, l.Y, l.Z)
end
local a = MINE_PICKED and StaticFindObject(MINE_PICKED)
if not (a and a:IsValid()) then return "gone" end
local l = a:K2_GetActorLocation()
local s = {}
for _, f in ipairs({ "MovingTowardCar", "bLockMovement", "SpawnedFromEvent", "BlockDamage" }) do
    pcall(function() s[#s + 1] = f .. "=" .. tostring(a[f]) end)
end
pcall(function() s[#s + 1] = "in_range=" .. tostring(a.BP_HazardProperty_PlayerRange.PlayerInRange) end)
pcall(function() s[#s + 1] = "phys=" .. tostring(a.RootComponent:IsSimulatingPhysics()) .. " root=" .. a.RootComponent:GetClass():GetFName():ToString() end)
pcall(function() s[#s + 1] = "tick=" .. tostring(a:IsActorTickEnabled()) end)
return string.format("%.0f,%.0f,%.0f to_car=%.0f %s", l.X, l.Y, l.Z, math.sqrt((l.X - cl.X) ^ 2 + (l.Y - cl.Y) ^ 2), table.concat(s, " "))
