-- Does re-binding the own car's slots (twincar.relink's SetItemSlot(nil) + SetItemSlot(slot): the parts are spawned
-- again) disturb the car's physics? Re-binds every slot (RELINK_ALL) or none, then samples the car's rotation and
-- speed for 3 s into RelinkProbe (read it back with "return RelinkProbe").
local SSC = StaticFindObject("/Script/PenDriverInventory.SlotSceneComponent")
local car = FindFirstOf("BP_CarManager_C").NewCarActor
local function sample(tag)
    local r, l, v = car:K2_GetActorRotation(), car:K2_GetActorLocation(), car:GetVelocity()
    return string.format("%s loc=%.0f,%.0f,%.0f rot=%.1f,%.1f,%.1f v=%.0f", tag, l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll,
        math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z))
end
RelinkProbe = { sample("before") }
local n = 0
if RELINK_ALL ~= false then
    local comps = car:K2_GetComponentsByClass(SSC)
    for i = 1, #comps do
        local c = comps[i]:get()
        local sl = c.ItemSlot
        if sl and sl:IsValid() and sl.Items:GetArrayNum() > 0 then
            pcall(function() c:SetItemSlot(nil) c:SetItemSlot(sl) end)
            n = n + 1
        end
    end
end
RelinkProbe[#RelinkProbe + 1] = "rebound " .. n
for i = 1, 15 do
    Dev.after(i * 200, function() RelinkProbe[#RelinkProbe + 1] = sample(string.format("t+%.1f", i * 0.2)) end)
end
return table.concat(RelinkProbe, " | ")
