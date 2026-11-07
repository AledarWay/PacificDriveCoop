-- The host's route map for the lobby's guests in their garages (owner, 2026-10-24: "the host's map, junctions
-- and conditions at the lobby's members"). Probed (NOTES "The garage map"):
--   * the map table draws the main route state (BP_ProgressionManager's BP_RouteState_C) live: RouteShapeWidget
--     paints its LegStates; every player has the same WorldShape (the junction graph, legs RouteShapeLeg_<n>), the
--     legs' state differs: active / discovered / scanned (RevealState), instability, anchors, destination route,
--     modifiers (the conditions: RM_ViciousStorm, RM_PitchBlack, RM_JunctionState_*), and the leg's whiteboard
--     (biome, level / map location, spawn densities, storm timing - what the zone is generated from);
--   * a junction "selection" is not stored: the host hovers and departs (BaseRouteState:TravelTo, session.lua).
-- Host: export() -> rows per leg (L) + its whiteboard tags (W). Guest: apply() writes them into its own route
-- state (fields, modifiers via Remove/ApplyModifier, whiteboard via ClearAllTags / AddTag / SetTagFloat), then
-- UpdateConditions (the derived reveal / navigate flags). The guest's own map is kept in a backup file first and
-- put back once it is out of the lobby in its garage (restore); the backup goes when the guest drives out on its
-- own (that departure saves the restored map).
-- The hazard / boon / event pools (soft class arrays, P rows; owner's alpha 19 item 4: the junction panel's hazards and
-- features differed for the same route; item 15: the guest's zone got a gameplay event of its own leg's pool) - read
-- as paths by KismetSystemLibrary's Conv_SoftClassReferenceToString, written as MakeSoftClassPath ->
-- Conv_SoftClassPathToSoftClassRef into the emptied array (probed 2026-11-04).
local M = {}
-- path lookups: the native one answers a miss at once (UE4SS walks every object then: ~50 ms)
local SFO = StaticFindObject
if CoopNative_HasPath then SFO = function(p) if CoopNative_HasPath(p) then return StaticFindObject(p) end return nil end end

local function pathOf(o)
    if not (o and o.IsValid and o:IsValid()) then return "-" end
    local ok, s = pcall(function() return o:GetFullName() end)
    return ok and (s:gsub("^%S+%s+", "")) or "-"
end
local function elem(e)
    local ok, g = pcall(function() return e:get() end)
    return ok and g or e
end
local function loadObj(p)
    if not p or p == "-" or p == "" then return nil end
    local o = SFO(p)
    if not (o and o:IsValid()) then pcall(function() o = LoadAsset(p) end) o = SFO(p) end
    return (o and o:IsValid()) and o or nil
end
local function b(v) return v and "1" or "0" end
local POOLS = { "CurrentHazardPoolClasses", "CurrentBoonPoolClasses", "CurrentGameplayEventPool" }
local KSL
local function ksl()
    if not (KSL and KSL:IsValid()) then KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
    return KSL
end
-- a leg's pool: its classes' paths, "-" for none
local function poolRead(l, f)
    local r = {}
    pcall(function() l[f]:ForEach(function(_, e) r[#r + 1] = ksl():Conv_SoftClassReferenceToString(e:get()):ToString() end) end)
    return #r > 0 and table.concat(r, ",") or "-"
end
local function poolWrite(l, f, paths)
    local arr = l[f]
    arr:Empty()
    if paths == "-" then return end
    local i = 0
    for p in paths:gmatch("[^,]+") do
        i = i + 1
        arr[i] = ksl():Conv_SoftClassPathToSoftClassRef(ksl():MakeSoftClassPath(p))
    end
end

-- the main route state (the garage map): the progression manager's WorldState - after a run an older route state
-- of the manager lingers (writing into that one changed nothing on the map); not the per-run / expedition ones
function M.route()
    local pm = FindFirstOf("BP_ProgressionManager_C")
    local ok, r = pcall(function() return pm.WorldState end)
    if ok and r and r:IsValid() then return r end
end

local function legs(route)
    local r = {}
    route.LegStates:ForEach(function(k, v) r[#r + 1] = { key = k:get():GetFName():ToString(), leg = v:get() } end)
    table.sort(r, function(a, c) return a.key < c.key end)
    return r
end

-- rows of the route: header, per leg L, per whiteboard tag W
function M.rows()
    local route = M.route()
    if not route then return nil, "no route state" end
    local out = { string.format("R\t%s\t%s", pathOf(route.WorldShape), tostring(route.WorldShapeRandSeed)) }
    for _, e in ipairs(legs(route)) do
        local l = e.leg
        local mods = {}
        pcall(function() for i = 1, #l.AppliedModifiers do mods[#mods + 1] = pathOf(elem(l.AppliedModifiers[i])) end end)
        out[#out + 1] = table.concat({ "L", e.key, b(l.Active), b(l.Discovered), b(l.Revealable), b(l.Visited),
            tostring(l.RevealState), tostring(l.Instability), tostring(l.AnchorRequirement), pathOf(l.DestinationRoute),
            pathOf(l.MapLocation), #mods > 0 and table.concat(mods, ",") or "-", pathOf(l.CoreJunctionModifier),
            pathOf(l.CoreFeatureCachedRM) }, "\t")
        local wb = l.LegWhiteboard
        if wb and wb:IsValid() then
            local tags = wb:GetAllTags(false)
            for i = 1, #tags do
                local name = elem(tags[i]).TagName:ToString()
                local f = wb:GetTagFloat({ TagName = FName(name) }, false, 0)
                out[#out + 1] = string.format("W\t%s\t%s\t%.6g", e.key, name, f)
            end
        end
        for _, f in ipairs(POOLS) do
            local paths = poolRead(l, f)
            if paths ~= "-" then out[#out + 1] = table.concat({ "P", e.key, f, paths }, "\t") end
        end
    end
    return out
end

-- the host's documents: "doc:<name>" = in memory (the in-game network, link.lua), else a file
local function readText(p)
    if CoopSyncRead then return CoopSyncRead(p) end
    local f = p and io.open(p, "rb")
    if not f then return nil end
    local s = f:read("*a") f:close()
    return s
end
local function writeText(p, s)
    if CoopSyncWrite then return CoopSyncWrite(p, s) end
    local f = io.open(p .. ".tmp", "wb")
    if not f then return false end
    f:write(s) f:close()
    os.remove(p)
    return os.rename(p .. ".tmp", p)
end
local function writeAtomic(path, lines) return writeText(path, table.concat(lines, "\n") .. "\n") end
local function readLines(path)
    local s = readText(path)
    if not s then return nil end
    local r = {}
    for line in s:gmatch("[^\r\n]+") do r[#r + 1] = line end
    return r
end

-- a cheap signature of the legs (~2 ms; the full rows take ~30 ms): what a scan, a hover (map location) or a
-- reroll changes
function M.quickSig()
    local route = M.route()
    if not route then return nil end
    local parts = {}
    route.LegStates:ForEach(function(k, v)
        local l = v:get()
        parts[#parts + 1] = tostring(l.RevealState) .. tostring(l.Discovered) .. tostring(l.Active) .. tostring(l.Instability)
            .. (l.MapLocation and l.MapLocation:IsValid() and "m" or "-") .. #l.AppliedModifiers
    end)
    return table.concat(parts, ",")
end

-- Host: the map rows into path when they changed since the last export (a signature of the rows). The full rows
-- are made only when the cheap signature changed, or every FULL_S seconds (whiteboard-only changes).
local lastSig, lastQuick, lastFull = nil, nil, -1e9
local FULL_S = 30
function M.export(path, force)
    local q = M.quickSig()
    if not force and q == lastQuick and os.clock() - lastFull < FULL_S then return false end
    lastQuick, lastFull = q, os.clock()
    local rows, e = M.rows()
    if not rows then return nil, e end
    local sig = table.concat(rows, "\n")
    if sig == lastSig and not force then return false end
    if not writeAtomic(path, rows) then return nil, "cannot write " .. path end
    lastSig = sig
    return #rows
end

local function split(line)
    local t = {}
    for v in (line .. "\t"):gmatch("([^\t]*)\t") do t[#t + 1] = v end
    return t
end

-- Write rows into this game's route state. Returns the number of legs set, the misses.
function M.applyRows(rows)
    local route = M.route()
    if not route then return nil, "no route state" end
    local byKey = {}
    for _, e in ipairs(legs(route)) do byKey[e.key] = e.leg end
    local tags = {} -- key -> { {name, value} }
    local pools = {} -- key -> { field -> paths } (a pool without a row: empty)
    local n, miss = 0, {}
    for _, line in ipairs(rows) do
        local t = split(line)
        if t[1] == "R" then
            if pathOf(route.WorldShape) ~= t[2] then return nil, "other world shape: " .. tostring(t[2]) end
            if tonumber(t[3]) then pcall(function() route.WorldShapeRandSeed = tonumber(t[3]) end) end
        elseif t[1] == "W" then
            tags[t[2]] = tags[t[2]] or {}
            table.insert(tags[t[2]], { t[3], tonumber(t[4]) or 0 })
        elseif t[1] == "P" then
            pools[t[2]] = pools[t[2]] or {}
            pools[t[2]][t[3]] = t[4]
        elseif t[1] == "L" then
            local l = byKey[t[2]]
            if not l then miss[#miss + 1] = t[2]
            else
                local ok, err = pcall(function()
                    l.Active, l.Discovered, l.Revealable, l.Visited = t[3] == "1", t[4] == "1", t[5] == "1", t[6] == "1"
                    l.RevealState = tonumber(t[7]) or 0
                    l.Instability = tonumber(t[8]) or 0
                    l.AnchorRequirement = tonumber(t[9]) or 0
                    l.DestinationRoute = loadObj(t[10])
                    l.MapLocation = loadObj(t[11])
                    l.CoreJunctionModifier = loadObj(t[13])
                    l.CoreFeatureCachedRM = loadObj(t[14])
                    -- the modifiers: off what the guest's leg has, on what the host's has
                    local have = {}
                    for i = 1, #l.AppliedModifiers do have[#have + 1] = elem(l.AppliedModifiers[i]) end
                    for _, m in ipairs(have) do l:RemoveModifier(m) end
                    if t[12] ~= "-" then
                        for p in t[12]:gmatch("[^,]+") do
                            local m = loadObj(p)
                            if m then l:ApplyModifier(m, true) end
                        end
                    end
                end)
                if ok then n = n + 1 else miss[#miss + 1] = t[2] .. ":" .. tostring(err) end
            end
        end
    end
    -- the whiteboards after the modifiers (applying a modifier writes its tags too)
    for key, list in pairs(tags) do
        local l = byKey[key]
        local wb = l and l.LegWhiteboard
        if wb and wb:IsValid() then
            pcall(function()
                wb:ClearAllTags()
                for _, tv in ipairs(list) do
                    local tag = { TagName = FName(tv[1]) }
                    wb:AddTag(tag, false)
                    if tv[2] ~= 0 then wb:SetTagFloat(tag, tv[2]) end
                end
            end)
        end
    end
    -- the pools after the modifiers too (a modifier's hazards go into the pool)
    for key, l in pairs(byKey) do
        local want = pools[key] or {}
        for _, f in ipairs(POOLS) do
            if poolRead(l, f) ~= (want[f] or "-") then pcall(poolWrite, l, f, want[f] or "-") end
        end
    end
    pcall(function() route:UpdateConditions() end)
    return n, miss
end

function M.hasBackup(backupPath)
    local f = io.open(backupPath, "rb")
    if f then f:close() return true end
    return false
end

-- Guest: apply the host's map file; the guest's own map goes to backupPath first (once: an existing backup is the
-- guest's own map from before an earlier lobby, not to be overwritten by a mirrored one).
function M.apply(path, backupPath)
    local rows = readLines(path)
    if not rows or #rows < 2 then return nil, "no host map at " .. path end
    if backupPath and not M.hasBackup(backupPath) then
        local own = M.rows()
        if own then writeAtomic(backupPath, own) end
    end
    local n, miss = M.applyRows(rows)
    if not n then return nil, miss end
    return string.format("map: %d legs from the host%s", n, #miss > 0 and (" (missing: " .. table.concat(miss, " "):sub(1, 120) .. ")") or "")
end

-- Guest: back to its own map (the backup stays until a solo departure saves it: forget()).
function M.restore(backupPath)
    local rows = readLines(backupPath)
    if not rows then return nil, "no backup" end
    local n, miss = M.applyRows(rows)
    if not n then return nil, miss end
    return string.format("map: own map back (%d legs)", n)
end
function M.forget(backupPath) os.remove(backupPath) end

-- a short signature for tests: legs active / discovered / scanned, modifier count, whiteboard tag count
function M.summary()
    local rows = M.rows()
    if not rows then return "no route" end
    local a, d, s, m, w = 0, 0, 0, 0, 0
    for _, line in ipairs(rows) do
        local t = split(line)
        if t[1] == "L" then
            if t[3] == "1" then a = a + 1 end
            if t[4] == "1" then d = d + 1 end
            if t[7] ~= "0" then s = s + 1 end
            if t[12] ~= "-" then for _ in t[12]:gmatch("[^,]+") do m = m + 1 end end
        elseif t[1] == "W" then w = w + 1 end
    end
    return string.format("active=%d discovered=%d scanned=%d mods=%d tags=%d", a, d, s, m, w)
end

return M
