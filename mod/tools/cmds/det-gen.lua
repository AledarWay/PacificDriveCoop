-- Experiment (2026-10-23): can two games generate the same zone? Everything known to vary per run is pinned:
--   * BP_RandomManager_C.StreamSeeds ch0/ch1 + MyCurrentStream and the route state's WorldShapeRandSeed (native,
--     per-run values) -> constants at the zone's PreLevelChange / PostLevelChange / Execute Spawn Leafs;
--   * unseeded Kismet random nodes -> a Lua LCG, reset at PreLevelChange;
--   * the native spawn strategy runs amortized over frames with a time budget, so other actors' per-tick random
--     calls interleaved with the generator's: AllottedTimePerFrame -> 1000 s (everything in one frame).
-- DETGEN_NO_BUDGET / DETGEN_NO_RANDOM / DETGEN_NO_PIN (set before this file) switch parts off; DETGEN_RESET_AT_STRATEGY
-- resets the LCG when the spawn strategy starts (the level load before it makes a different number of calls).
local LOG = "C:/PacificDriveCoop/local/coopdev/detgen.log"
local function log(s) local f = io.open(LOG, "ab") f:write(os.date("%H:%M:%S ") .. s .. "\n") f:close() end
DETGEN_STATE = DETGEN_STATE or { state = 424242, calls = 0, budgetHits = 0 }
local D = DETGEN_STATE
local SEED = 424242

local function nextu()
    D.state = (D.state * 1103515245 + 12345) % 2147483648
    D.calls = D.calls + 1
    return D.state / 2147483648
end
local function arg(p) local ok, v = pcall(function() return p:get() end) return ok and v or 0 end

local function pin(where)
    if DETGEN_NO_PIN then return end
    local rm = FindFirstOf("BP_RandomManager_C")
    if rm and rm:IsValid() and rm.StreamSeeds:GetArrayNum() >= 2 then
        rm.StreamSeeds[1] = 111111
        rm.StreamSeeds[2] = 222222
        pcall(function() rm.MyCurrentStream = { InitialSeed = 333, Seed = 333 } end)
    end
    local n = 0
    for _, r in ipairs(FindAllOf("BaseRouteState") or {}) do
        if r:IsValid() and not r:GetFullName():find("Default__", 1, true) then
            pcall(function() r.WorldShapeRandSeed = 777 n = n + 1 end)
        end
    end
    log(where .. ": pinned (route states " .. n .. "), lcg calls " .. D.calls)
end

if not D.hooked then
    D.hooked = true
    if not DETGEN_NO_RANDOM then
        local K = "/Script/Engine.KismetMathLibrary:"
        RegisterHook(K .. "RandomFloat", function() return nextu() end)
        RegisterHook(K .. "RandomFloatInRange", function(_, mn, mx) local a, b = arg(mn), arg(mx) return a + (b - a) * nextu() end)
        RegisterHook(K .. "RandomInteger", function(_, mx) local m = arg(mx) if m <= 0 then return 0 end return math.floor(nextu() * m) end)
        RegisterHook(K .. "RandomIntegerInRange", function(_, mn, mx) local a, b = arg(mn), arg(mx) if b < a then return a end return a + math.floor(nextu() * (b - a + 1)) end)
        RegisterHook(K .. "RandomBool", function() return nextu() < 0.5 end)
        RegisterHook(K .. "RandomBoolWithWeight", function(_, w) return nextu() < arg(w) end)
    end
    if not DETGEN_NO_BUDGET then
        RegisterHook("/Script/PenDriverPro.SpawnStrategy:ExecuteSpawnStrategyAmortized", function(_, _, _, _, _, budget)
            local before = arg(budget)
            pcall(function() budget:set(1000.0) end)
            D.budgetHits = D.budgetHits + 1
            if DETGEN_RESET_AT_STRATEGY then D.state, D.calls = SEED, 0 end
            log(string.format("ExecuteSpawnStrategyAmortized: budget %.3f -> %.1f, lcg calls %d", before, arg(budget), D.calls))
        end)
    end
    local BP = "/Game/Systems/Managers/BP_SpawningManager.BP_SpawningManager_C:"
    RegisterHook(BP .. "K2_PreLevelChange", function()
        log("PreLevelChange: lcg reset (calls before " .. D.calls .. ")")
        D.state, D.calls = SEED, 0
        pin("PreLevelChange")
    end)
    RegisterHook(BP .. "K2_PostLevelChange", function() pin("PostLevelChange") end)
    RegisterHook(BP .. "Execute Spawn Leafs", function() pin("ExecuteSpawnLeafs") end)
    RegisterHook(BP .. "Execute Spawning Complete", function() log("SpawningComplete: lcg calls " .. D.calls) end)
end
return string.format("det-gen hooks in (budget %s, random %s, pin %s)", tostring(not DETGEN_NO_BUDGET), tostring(not DETGEN_NO_RANDOM), tostring(not DETGEN_NO_PIN))
