-- Experiment: right before zone spawning, overwrite the non-deterministic random channels.
local LOG = "C:/PacificDriveCoop/local/coopdev/seedprobe.log"
local function log(s) local f = io.open(LOG, "ab") f:write(os.date("%H:%M:%S ") .. s .. "\n") f:close() end

local function seeds(rm)
    local t = {}
    for i = 1, rm.StreamSeeds:GetArrayNum() do t[#t + 1] = tostring(rm.StreamSeeds[i]) end
    return table.concat(t, ",") .. " stream=" .. tostring(rm.MyCurrentStream.Seed)
end

local function pin(where)
    local rm = FindFirstOf("BP_RandomManager_C")
    log(where .. " before: " .. seeds(rm))
    if rm.StreamSeeds:GetArrayNum() >= 2 then
        rm.StreamSeeds[1] = 111111
        rm.StreamSeeds[2] = 222222
    end
    local ok, err = pcall(function() rm.MyCurrentStream = { InitialSeed = 333, Seed = 333 } end)
    if not ok then log("stream write failed: " .. tostring(err)) end
    log(where .. " after: " .. seeds(rm))
end

local BP = "/Game/Systems/Managers/BP_SpawningManager.BP_SpawningManager_C:"
RegisterHook(BP .. "K2_PostLevelChange", function() pin("PostLevelChange") end)
RegisterHook(BP .. "Execute Spawn Leafs", function() pin("ExecuteSpawnLeafs") end)
return "hooks registered"
