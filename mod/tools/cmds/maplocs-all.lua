-- Every MapLocation the game has loaded: its object path and level (to pick zones to look at).
local out = {}
for _, m in ipairs(FindAllOf("MapLocation") or {}) do
    local p = m:GetFullName():gsub("^%S+%s+", "")
    if not p:find("Default__", 1, true) then
        local ok, lvl = pcall(function() return m.LevelAsset.AssetPathName:ToString() end)
        out[#out + 1] = p .. "\t" .. (ok and lvl or "?")
    end
end
table.sort(out)
return #out .. "\n" .. table.concat(out, "\n")
