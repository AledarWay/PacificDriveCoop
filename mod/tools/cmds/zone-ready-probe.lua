-- Why zoneReady stays false: spawn markers left / spawned actors at the origin, by class (in this world's level).
local gi = FindFirstOf("DrivingGameInstance")
local level = gi:GetWorld():GetFullName():gsub("^%S+ ", "") .. ":PersistentLevel."
local byClass, n = {}, 0
for _, a in ipairs(FindAllOf("Actor") or {}) do
    if a:IsValid() and a:GetFullName():find(level, 1, true) then
        local c = a:GetClass():GetFName():ToString()
        local marker = c:find("^BP_ClumpedSpawnMarker_") ~= nil
        local origin = false
        if not marker then
            local ok, l = pcall(function() return a:K2_GetActorLocation() end)
            origin = ok and l.X == 0 and l.Y == 0 and l.Z == 0
        end
        if marker or origin then
            local k = (marker and "marker " or "origin ") .. c
            byClass[k] = (byClass[k] or 0) + 1
            n = n + 1
        end
    end
end
local out = {}
for k, v in pairs(byClass) do out[#out + 1] = k .. "=" .. v end
table.sort(out)
return "world=" .. level .. " n=" .. n .. " | " .. table.concat(out, " ")
