local sts = FindAllOf("SpawnState") or {}
Dev.out("SpawnState instances", #sts)
for _, s in ipairs(sts) do
  local n = s.SpawnedActors:GetArrayNum()
  Dev.out(Dev.name(s), "SpawnedActors", n, "Markers", s.Markers:GetArrayNum())
  local byc = {}
  for i = 1, n do local a = s.SpawnedActors[i]; if a:IsValid() then local c = a:GetClass():GetFName():ToString(); byc[c] = (byc[c] or 0) + 1 end end
  local keys = {} for k in pairs(byc) do keys[#keys+1] = k end table.sort(keys, function(x,y) return byc[x] > byc[y] end)
  for i = 1, math.min(40, #keys) do Dev.out("  ", keys[i], byc[keys[i]]) end
end
return "ok"
