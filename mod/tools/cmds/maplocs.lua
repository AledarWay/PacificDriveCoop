local list = FindAllOf("MapLocation") or {}
Dev.out("MapLocation count", #list)
for i, m in ipairs(list) do
  if i > 60 then break end
  local ok, lvl = pcall(function() return m.LevelAsset.AssetPathName:ToString() end)
  Dev.out(m:GetFullName(), ok and lvl or "?", "start", m.IsStartingLevel)
end
return #list
