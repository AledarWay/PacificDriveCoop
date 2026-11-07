local t = {}
for _, a in ipairs(CoopSync.collect()) do
  if CoopSync.clsName(a) == "BP_Destruct_Traffic_Cone_C" then
    local l = a:K2_GetActorLocation()
    local rc = a.RootComponent
    local sim = false pcall(function() sim = rc:IsSimulatingPhysics() end)
    t[#t+1] = string.format("%s@%.0f,%.0f,%.0f sim=%s mob=%s", a:GetFName():ToString(), l.X, l.Y, l.Z, tostring(sim), tostring(rc.Mobility))
  end
end
table.sort(t)
return table.concat(t, " | ")
