-- Prints every known seed value in the current game state.
local gi = FindFirstOf("DrivingGameInstance")
Dev.out("MasterSeed", gi.MasterSeed, "state", gi.CurrentGameplayState, "world", gi:GetWorld():GetFName():ToString())

local sm = FindFirstOf("BP_SpawningManager_C")
if sm then Dev.out("SpawningManager.CurrentSpawnSeed", sm.CurrentSpawnSeed) end

local rm = FindFirstOf("BP_RandomManager_C")
if rm then
    local t = {}
    for i = 1, rm.StreamSeeds:GetArrayNum() do t[#t + 1] = tostring(rm.StreamSeeds[i]) end
    Dev.out("RandomManager.StreamSeeds", table.concat(t, ","))
    pcall(function() Dev.out("RandomManager.MyCurrentStream", rm.MyCurrentStream.InitialSeed, rm.MyCurrentStream.Seed) end)
end

for _, rs in ipairs(FindAllOf("RandomState") or {}) do
    local t = {}
    for ch = 0, 14 do
        local ok, s = pcall(function() return rs:GetSeed(ch) end)
        local ok2, s0 = pcall(function() return rs:GetInitialSeed(ch) end)
        t[#t + 1] = string.format("%d:%s/%s", ch, ok and tostring(s) or "?", ok2 and tostring(s0) or "?")
    end
    Dev.out("RandomState", Dev.name(rs), table.concat(t, " "))
end

for _, r in ipairs(FindAllOf("BaseRouteState") or {}) do
    Dev.out("Route", r:GetFName():ToString(), "WorldShapeRandSeed", r.WorldShapeRandSeed)
end
return "done"
