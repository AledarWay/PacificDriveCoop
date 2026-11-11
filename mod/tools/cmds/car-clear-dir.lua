-- The own car turned to the clearest way ahead (cars-test 8b / 9: the guest's car driven into a tree or a rock by
-- the start spot bounced back, then would not move on the throttle - 2026-11-10). Of 16 yaws, the ones with nothing
-- at bumper and roof height from 300 to CD_LEN ahead; of those, the ground CD_LEN out nearest the car's height. The
-- car is put there turned that way, at rest. Returns "<yaw> rise=<cm> clear=<n of 16>" or "none ..." (left as it was).
local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local car = _G.CoopPlayers.twinModule().ownCar()
local p = car:K2_GetActorLocation()
local len = CD_LEN or 4000
local function hit(a, b)
    local h = {}
    local ok, r = pcall(function() return KSL:LineTraceSingle(car, a, b, 0, false, { car }, 0, h, true, { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0) end)
    return ok and r, h
end
local best, bestRise, clear = nil, nil, 0
for i = 0, 15 do
    local yaw = i * 22.5
    local dx, dy = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
    local blocked = false
    for _, z in ipairs({ 40, 140 }) do
        if hit({ X = p.X + dx * 300, Y = p.Y + dy * 300, Z = p.Z + z }, { X = p.X + dx * len, Y = p.Y + dy * len, Z = p.Z + z }) then blocked = true break end
    end
    if not blocked then
        clear = clear + 1
        local o = { X = p.X + dx * len, Y = p.Y + dy * len }
        local ok, h = hit({ X = o.X, Y = o.Y, Z = p.Z + 400 }, { X = o.X, Y = o.Y, Z = p.Z - 1500 })
        local rise = ok and h.ImpactPoint and math.abs(h.ImpactPoint.Z - p.Z) or 1500
        if not bestRise or rise < bestRise then best, bestRise = yaw, rise end
    end
end
if not best then return "none clear=0" end
car:K2_SetActorLocationAndRotation({ X = p.X, Y = p.Y, Z = p.Z + 60 }, { Pitch = 0, Yaw = best, Roll = 0 }, false, {}, true)
pcall(function()
    car.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName("None"))
    car.RootComponent:SetPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false, FName("None"))
end)
return string.format("%.1f rise=%.0f clear=%d", best, bestRise, clear)
