-- Experiment: make unseeded Kismet random nodes deterministic during zone generation.
-- A Lua LCG replaces the global FMath::Rand-backed results; it is reset when the zone level changes.
local LOG = "C:/PacificDriveCoop/local/coopdev/seedprobe.log"
local function log(s) local f = io.open(LOG, "ab") f:write(os.date("%H:%M:%S ") .. s .. "\n") f:close() end

local SEED = 424242
local state = SEED
local calls = 0
local function nextu() -- [0,1)
    state = (state * 1103515245 + 12345) % 2147483648
    calls = calls + 1
    return state / 2147483648
end
local function arg(p) local ok, v = pcall(function() return p:get() end) return ok and v or 0 end

local K = "/Script/Engine.KismetMathLibrary:"
RegisterHook(K .. "RandomFloat", function() return nextu() end)
RegisterHook(K .. "RandomFloatInRange", function(_, mn, mx) local a, b = arg(mn), arg(mx) return a + (b - a) * nextu() end)
RegisterHook(K .. "RandomInteger", function(_, mx) local m = arg(mx) if m <= 0 then return 0 end return math.floor(nextu() * m) end)
RegisterHook(K .. "RandomIntegerInRange", function(_, mn, mx) local a, b = arg(mn), arg(mx) if b < a then return a end return a + math.floor(nextu() * (b - a + 1)) end)
RegisterHook(K .. "RandomBool", function() return nextu() < 0.5 end)
RegisterHook(K .. "RandomBoolWithWeight", function(_, w) return nextu() < arg(w) end)

local BP = "/Game/Systems/Managers/BP_SpawningManager.BP_SpawningManager_C:"
RegisterHook(BP .. "K2_PreLevelChange", function()
    log("det-random reset at PreLevelChange (calls before reset: " .. calls .. ")")
    state = SEED calls = 0
end)
RegisterHook(BP .. "Execute Spawn Leafs", function() log("det-random at ExecuteSpawnLeafs: calls so far " .. calls) end)
RegisterHook(BP .. "Execute Spawning Complete", function() log("det-random at SpawningComplete: calls so far " .. calls) end)
return "deterministic random installed"
