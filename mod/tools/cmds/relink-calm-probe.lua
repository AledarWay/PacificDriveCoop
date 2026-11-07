-- relink-flip-probe with the car held: chassis kinematic during the re-bind, put back to its transform with zero
-- velocity and physics on again after HOLD_MS; samples into RelinkProbe as before.
local SSC = StaticFindObject("/Script/PenDriverInventory.SlotSceneComponent")
local car = FindFirstOf("BP_CarManager_C").NewCarActor
local HOLD = HOLD_MS or 300
local function sample(tag)
    local r, l, v = car:K2_GetActorRotation(), car:K2_GetActorLocation(), car:GetVelocity()
    return string.format("%s loc=%.0f,%.0f,%.0f rot=%.1f,%.1f,%.1f v=%.0f", tag, l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll,
        math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z))
end
RelinkProbe = { sample("before") }
local root = car.RootComponent
local loc, rot = car:K2_GetActorLocation(), car:K2_GetActorRotation()
root:SetSimulatePhysics(false)
local n = 0
local comps = car:K2_GetComponentsByClass(SSC)
for i = 1, #comps do
    local c = comps[i]:get()
    local sl = c.ItemSlot
    if sl and sl:IsValid() and sl.Items:GetArrayNum() > 0 then
        pcall(function() c:SetItemSlot(nil) c:SetItemSlot(sl) end)
        n = n + 1
    end
end
RelinkProbe[#RelinkProbe + 1] = "rebound " .. n
Dev.after(HOLD, function()
    car:K2_SetActorLocationAndRotation(loc, rot, false, {}, true)
    root:SetSimulatePhysics(true)
    root:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName("None"))
    root:SetPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false, FName("None"))
    RelinkProbe[#RelinkProbe + 1] = "released"
end)
for i = 1, 15 do
    Dev.after(HOLD + i * 200, function() RelinkProbe[#RelinkProbe + 1] = sample(string.format("t+%.1f", i * 0.2)) end)
end
return table.concat(RelinkProbe, " | ")
