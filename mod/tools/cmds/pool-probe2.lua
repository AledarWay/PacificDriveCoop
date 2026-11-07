local groups = {}
for _, a in ipairs(FindAllOf("ItemActorManifestation") or {}) do
  if CoopSyncUsable(a) and a:GetFullName():find(":PersistentLevel%.") then
    local l = a:K2_GetActorLocation()
    local origin = math.abs(l.X) < 1 and math.abs(l.Y) < 1 and math.abs(l.Z) < 1
    local inst = a.Instance
    local hasInst = inst and inst:IsValid() and CoopSyncUsable(inst)
    local okp, isP = pcall(function() return a:IsPooled() end)
    local k = string.format("origin=%s inst=%s destroyedByPool=%s IsPooled()=%s hiddenInGame=%s", tostring(origin), tostring(hasInst), tostring(a.bDestroyedByPool), okp and tostring(isP) or "?", tostring(a.bHidden))
    groups[k] = (groups[k] or 0) + 1
  end
end
for k, v in pairs(groups) do Dev.out(v, k) end
return "ok"
