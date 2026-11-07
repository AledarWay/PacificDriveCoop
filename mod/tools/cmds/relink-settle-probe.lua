-- relink-flip-probe with the car settled as twincar does it: put back to its transform with zero velocities from the
-- 3rd frame after the re-bind, every 100 ms for 0.6 s (physics stays on). Samples into RelinkProbe.
local SSC = StaticFindObject("/Script/PenDriverInventory.SlotSceneComponent")
local car = FindFirstOf("BP_CarManager_C").NewCarActor
local function sample(tag)
    local r, l, v = car:K2_GetActorRotation(), car:K2_GetActorLocation(), car:GetVelocity()
    return string.format("%s loc=%.0f,%.0f,%.0f rot=%.1f,%.1f,%.1f v=%.0f", tag, l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll,
        math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z))
end
RelinkProbe = { sample("before") }
local loc, rot = car:K2_GetActorLocation(), car:K2_GetActorRotation()
local function settle()
    local root = car.RootComponent
    car:K2_SetActorLocationAndRotation(loc, rot, false, {}, true)
    root:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName("None"))
    root:SetPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false, FName("None"))
end
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
-- as twincar's settler: from the 3rd frame after the re-bind, every 100 ms until 0.6 s
local frames, t0, lastPut, h = 0, nil, -1, nil
h = LoopInGameThreadWithDelay(1, function()
    frames = frames + 1
    if frames < 3 then return end
    local now = os.clock()
    t0 = t0 or now
    if now - lastPut >= 0.1 then settle() lastPut = now end
    if now - t0 > 0.6 and h then CancelDelayedAction(h) h = nil end
end)
for i = 1, 15 do
    Dev.after(i * 200, function() RelinkProbe[#RelinkProbe + 1] = sample(string.format("t+%.1f", i * 0.2)) end)
end
return table.concat(RelinkProbe, " | ")
