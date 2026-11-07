-- Logs the spawner's inputs at the moment native spawn strategies start.
local LOG = "C:/PacificDriveCoop/local/coopdev/seedprobe.log"
local function log(s) local f = io.open(LOG, "ab") f:write(os.date("%H:%M:%S ") .. s .. "\n") f:close() end
local function count(cls) local l = FindAllOf(cls) return l and #l or 0 end

local function snap(tag, extra)
    local w = FindFirstOf("DrivingGameInstance"):GetWorld()
    local loaded, total = 0, 0
    pcall(function()
        for i = 1, w.StreamingLevels:GetArrayNum() do
            total = total + 1
            local sl = w.StreamingLevels[i]
            if sl:IsLevelLoaded() then loaded = loaded + 1 end
        end
    end)
    log(string.format("%s %s levels %d/%d SpawnPointActor=%d SpawnScatterVolume=%d SpawnModifierActor=%d BP_SpawnPoint_C=%d BaseSiteSpawnerActor=%d LootableTemplate=%d",
        tag, extra or "", loaded, total, count("SpawnPointActor"), count("SpawnScatterVolume"), count("SpawnModifierActor"),
        count("BP_SpawnPoint_C"), count("BaseSiteSpawnerActor"), count("LootableTemplate")))
end

RegisterHook("/Script/PenDriverPro.SpawnStrategy:ExecuteSpawnStrategyAmortized", function(_, wc, latent, cls, overrides, budget)
    local b, c = "?", "?"
    pcall(function() b = tostring(budget:get()) end)
    pcall(function() c = cls:get():GetFName():ToString() end)
    snap("ExecuteSpawnStrategyAmortized", "class=" .. c .. " budget=" .. b)
end)
RegisterHook("/Script/PenDriverPro.SpawnStrategy:ExecuteSpawnStrategy", function(_, wc, cls)
    local c = "?"
    pcall(function() c = cls:get():GetFName():ToString() end)
    snap("ExecuteSpawnStrategy", "class=" .. c)
end)
local BP = "/Game/Systems/Managers/BP_SpawningManager.BP_SpawningManager_C:"
RegisterHook(BP .. "Execute Spawn Leafs", function() snap("ExecuteSpawnLeafs") end)
RegisterHook(BP .. "Execute Spawning Complete", function() snap("SpawningComplete") end)
return "spawn input probes installed"
