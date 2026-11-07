local t = {}
for _, a in ipairs(FindAllOf("BP_Destruct_Traffic_Cone_C") or {}) do
  if CoopSyncUsable(a) and a:GetFullName():find(":PersistentLevel%.") then
    local p = CoopSyncParentOf(a)
    if p then
      local l = a:K2_GetActorLocation()
      local pl = p:K2_GetActorLocation()
      t[#t+1] = string.format("%s@%.0f,%.0f,%.0f parent=%s(%s)@%.0f,%.0f,%.0f", a:GetFName():ToString(), l.X, l.Y, l.Z, p:GetFName():ToString(), CoopSync.clsName(p), pl.X, pl.Y, pl.Z)
    end
  end
end
table.sort(t)
return table.concat(t, " | ")
