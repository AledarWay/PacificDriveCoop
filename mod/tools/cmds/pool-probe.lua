-- Pooled item manifestations without an item Instance (what spawnsync's inPool treats as idle): per class,
-- how many stand at the origin, are hidden, have collision / tick off.
local Pooled = StaticFindObject("/Script/PenDriverUtils.PooledActor")
local ItemActor = StaticFindObject("/Script/PenDriverInventory.ItemActorManifestation")
local stats = {}
for _, a in ipairs(FindAllOf("Actor") or {}) do
    if CoopSyncUsable(a) and a:GetFullName():find(":PersistentLevel.", 1, true) and a:IsA(Pooled) and a:IsA(ItemActor) then
        local ok, inst = pcall(function() return a.Instance end)
        local hasInst = ok and inst and inst:IsValid()
        local l = a:K2_GetActorLocation()
        local origin = math.abs(l.X) < 1 and math.abs(l.Y) < 1 and math.abs(l.Z) < 1
        local okU, inUse = pcall(function() return a.bInUse end)
        local k = string.format("%s inst=%s origin=%s hidden=%s collide=%s", a:GetClass():GetFName():ToString(), tostring(hasInst),
            tostring(origin), tostring(a.bHidden), tostring(a:GetActorEnableCollision()))
        stats[k] = (stats[k] or 0) + 1
    end
end
local t = {}
for k, v in pairs(stats) do t[#t + 1] = string.format("%4d %s", v, k) end
table.sort(t)
return table.concat(t, "\n")
