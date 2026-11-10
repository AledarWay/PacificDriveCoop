-- Each car's own handling (owner, 2026-11-09: "after we swapped cars the cars' characteristics swapped: my upgraded
-- fast car and the friend's starting slow one behaved the other way round").
-- A car's physics (IWCarPhysics VehicleControllerComponent) drives by its Profile, and every BP_PlayerCarNew_C's is
-- the one asset /Game/Characters/PlayerCar/TuningProfiles/MainTuningGraph (one object, probed 2026-11-10). Each car's
-- AC_CarHandling writes its parameters into the context car's Profile every tick (IWTuningGraph SetParameter; the car
-- manager's NewCarActor): the ones from the parts (engine, the tires' kinds, flats, boost: PARTS) and the ones of the
-- moment (speed, slopes, surface, park), which every handling computes for the context car. The parts are the local
-- player's own (the handling reads them through the car manager: the twin's handling's wheel values on the host became
-- the host's offroad tires when asked, PartProperty_Wheel; the twin's own parts never reached it). So both cars drove
-- by one graph - a car the last writer's (the guest's own car, the same 4 s of full throttle from the same spot: 1800
-- with the twin's handling stopped, 2300-3150 with it running), the context car's graph got the two handlings' tires
-- in turn (the host on offroad tires: 0.9 / 0.09 by turns), and a player in the other's car drove it on the own parts.
-- Now:
--   * each car drives by a graph of its own (a copy of the asset: the graph and each of its nodes - 191, shared within
--     the graph - constructed with the original as the template, the children pointed at the copies; started with the
--     asset's parameters), so the moment's parameters land in the context car's only;
--   * the graphs' SetParameter is hooked (the part writes kept); when one of a handling's functions ends (ReceiveTick,
--     the profile updates; UE4SS's hooks run after the body) the writes made meanwhile are that handling's: the own
--     car's handling's are the own car's parts (kept, and set on its graph), and every graph written gets its own car's
--     values back - the own car's from its handling, the other's car's from its owner;
--   * the own car's part values go to the other side (TU lines, playersync), which sets them on its twin's graph.
--   Only while both cars are there.
--   TU <time> <name>=<value>,...    the own car's part parameters (changed: checked every 1 s; and every 10 s)
local M = {}
local ASSET = "/Game/Characters/PlayerCar/TuningProfiles/MainTuningGraph.MainTuningGraph"
local SET = "/Script/IWCarPhysics.IWTuningGraph:SetParameter"
local HANDLING = "/Game/Characters/PlayerCar/Components/AC_CarHandling.AC_CarHandling_C:"
local AFTER = { "ReceiveTick", "UpdateProfileOnParking", "UpdateBaseCarGameplayOptions", "InitializeTuningConstants" }
-- the parameters the handling writes (probed: SetParameter hooked, 2026-11-10)
local NAMES = { "AcellBoost", "CarHandling_Less", "CarHandling_More", "Dirtroad", "DownSlope", "EngineDamage",
    "EngineDamage_Setting", "EnginePower_Less", "EnginePower_More", "EngineQuality", "FlatTire", "FlatTire_Setting",
    "FlatTire_Setting_HasFlat", "Gravel", "Gravel_Setting", "Mud", "MudTraction", "Mud_Setting", "OffRoad_Setting",
    "Offroad", "Park", "Rain", "Road", "Sand", "Slomo", "Speed", "UpSlope", "Water", "Water_Setting", "WheelDirtRoad",
    "WheelGravel", "WheelMud", "WheelOffroad", "WheelPower", "WheelRain", "WheelRoad", "WheelSand", "WheelWater" }
-- the ones from the car's parts (the *_Setting ones are the player's game options; surface / speed / slopes / park /
-- slomo the moment's)
local PARTS = {}
for _, n in ipairs({ "AcellBoost", "CarHandling_Less", "CarHandling_More", "EngineDamage", "EnginePower_Less",
    "EnginePower_More", "EngineQuality", "FlatTire", "FlatTire_Setting_HasFlat", "MudTraction", "WheelDirtRoad",
    "WheelGravel", "WheelMud", "WheelOffroad", "WheelPower", "WheelRain", "WheelRoad", "WheelSand", "WheelWater" }) do PARTS[n] = true end
M.PARTS = PARTS

-- one state per Lua state: the hooks stay registered across module reloads (they call T.onSet / T.onAfter)
CoopSyncTuning = CoopSyncTuning or {}
local T = CoopSyncTuning
T.graphs, T.carOfGraph, T.ownVals, T.pend, T.n = T.graphs or {}, T.carOfGraph or {}, T.ownVals or {}, T.pend or {}, T.n or 0
T.stats = T.stats or {}
for _, k in ipairs({ "copies", "writes", "moved", "restored", "errors" }) do T.stats[k] = T.stats[k] or 0 end
M.T = T

local VC
local function vcOf(car)
    VC = VC or StaticFindObject("/Script/IWCarPhysics.VehicleControllerComponent")
    return car:GetComponentByClass(VC)
end
local fnames = {}
local function fn(n) local f = fnames[n] if not f then f = FName(n) fnames[n] = f end return f end

-- the asset's deep copy (its outer: the car's controller, so it goes with the car), started with the values of
-- `from` (the car's graph before, else the asset)
local function copyGraph(g, outer, from)
    local memo = {}
    local function node(n)
        local k = n:GetAddress()
        if memo[k] then return memo[k] end
        local c = StaticConstructObject(n:GetClass(), outer, FName("None"), 0, 0, false, false, n)
        memo[k] = c
        for i = 1, n.Children:GetArrayNum() do c.Children[i] = node(n.Children[i]) end
        return c
    end
    local cg = StaticConstructObject(g:GetClass(), outer, FName("None"), 0, 0, false, false, g)
    cg.FirstNode = node(g.FirstNode)
    local src = from or g
    for _, n in ipairs(NAMES) do pcall(function() cg:SetParameter(fn(n), src:GetParameter(fn(n))) end) end
    return cg
end

function T.onSet(self, name, value)
    if not T.on or T.flushing then return end
    local ok = pcall(function()
        local gk = self:get():GetAddress()
        if not T.carOfGraph[gk] then return end
        local key = name:get():ToString()
        if not PARTS[key] then return end
        T.n = T.n + 1
        local w = T.pend[T.n]
        if w then w[1], w[2], w[3] = gk, key, value:get() else T.pend[T.n] = { gk, key, value:get() } end
    end)
    if ok then T.stats.writes = T.stats.writes + 1 else T.stats.errors = T.stats.errors + 1 end
end
-- the part value a car's graph must hold: the own car's - what its own handling wrote last; the other's - its owner's
local function truth(ck, key)
    if ck == T.own then return T.ownVals[key] end
    return T.owner and T.owner[key]
end
function T.onAfter(ctx)
    if not T.on or T.n == 0 then return end
    T.flushing = true
    local ok, e = pcall(function()
        local car = ctx:get():GetOwner()
        local writer = car and car:IsValid() and car:GetAddress()
        local ownG = T.graphs[T.own]
        for i = 1, T.n do
            local w = T.pend[i]
            local key = w[2]
            -- (the own car's handling: its car's parts - kept, and into its graph wherever it wrote)
            if writer == T.own then
                T.ownVals[key] = w[3]
                if ownG and ownG:IsValid() and w[1] ~= ownG:GetAddress() then ownG:SetParameter(fn(key), w[3]) T.stats.moved = T.stats.moved + 1 end
            end
            -- (the graph written: its own car's value back where the writer was not that car's own handling)
            local target = T.carOfGraph[w[1]]
            if target and not (target == T.own and writer == T.own) then
                local v = truth(target, key)
                local tg = T.graphs[target]
                if v ~= nil and tg and tg:IsValid() then tg:SetParameter(fn(key), v) T.stats.restored = T.stats.restored + 1 end
            end
        end
    end)
    T.flushing = false
    T.n = 0
    if not ok then T.stats.errors = T.stats.errors + 1 T.stats.lastErr = tostring(e) end
end
local function hook()
    if T.hooked then return true end
    local Hooks = CoopSyncHook or dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "hooks.lua").hook
    if not Hooks then return false end
    T.hooked = true
    Hooks(SET, function(...) return T.onSet(...) end)
    for _, f in ipairs(AFTER) do Hooks(HANDLING .. f, function(...) return T.onAfter(...) end) end
    return true
end

-- every 0.5 s (playersync): own car and the twin (nil: none). Each gets its own graph while both are there.
function M.tick(own, twin)
    local both = own and twin and own:IsValid() and twin:IsValid()
    if not both then T.on, T.n = false, 0 return end
    if not hook() then return end
    local g = StaticFindObject(ASSET)
    if not (g and g:IsValid()) then return end
    for _, car in ipairs({ own, twin }) do
        local k = car:GetAddress()
        local vc = vcOf(car)
        local cur = T.graphs[k]
        if vc and vc:IsValid() and not (cur and cur:IsValid() and vc.Profile:IsValid() and vc.Profile:GetAddress() == cur:GetAddress()) then
            -- (a car's graph made again - its profile put back to the asset by the game, or a new car: started with
            -- the car's graph before, and its part values put on. The asset's, which nothing writes once the cars have
            -- copies, left the guest's own car at engine 0 after the rides in the other's car: cars-test 2026-11-10)
            local okC, cg = pcall(copyGraph, g, vc, cur and cur:IsValid() and cur or nil)
            local ok = okC
            if ok and cg and cg:IsValid() then
                local vals = (car:GetAddress() == own:GetAddress()) and T.ownVals or T.owner
                if vals then for n, v in pairs(vals) do pcall(function() cg:SetParameter(fn(n), v) end) end end
                vc.Profile = cg
                T.graphs[k] = cg
                T.carOfGraph[cg:GetAddress()] = k
                T.stats.copies = T.stats.copies + 1
            else
                T.stats.errors = T.stats.errors + 1
                T.stats.lastErr = tostring(cg)
            end
        end
    end
    for k, cg in pairs(T.graphs) do if not cg:IsValid() then T.graphs[k] = nil end end
    for gk, k in pairs(T.carOfGraph) do if not T.graphs[k] then T.carOfGraph[gk] = nil end end
    T.own, T.twin = own:GetAddress(), twin:GetAddress()
    T.on = true
    M.applyTwin()
end

-- the other's car's graph: its owner's part values (on each line and every tick: a write there in between is put back
-- after the writer's function, this keeps it so between lines too)
function M.applyTwin()
    local g = T.twin and T.graphs[T.twin]
    if not (T.owner and g and g:IsValid()) then return end
    T.flushing = true
    for n, v in pairs(T.owner) do pcall(function() g:SetParameter(fn(n), v) end) end
    T.flushing = false
end
-- the own car's part parameters (what its own handling wrote last) as the TU line's field; nil: none yet
function M.ownLine()
    local t = {}
    for n in pairs(PARTS) do local v = T.ownVals[n] if type(v) == "number" then t[#t + 1] = string.format("%s=%.4g", n, v) end end
    table.sort(t)
    return #t > 0 and table.concat(t, ",") or nil
end
-- the other's: its owner's part parameters for its car here
function M.applyOwner(field)
    local o = {}
    for n, v in (field or ""):gmatch("([%w_]+)=([%-%d%.eE+]+)") do if PARTS[n] then o[n] = tonumber(v) end end
    if next(o) then T.owner = o end
    T.stats.received = (T.stats.received or 0) + 1
    M.applyTwin()
end

function M.graphOf(car) local g = car and T.graphs[car:GetAddress()] return g and g:IsValid() and g or nil end
function M.param(car, name)
    local g = M.graphOf(car)
    if not g then return nil end
    local ok, v = pcall(function() return g:GetParameter(fn(name)) end)
    return ok and v or nil
end

function M.info()
    local s = T.stats
    return string.format("tuning on=%s copies=%d writes=%d moved=%d restored=%d received=%d errors=%d%s", tostring(T.on), s.copies,
        s.writes, s.moved, s.restored, s.received or 0, s.errors, s.lastErr and (" " .. s.lastErr:sub(1, 80)) or "")
end
return M
