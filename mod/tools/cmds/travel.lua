-- Set a fixed master seed and travel to a fixed wilderness map location.
local SEED = tonumber(os.getenv("COOP_SEED") or "") or 12345
local LOC = "MLoc_Wilderness_Forest_07"
local gi = FindFirstOf("DrivingGameInstance")
gi:SetMasterSeed(SEED)
Dev.out("MasterSeed now", gi.MasterSeed)
local target
for _, m in ipairs(FindAllOf("MapLocation") or {}) do
    if m:GetFName():ToString() == LOC then target = m end
end
Dev.out("target", Dev.name(target))
local lm = FindFirstOf("BP_LevelManager_C")
lm:LevelTravel(target)
return "LevelTravel called"
