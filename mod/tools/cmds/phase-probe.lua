-- Route phase (0 idle, 1 generation, 2 planning, 3 explore) of every route state, plus how many actors
-- of the current world stand at the origin (still being placed by the zone generator).
local out = {}
for _, r in ipairs(FindAllOf("BaseRouteState") or {}) do
    if r:IsValid() and not r:GetFullName():find("Default__", 1, true) then
        out[#out + 1] = r:GetFName():ToString() .. "=" .. tostring(r.CurrentPhase)
    end
end
local gi = FindFirstOf("DrivingGameInstance")
local level = gi:GetWorld():GetFullName():gsub("^%S+ ", "") .. ":PersistentLevel."
local n, origin = 0, 0
for _, a in ipairs(FindAllOf("Actor") or {}) do
    if a:IsValid() and a:GetFullName():find(level, 1, true) then
        n = n + 1
        local ok, l = pcall(function() return a:K2_GetActorLocation() end)
        if ok and l and l.X == 0 and l.Y == 0 and l.Z == 0 then origin = origin + 1 end
    end
end
return string.format("state=%s world=%s actors=%d origin=%d phases %s", tostring(gi.CurrentGameplayState),
    gi:GetWorld():GetFName():ToString(), n, origin, table.concat(out, " "))
