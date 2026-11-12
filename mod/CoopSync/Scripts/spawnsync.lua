-- Spawn replication v2: host exports gameplay actors, client makes its zone match the host's.
-- Format (TSV): Kind  ClassPath  X Y Z  Pitch Yaw Roll  SX SY SZ  Key  Loot (see lootsync.lua)
--   Kind L = level-placed actor (stable Key = its path in the level package, same on every machine)
--   Kind R = runtime-spawned actor (Key = its name, only informative)
--   Kind D = derived actor, created by another actor on BeginPlay; not replicated, listed for scoring
--   optional 14th column Variant: the building class a site spawner built (BP_Spawner_Building_*)
local M = {}
-- path lookups: the native one answers a miss at once (UE4SS walks every object then: ~50 ms)
local SFO = StaticFindObject
if CoopNative_HasPath then SFO = function(p) if CoopNative_HasPath(p) then return StaticFindObject(p) end return nil end end
local DIR = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local Loot = dofile(DIR .. "lootsync.lua")
M.Loot = Loot

-- Classes whose instances are generated / randomized per run and must look the same for everyone.
local PATTERNS = {
    "^BP_Lootable_", "^BP_WorldItem", "^BP_Spawn_", "^BP_Hazard", "^BP_Template_",
    "^BP_Resource_", "^BP_Destruct_", "^BP_TpoleTool", "^BP_VolCascade", "^BP_RoadObstruct",
    "^BP_Spawner_Building_", "^BP_Spawner_Site_", -- site spawners (see SITE_SPAWNER below)
    "^BP_LevelTransition_ExitPortal_", -- exits home: placed per run (the guest had its own, elsewhere: alpha 18 item 40)
}
-- Site spawners: the zone generator places them at random spots (GUID names, so no stable key) and each
-- builds its building / train car / container on its own spot. A host spawner spawned on the client builds
-- the same thing there (observed: a train flatbed spawner, frame + prefab cargo within seconds), so the
-- spawners are replicated and the client's own are removed together with what they built (removing only
-- the building frames and leaving the spawner crashed the client on its next travel). Car spawners are
-- not: their wrecks are replicated as BP_Template_*.
local SITE_SPAWNER = { "^BP_Spawner_Building_", "^BP_Spawner_Site_" }
local SITE_PRODUCTS = { "^BP_BuildingFrame_", "^PrefabSettingsActor$", "^BP_Container_" }
local EXCLUDE = {
    "^BP_Resource_Narrative_",    -- quest items are fixed level content
    "^BP_TemplatePart_",          -- parts belong to their template
    "^BP_Spawn_PreHazardHelper_", -- spawns hazards itself on BeginPlay; we replicate its results instead
}
-- Created by another replicated actor when it spawns: never spawn or destroy these ourselves.
local DERIVED = {
    "^BP_WorldItem_Resource_GasPumpHandle", -- created by BP_Resource_GasPumpBase
    "^BP_VolCascade_",                      -- created by radiation hazards when they spawn
}
-- a client derived actor this close to a host one of its class is the same (kept at import)
local DERIVED_TOL = 50
-- a client actor its name did not match this close to a host one of its class is the same (kept at import): over the
-- host's exact zone (its save loaded) the runtime actors are the host's, under new names (owner 2026-11-11: the import
-- over it still removed and spawned hundreds, 11.7 s)
local RUNTIME_TOL = 50

local function anyMatch(list, s)
    for _, p in ipairs(list) do if s:find(p) then return true end end
    return false
end
local function clsName(a) return a:GetClass():GetFName():ToString() end
function M.matches(cls) return anyMatch(PATTERNS, cls) and not anyMatch(EXCLUDE, cls) end
function M.isDerived(cls) return anyMatch(DERIVED, cls) end

local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
-- GC purges incrementally: objects flagged Unreachable stay in GUObjectArray for a few frames while
-- being torn down, and IsValid() only checks PendingKill. Touching them crashes, so check that first.
local UNREACHABLE = EInternalObjectFlags and EInternalObjectFlags.Unreachable or nil
-- One native flag test (Unreachable | PendingKill) instead of the KismetSystemLibrary:IsValid UFunction
-- call, which was most of the per-actor cost of collect() (34 ms for ~4000 actors).
local DEAD = UNREACHABLE and EInternalObjectFlags.PendingKill and (UNREACHABLE | EInternalObjectFlags.PendingKill) or nil
local function usable(o)
    if not (o and o:IsValid()) then return false end
    if DEAD then return not o:HasAnyInternalFlags(DEAD) end
    if UNREACHABLE and o:HasAnyInternalFlags(UNREACHABLE) then return false end
    return KSL:IsValid(o)
end
CoopSyncUsable = usable

-- Attach parent via properties, validating every link. The native GetAttachParentActor() reads the
-- parent component through a raw pointer and crashed (AV at 0x12) right after parts were destroyed.
local function parentOf(a)
    local ok, p = pcall(function()
        local rc = a.RootComponent
        if not usable(rc) then return nil end
        local pc = rc.AttachParent
        if not usable(pc) then return nil end
        local owner = pc:GetOwner()
        if usable(owner) then return owner end
        return nil
    end)
    return ok and p or nil
end
M.parentOf = parentOf
CoopSyncParentOf = parentOf
local function alive(a) return usable(a) end
local function isReplicated(a) return usable(a) and M.matches(clsName(a)) end -- (rarely called: parents only)
local function key(a) return (a:GetFullName():gsub("^%S+ ", "")) end

-- Runtime-spawned actors get generated names ending in a large index (e.g. _2147450724).
local function isRuntime(a)
    local idx = tonumber(a:GetFName():ToString():match("_(%d+)$") or "")
    return idx ~= nil and idx > 2000000000
end

-- Replicated parents that do not create what is attached under them: road obstructions carry prefab
-- children (cones, signs) placed by the zone generator, and a rock spawned on the client comes bare.
local CONTAINERS = { "^BP_RoadObstruct_" }

-- Root = no ancestor in the attach chain is itself a replicated actor (level containers are fine).
local function isRoot(a)
    local p, guard = parentOf(a), 0
    while p and p:IsValid() and guard < 16 do
        if isReplicated(p) and not anyMatch(CONTAINERS, clsName(p)) then return false end
        if clsName(p) == "BP_PlayerCarNew_C" then return false end
        p = parentOf(p)
        guard = guard + 1
    end
    return true
end
M.isRoot = isRoot

-- skip transient/template objects that are not in a level (e.g. /Engine/Transient.*)
local function inWorld(a) return a:GetFullName():find(":PersistentLevel%.") ~= nil end

-- Pooled actors (APooledActor, e.g. world items) waiting unused in their pool are not part of the world.
-- bPooled is true for every pool-managed actor (active ones too); an idle item manifestation is the
-- one without an item Instance (observed: 42 idle without, 94 in use with an Instance) or one parked
-- at 0,0,0 after being removed from the world.
local PooledClass = StaticFindObject("/Script/PenDriverUtils.PooledActor")
local ItemActorClass = StaticFindObject("/Script/PenDriverInventory.ItemActorManifestation")
local function inPool(a)
    if not (PooledClass and a:IsA(PooledClass)) then return false end
    if ItemActorClass and a:IsA(ItemActorClass) then
        -- idle = parked by its pool at the world origin (a picked-up item keeps its Instance there), hidden,
        -- or without an item Instance (a world item just picked up loses it on the spot). Hazards (landmines,
        -- grabbers, clouds, saw blades) are item manifestations that never have one and live in the world
        -- (observed 303 mines on a host, all placed), so for them only origin / hidden count.
        local l = a:K2_GetActorLocation()
        if math.abs(l.X) < 1 and math.abs(l.Y) < 1 and math.abs(l.Z) < 1 then return true end
        local ok, hidden = pcall(function() return a.bHidden end)
        if ok and hidden == true then return true end
        if clsName(a):find("^BP_Hazard") then return false end
        local okI, inst = pcall(function() return a.Instance end)
        return not (okI and usable(inst))
    end
    return false
end
M.inPool = inPool

-- class name -> replicated? (patterns are matched once per class, not once per actor)
local matchCache = {}
local function classMatches(c)
    local m = matchCache[c]
    if m == nil then m = M.matches(c) matchCache[c] = m end
    return m
end

-- verdict by class object address: no class-name string per actor (classes stay loaded in a zone)
local verdictByClass = {}
local function classMatchesFast(a)
    local c = a:GetClass()
    local ok, addr = pcall(function() return c:GetAddress() end)
    if not ok or not addr then return classMatches(c:GetFName():ToString()) end
    local v = verdictByClass[addr]
    if v == nil then v = classMatches(c:GetFName():ToString()) verdictByClass[addr] = v end
    return v
end

-- The native helpers (mod/CoopNative world.cpp, 2026-10-25): the world walks in C++ (x6-20 faster). Lua still decides
-- what a class is (the patterns here); C++ keeps the answer per class name as tag bits and filters by them. Without
-- the native half (CoopNative_Find missing) the Lua walks below run as before.
local N = CoopNative_Find ~= nil
M.native = N
local TAG = { REPL = 1, CONTAINER = 2, PLAYERCAR = 4, DRESS = 8, DRESS_ROOT = 16, TEMPLATE = 32, STATICMESH = 64,
    SITE_PRODUCT = 128, FRAME = 256, MARKER = 512, ANCHOR = 1024 }
local OPT = { LEVEL = 1, ROOT = 2, PREFAB = 4, PATHS = 8 }
local DRESS_CLASSES, DRESS_SKIP, DRESS_ROOTS -- (defined with the dressing below)
local function tagsOf(c)
    local t = 0
    if classMatches(c) then
        t = t | TAG.REPL
        if c:find("^BP_Template_") then t = t | TAG.TEMPLATE end
    end
    if anyMatch(CONTAINERS, c) then t = t | TAG.CONTAINER end
    if c == "BP_PlayerCarNew_C" then t = t | TAG.PLAYERCAR end
    if anyMatch(DRESS_CLASSES, c) and not classMatches(c) and not anyMatch(DRESS_SKIP, c) then t = t | TAG.DRESS end
    if DRESS_ROOTS[c] then t = t | TAG.DRESS_ROOT end
    if c == "StaticMeshActor" then t = t | TAG.STATICMESH end
    if anyMatch(SITE_PRODUCTS, c) then t = t | TAG.SITE_PRODUCT end
    if c:find("^BP_BuildingFrame_") then t = t | TAG.FRAME end
    if c:find("^BP_ClumpedSpawnMarker_") then t = t | TAG.MARKER end
    if c == "BP_HazardAnchorPull_C" then t = t | TAG.ANCHOR end
    return t
end
-- the world's actors with a tag in want (opts: OPT bits); classes new to C++ get their tags first
local function nfind(want, opts)
    for name, k in pairs(CoopNative_NewClasses()) do CoopNative_TagClass(k, tagsOf(name)) end
    return CoopNative_Find(want, opts or 0)
end
M.nfind, M.TAG, M.OPT = nfind, TAG, OPT
if N then CoopNative_ForgetClasses() end -- (the scripts were loaded again: the patterns may have changed)

-- All replicated root actors currently in the zone (derived ones included, flagged by isDerived).
-- Cheap checks first: liveness flags, then the cached class verdict; level / pool / root checks only
-- for actors of replicated classes.
-- Attachment rarely changes, and walking the attach chain (reflection reads + GetOwner) was most of
-- the remaining cost, so "in a level and a root" is cached per actor path for ROOT_TTL seconds.
local ROOT_TTL = 30
local rootCache = {}
local rootCacheSweep = 0
function M.collect()
    local out = {}
    if N then
        for _, a in ipairs(nfind(TAG.REPL, OPT.LEVEL | OPT.ROOT)) do
            if not inPool(a) then out[#out + 1] = a end
        end
        return out
    end
    local now = os.clock()
    if now - rootCacheSweep > ROOT_TTL * 4 then rootCache = {} rootCacheSweep = now end
    for _, a in ipairs(FindAllOf("Actor") or {}) do
        if usable(a) and classMatchesFast(a) then
            local p = a:GetFullName()
            local c = rootCache[p]
            if not c or now - c.t > ROOT_TTL then
                c = { t = now, ok = p:find(":PersistentLevel%.") ~= nil and isRoot(a) }
                rootCache[p] = c
            end
            if c.ok and not inPool(a) then out[#out + 1] = a end
        end
    end
    return out
end
function M.invalidateRoots() rootCache = {} end

-- Replicated roots for per-frame work, maintained by an incremental scan (scanFrame) so that no single
-- frame pays for a full FindAllOf + filter:
--   frame 1 of a scan: FindAllOf("Actor"), class verdict by class address, object paths of candidates
--   next frames:       per candidate (by path, budgeted): in a level, not pooled, a root (cached 30 s)
-- roots() returns the last completed scan's actors (looked up again by path; no UObject references are
-- kept across frames). A scan starts at most every RESCAN_S seconds.
local RESCAN_S = 2
local rootPaths, lastScan = nil, -1e9
local scan -- { cands = {paths}, i, out = {paths} }
local derivedByPath = {}
function M.isDerivedPath(p) return derivedByPath[p] == true end
local function scanBegin()
    if N then
        -- level and root already checked in C++: the candidates only need the pool check
        scan = { cands = nfind(TAG.REPL, OPT.LEVEL | OPT.ROOT | OPT.PATHS), i = 1, out = {}, native = true }
        return
    end
    local cands = {}
    for _, a in ipairs(FindAllOf("Actor") or {}) do
        if usable(a) and classMatchesFast(a) then cands[#cands + 1] = M.ref(a) end
    end
    scan = { cands = cands, i = 1, out = {} }
end
local function scanCandidate(p)
    local a = M.deref(p)
    if not a then return end
    local c = scan.native and { ok = true } or nil
    if not c then
        local now = os.clock()
        c = rootCache[p]
        if not c or now - c.t > ROOT_TTL then
            c = { t = now, ok = p:find(":PersistentLevel%.") ~= nil and isRoot(a) }
            rootCache[p] = c
        end
    end
    if c.ok and not inPool(a) then
        scan.out[#scan.out + 1] = p
        if derivedByPath[p] == nil then derivedByPath[p] = M.isDerived(clsName(a)) end
    end
end
-- Advance the background scan within the frame deadline (os.clock seconds). Returns true when a scan
-- completed in this frame.
function M.scanFrame(deadline)
    local now = os.clock()
    if not scan then
        if rootPaths and now - lastScan < RESCAN_S then return false end
        lastScan = now
        scanBegin()
        return false -- the candidate list was this frame's work
    end
    while scan.i <= #scan.cands do
        if os.clock() > deadline then return false end
        scanCandidate(scan.cands[scan.i])
        scan.i = scan.i + 1
    end
    rootPaths = scan.out
    scan = nil
    M.scanGeneration = (M.scanGeneration or 0) + 1
    return true
end
function M.roots(force)
    if force or not rootPaths then
        local list = M.collect()
        rootPaths = {}
        for i, a in ipairs(list) do
            rootPaths[i] = M.ref(a)
            derivedByPath[rootPaths[i]] = M.isDerived(clsName(a))
        end
        lastScan = os.clock()
        M.scanGeneration = (M.scanGeneration or 0) + 1
        return list, true
    end
    local out = {}
    for _, p in ipairs(rootPaths) do
        local a = M.deref(p)
        if a and not inPool(a) then out[#out + 1] = a end
    end
    return out, false
end
function M.rootPaths() return rootPaths end

local function dist2(a, b) return (a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2 end

-- Actors of the current level standing on one of the given spots (5 units) whose class matches SITE_PRODUCTS:
-- what site spawners built there. Returns { {a, cls, loc}, ... }.
local function siteProducts(spots)
    local out = {}
    if #spots == 0 then return out end
    for _, a in ipairs(N and nfind(TAG.SITE_PRODUCT, OPT.LEVEL) or FindAllOf("Actor") or {}) do
        if N or (usable(a) and inWorld(a)) then
            local c = clsName(a)
            if N or anyMatch(SITE_PRODUCTS, c) then
                local l = a:K2_GetActorLocation()
                for _, p in ipairs(spots) do
                    if dist2(l, p) < 25 then out[#out + 1] = { a = a, cls = c, loc = l } break end
                end
            end
        end
    end
    return out
end
function M.isSiteSpawner(cls) return anyMatch(SITE_SPAWNER, cls) end

-- Prefab dressing (2026-10-23): the zone's buildings are prefabs (PrefabSettingsActor + hundreds of attached static
-- meshes, lights, doors, posters); the native spawn strategy keeps one variant per site and removes the others, and
-- site spawners build theirs - differently in every game (a site: host variant with 291 meshes, client another with
-- 79; whole buildings on one side only: 59% of all actors matched while the replicated classes were at 98%).
-- The host lists the dressing (visual actors under prefabs / variant containers / wreck templates, see underPrefab;
-- kind P: class, transform, look); the client removes what the host has not and spawns what it lacks (matched by
-- class + mesh + spot). Whole zone, every class: 59% -> 90% matched (sync-test "WHOLE ZONE").
DRESS_SKIP = { "^Actor$", "^ManageChildrenActor$", "^PrefabSettingsActor$", "^PrefabActor$", "^PrefabWrapper$",
    "^BP_PrefabSelfDeletor", "^BP_BuildingFrame_", "^BP_LeafSpawner", "^BP_Spawner_", "^SpawnModifierActor$",
    "^BP_ClumpedSpawnMarker_" }
local DRESS_TOL2 = 10 * 10
-- Dressing = visual classes only (quest items and other gameplay actors under the same containers are never touched)
-- under a dressing root: a prefab, a ManageChildrenActor, a leaf spawner (variants placed in the level and culled
-- natively), or - static meshes only - a replicated wreck template (BP_Template_*: the host's template adds random
-- meshes at run time, the client's imported copy does not).
DRESS_CLASSES = { "^StaticMeshActor$", "^PointLight$", "^SpotLight$", "^RectLight$", "^DecalActor$", "^BP_Prop_", "^BP_Door_",
    "^BP_Poster_", "^BP_Decal_", "^BP_Billboard_", "^BP_IF_" }
DRESS_ROOTS = { PrefabSettingsActor = true, ManageChildrenActor = true, BP_LeafSpawner_C = true }
local function underPrefab(a, c)
    local cur, g = parentOf(a), 0
    while cur and g < 16 do
        local pc = clsName(cur)
        if DRESS_ROOTS[pc] then return true end
        if classMatches(pc) then return c == "StaticMeshActor" and pc:find("^BP_Template_") ~= nil end
        cur, g = parentOf(cur), g + 1
    end
    return false
end
local function short(o) return (o:GetFullName():gsub("^%S+ ", "")) end
-- the look of a dressing actor: a static mesh actor's mesh / slot materials / collision profile, a light's
-- intensity and colour ("-" for the rest: spawned by class)
local function dressLook(a, c)
    local look = "-"
    pcall(function()
        if c == "StaticMeshActor" then
            local comp = a.StaticMeshComponent
            local mesh = comp.StaticMesh
            if not (mesh and mesh:IsValid()) then look = "m=" return end
            local mats = {}
            for i = 0, comp:GetNumMaterials() - 1 do
                local m = comp:GetMaterial(i)
                if m and m:IsValid() and m:GetClass():GetFName():ToString() == "MaterialInstanceDynamic" then m = m.Parent end
                mats[#mats + 1] = (m and m:IsValid()) and short(m) or ""
            end
            look = "m=" .. short(mesh) .. "~t=" .. table.concat(mats, ";") .. "~c=" .. comp:GetCollisionProfileName():ToString()
                .. "~v=" .. (comp:IsVisible() and "1" or "0")
        elseif c == "PointLight" or c == "SpotLight" then
            local lc = a.LightComponent
            local col = lc.LightColor
            look = string.format("i=%.3f~col=%d,%d,%d", lc.Intensity, col.R, col.G, col.B)
        end
    end)
    return look
end
-- every dressing actor of the zone: { a, cls, clsPath, look, loc }
local function dressEntry(a, c)
    return { a = a, cls = c, clsPath = a:GetClass():GetFullName():gsub("^%S+ ", ""), look = dressLook(a, c), loc = a:K2_GetActorLocation() }
end
local function dressing()
    local out = {}
    if N then
        -- under a prefab (C++), plus what this side spawned as dressing earlier (not under a prefab)
        local seen = {}
        for _, a in ipairs(nfind(TAG.DRESS, OPT.LEVEL | OPT.PREFAB)) do
            local p = M.ref(a)
            seen[p] = true
            out[#out + 1] = dressEntry(a, clsName(a))
        end
        for full in pairs(CoopSyncDress or {}) do
            local p = full:gsub("^%S+ ", "")
            local a = not seen[p] and M.deref(p) or nil
            if a then out[#out + 1] = dressEntry(a, clsName(a)) end
        end
        return out
    end
    for _, a in ipairs(FindAllOf("Actor") or {}) do
        if usable(a) and inWorld(a) then
            local c = clsName(a)
            if anyMatch(DRESS_CLASSES, c) and not classMatches(c) and not anyMatch(DRESS_SKIP, c) and (underPrefab(a, c) or (CoopSyncDress or {})[a:GetFullName()]) then
                out[#out + 1] = { a = a, cls = c, clsPath = a:GetClass():GetFullName():gsub("^%S+ ", ""), look = dressLook(a, c),
                    loc = a:K2_GetActorLocation() }
            end
        end
    end
    return out
end
M.dressing = dressing

function M.export(path)
    local f = assert(io.open(path, "wb"))
    local n = 0
    Loot.beginPass()
    local roots = M.collect()
    -- building spawners: the building class each one built (its frame on the spawner's spot)
    local spots = {}
    for _, a in ipairs(roots) do
        if clsName(a):find("^BP_Spawner_Building_") then spots[#spots + 1] = a:K2_GetActorLocation() end
    end
    local frames = {}
    for _, p in ipairs(siteProducts(spots)) do
        if p.cls:find("^BP_BuildingFrame_") then frames[#frames + 1] = p end
    end
    for _, a in ipairs(roots) do
        local l, r, s = a:K2_GetActorLocation(), a:K2_GetActorRotation(), a:GetActorScale3D()
        local kind = M.isDerived(clsName(a)) and "D" or (isRuntime(a) and "R" or "L")
        local clsPath = a:GetClass():GetFullName():gsub("^%S+ ", "")
        local loot = (kind ~= "D") and Loot.serialize(a) or nil
        local variant = ""
        if clsName(a):find("^BP_Spawner_Building_") then
            for _, p in ipairs(frames) do
                if dist2(p.loc, l) < 25 then variant = "\t" .. p.a:GetClass():GetFullName():gsub("^%S+ ", "") break end
            end
        end
        f:write(string.format("%s\t%s\t%.2f\t%.2f\t%.2f\t%.3f\t%.3f\t%.3f\t%.4f\t%.4f\t%.4f\t%s\t%s%s\n",
            kind, clsPath, l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll, s.X, s.Y, s.Z, key(a), loot or "", variant))
        n = n + 1
    end
    -- Kind F: every building frame (not replicated; the client aligns its frames to these after the import:
    -- level farms pick their silo variant per run, a spawner can come out another variant)
    for _, a in ipairs(N and nfind(TAG.FRAME, OPT.LEVEL) or FindAllOf("Actor") or {}) do
        if N or (usable(a) and inWorld(a) and clsName(a):find("^BP_BuildingFrame_")) then
            local l, r, s = a:K2_GetActorLocation(), a:K2_GetActorRotation(), a:GetActorScale3D()
            f:write(string.format("F\t%s\t%.2f\t%.2f\t%.2f\t%.3f\t%.3f\t%.3f\t%.4f\t%.4f\t%.4f\t%s\t\n",
                a:GetClass():GetFullName():gsub("^%S+ ", ""), l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll, s.X, s.Y, s.Z, key(a)))
        end
    end
    -- Kind P: prefab dressing (see dressing above); the look goes in the loot column
    for _, d in ipairs(dressing()) do
        local a = d.a
        local l, r, s = d.loc, a:K2_GetActorRotation(), a:GetActorScale3D()
        f:write(string.format("P\t%s\t%.2f\t%.2f\t%.2f\t%.3f\t%.3f\t%.3f\t%.4f\t%.4f\t%.4f\t%s\t%s\n",
            d.clsPath, l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll, s.X, s.Y, s.Z, key(a), d.look))
    end
    Loot.endPass()
    f:close()
    return n
end

local function split(line)
    local t = {}
    for v in (line .. "\t"):gmatch("([^\t]*)\t") do t[#t + 1] = v end
    return t
end

local function readList(path)
    local list = {}
    -- (a document of the in-game network, "doc:<name>", or a file)
    local text
    if CoopSyncRead then text = CoopSyncRead(path) else local f = io.open(path, "rb") if f then text = f:read("*a") f:close() end end
    for line in (text or ""):gmatch("[^\r\n]+") do
        local t = split(line)
        list[#list + 1] = {
            kind = t[1], cls = t[2], key = t[12], loot = t[13] or "", variant = t[14],
            loc = { X = tonumber(t[3]), Y = tonumber(t[4]), Z = tonumber(t[5]) },
            rot = { Pitch = tonumber(t[6]), Yaw = tonumber(t[7]), Roll = tonumber(t[8]) },
            scale = { X = tonumber(t[9]), Y = tonumber(t[10]), Z = tonumber(t[11]) },
        }
    end
    return list
end

local classCache = {}
local function findClass(path)
    if classCache[path] ~= nil then return classCache[path] end
    local c = SFO(path)
    if not c or not c:IsValid() then
        -- "/Game/X/BP_A.BP_A_C" -> try "/Game/X/BP_A.BP_A" and "/Game/X/BP_A"
        local pkg = path:gsub("%.[^.]+$", "")
        local asset = pkg .. "." .. pkg:match("[^/]+$")
        for _, p in ipairs({ asset, pkg, path }) do
            pcall(function() LoadAsset(p) end)
            c = SFO(path)
            if c and c:IsValid() then break end
        end
    end
    classCache[path] = (c and c:IsValid()) and c or false
    return classCache[path]
end

-- Sliced work (owner's stalls: the guest's import of a big zone took 12 s in one frame, its cleanup 3-16 s): a job
-- is a list of steps run SLICE_MS per frame. UE4SS calls fail inside Lua coroutines ("lua state has no instance"),
-- so no coroutines: step(job) returns true when it is done, false to be called again next frame (it keeps its own
-- cursor in job), M.overBudget() tells it the frame's time is up. Run directly (tests), every step runs to its end
-- at once. A job ends by itself when the world changes (a travel).
local SLICE_MS = 6 -- (10: the steps overran it, 18-23 ms of import per frame on the guest - F lines)
-- (under the guest's loading screen the frame rate does not matter: session.lua sets M.sliceMs = LOAD_SLICE_MS then)
M.sliceMs = SLICE_MS
local sliceEnd
function M.overBudget() return sliceEnd ~= nil and os.clock() > sliceEnd end
M.jobs = 0
local function runNow(steps)
    local job = {}
    for i = 1, #steps do while not steps[i](job) do end end
    return job.result
end
function M.runJob(label, steps, onDone)
    local job, world = { i = 1 }, M.worldAddr() -- (the address: a zone reloaded from a save keeps its name)
    local total, frames = 0, 0
    M.jobs = M.jobs + 1
    local h
    local function finish(ok, r)
        if h then CancelDelayedAction(h) end
        M.jobs = M.jobs - 1
        if CoopSyncHitch then CoopSyncHitch.note(string.format("%s: %.0f ms over %d frames", label, total, frames)) end
        pcall(onDone, ok, r, total, frames)
    end
    h = LoopInGameThreadWithDelay(1, function()
        if job.done then return end
        if M.worldAddr() ~= world then job.done = true finish(false, "world changed") return end
        local t0 = os.clock()
        sliceEnd = t0 + (M.sliceMs or SLICE_MS) / 1000
        while job.i <= #steps do
            local ok, fin = pcall(steps[job.i], job)
            if not ok then sliceEnd = nil job.done = true finish(false, fin) return end
            if fin then job.i = job.i + 1 end
            if M.overBudget() then break end
        end
        sliceEnd = nil
        total, frames = total + (os.clock() - t0) * 1000, frames + 1
        if CoopSyncHitch then CoopSyncHitch.spent(os.clock() - t0, "job") end
        if job.i > #steps then job.done = true finish(true, job.result) end
    end)
end


-- Destroys the given roots and everything attached under them (children first). roots: full names in a list. A job
-- step: cur.list (actor paths, found in one walk over the world: an actor whose parent chain reaches a root - by
-- address) is made in the first call, then destroyed from cur.i on until the frame's time is up. (A walk through
-- the roots' AttachChildren crashed the guest's game: children of actors destroyed earlier in the same frame.)
local function destroyTrees(roots, cur)
    if not cur.list and N then
        local names = {}
        for _, full in ipairs(roots) do names[#names + 1] = full end
        local doomed = CoopNative_TreePaths(table.concat(names, "\n"))
        cur.list, cur.i, cur.n = doomed, #doomed, 0
        return false
    end
    if not cur.list then
        local rootAddr = {}
        for _, full in ipairs(roots) do
            local a = M.deref((full:gsub("^%S+ ", "")))
            if a then rootAddr[a:GetAddress()] = true end
        end
        local doomed = {}
        for _, a in ipairs(FindAllOf("Actor") or {}) do
            if usable(a) then
                local x, guard = a, 0
                while x and guard < 16 do
                    if rootAddr[x:GetAddress()] then doomed[#doomed + 1] = M.ref(a) break end
                    x = parentOf(x)
                    guard = guard + 1
                end
            end
        end
        cur.list, cur.i, cur.n = doomed, #doomed, 0
        return false
    end
    -- (from the end: a root comes before its children in the walk only by chance; children-first is kept by
    -- destroying an actor only after what hangs under it - the walk lists every actor, so order does not matter
    -- for the outcome, only paths that are gone already are skipped)
    while cur.i >= 1 do
        local a = M.deref(cur.list[cur.i])
        cur.i = cur.i - 1
        if a and alive(a) then a:K2_DestroyActor() cur.n = cur.n + 1 end
        if M.overBudget() then return false end
    end
    return true
end

-- Spawns the client copy of one host entry {cls, loc, rot, scale, loot}. Returns actor or nil, error.
function M.spawnEntry(e)
    local xf = { Translation = e.loc, Rotation = M.quat(e.rot.Pitch, e.rot.Yaw, e.rot.Roll), Scale3D = e.scale }
    if (e.loot or ""):sub(1, 2) == "W|" then
        -- world items must be spawned together with their item, not as an empty actor of the class
        local ok, a = pcall(function() return Loot.spawnWorldItem(e.loot, xf) end)
        if ok and alive(a) then return a end
        return nil, "world item " .. e.loot:sub(1, 120)
    end
    local cls = findClass(e.cls)
    if not cls then return nil, e.cls end
    local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local variant = (e.variant and e.variant ~= "") and findClass(e.variant) or nil
    local ok, a = pcall(function()
        -- 1 = AlwaysSpawn (ignore collisions)
        local act = GS:BeginDeferredActorSpawnFromClass(FindFirstOf("PlayerController"), cls, xf, 1, nil)
        -- a building spawner builds the host's building, not one of its own choosing
        if variant then pcall(function() act.SpecificVariantOverride = variant end) end
        return GS:FinishSpawningActor(act, xf)
    end)
    if ok and alive(a) then return a end
    return nil, nil
end

-- Never keep UObject references across ticks: an actor that destroys itself gets garbage collected
-- and touching the stale wrapper crashes UE4SS. Keep the object path and look it up again instead.
function M.ref(a) return (a:GetFullName():gsub("^%S+ ", "")) end
-- (native: a weak handle per path, so the next lookup is an index into the object array, not a search by name; a
-- handle whose object is gone is replaced by the object now at that path, if any)
local weakOf = {}
function M.deref(p)
    if not p then return nil end
    if N then
        local h = weakOf[p]
        local o = h and CoopNative_Get(h)
        if o then return o end
        h = CoopNative_RefPath(p)
        weakOf[p] = h
        return h and CoopNative_Get(h) or nil
    end
    local o = SFO(p)
    if usable(o) then return o end
    return nil
end
function M.forgetRefs() weakOf = {} end
M.readList = readList
M.key = key
M.isRuntime = isRuntime
M.destroyTrees = destroyTrees
M.clsName = clsName
M.alive = alive
M.DIR = DIR -- folder of the CoopSync modules (other modules load their siblings from here)

-- Name of the map this game is on now (sync loops stop when it changes: the session's zone is gone).
function M.worldName()
    local gi = FindFirstOf("DrivingGameInstance")
    local ok, n = pcall(function() return gi:GetWorld():GetFName():ToString() end)
    return ok and n or "?"
end
-- The current World object's address: cheap enough for every frame (the game instance lives as long as the game).
-- The sync loops end on the first frame it differs from their start's: checked every 30 frames / every send before,
-- a loop ran on for some frames in the new world with the old zone's freed objects - the guest's game died going home
-- (a Lua call on a freed UObject in a game-thread loop; caught by trace.lua: statesync's frame loop, 2026-11-03).
local giH
function M.worldAddr()
    local gi = giH
    if not (gi and gi:IsValid()) then gi = FindFirstOf("DrivingGameInstance") giH = gi end
    local ok, a = pcall(function() return gi:GetWorld():GetAddress() end)
    return ok and a or nil
end

-- Has the zone generator finished? While it runs, its BP_ClumpedSpawnMarker_* helpers (hundreds) and pooled
-- candidates of replicated classes (containers, rocks) stand at the origin; it removes them some seconds after
-- the replicated root count already looks stable. Ready = no marker left and no replicated actor at the origin
-- (one BP_HazardAnchorPull_C always stays there). Returns ready, markers, actors at the origin.
function M.zoneReady()
    if N then
        nfind(0) -- (the tags of new classes)
        local markers, origin = CoopNative_ZoneCounts(TAG.MARKER, TAG.REPL, TAG.ANCHOR)
        return markers == 0 and origin == 0, markers, origin
    end
    local gi = FindFirstOf("DrivingGameInstance")
    local level = gi:GetWorld():GetFullName():gsub("^%S+ ", "") .. ":PersistentLevel."
    local markers, origin = 0, 0
    for _, a in ipairs(FindAllOf("Actor") or {}) do
        if usable(a) then
            local c = clsName(a)
            local marker = c:find("^BP_ClumpedSpawnMarker_") ~= nil
            if (marker or (classMatches(c) and c ~= "BP_HazardAnchorPull_C")) and a:GetFullName():find(level, 1, true) then
                if marker then markers = markers + 1
                else
                    local l = a:K2_GetActorLocation()
                    if l.X == 0 and l.Y == 0 and l.Z == 0 then origin = origin + 1 end
                end
            end
        end
    end
    return markers == 0 and origin == 0, markers, origin
end

local lastList -- the host list of the last import (cleanup repairs against it)
local failedKeys = {} -- host keys whose spawn failed at the last import (cleanup tries them once more)

-- Building frames to the host's (list rows of kind F): a client frame on a host frame's spot with another
-- class is replaced (frame + everything attached under it), a missing one is spawned. Client frames on no
-- host spot are only counted (not removed yet). Swapping a silo variant and travelling after was checked.
function M.alignFrames(list)
    local host = {}
    for _, e in ipairs(list) do if e.kind == "F" then host[#host + 1] = e end end
    if #host == 0 then return "frames: none listed" end
    local mine = {}
    for _, a in ipairs(N and nfind(TAG.FRAME, OPT.LEVEL) or FindAllOf("Actor") or {}) do
        if N or (usable(a) and inWorld(a) and clsName(a):find("^BP_BuildingFrame_")) then
            mine[#mine + 1] = { a = a, loc = a:K2_GetActorLocation(), cls = a:GetClass():GetFullName():gsub("^%S+ ", "") }
        end
    end
    local same, doomed, todo, matched = 0, {}, {}, {}
    for _, h in ipairs(host) do
        local hit
        for i, m in ipairs(mine) do
            if not matched[i] and dist2(m.loc, h.loc) < 25 then hit = i break end
        end
        if hit then
            matched[hit] = true
            if mine[hit].cls == h.cls then same = same + 1
            else doomed[mine[hit].a:GetFullName()] = true todo[#todo + 1] = h end
        else
            todo[#todo + 1] = h
        end
    end
    local extra = #mine
    for _ in pairs(matched) do extra = extra - 1 end
    -- (destroyTrees is a job step: run to its end here; it was called without its cursor and failed)
    local roots, cur = {}, {}
    for k in pairs(doomed) do roots[#roots + 1] = k end
    while not destroyTrees(roots, cur) do end
    local removed = cur.n or 0
    local spawned = 0
    for _, h in ipairs(todo) do
        local b = M.spawnEntry(h)
        if b then spawned = spawned + 1 CoopSyncKeep[b:GetFullName()] = true end
    end
    return string.format("frames: same=%d replaced/added=%d (spawned %d, removed %d actors) extra=%d", same, #todo, spawned, removed, extra)
end
-- Prefab dressing to the host's (list rows of kind P): a client dressing actor with no host row of its class and
-- look on its spot (10 units) is removed, a host row with no client actor there is spawned (a static mesh actor
-- with the host's mesh, materials and collision; a light with its intensity / colour; anything else by class).
local function spawnDress(e)
    local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local xf = { Translation = e.loc, Rotation = M.quat(e.rot.Pitch, e.rot.Yaw, e.rot.Roll), Scale3D = e.scale }
    local cls = findClass(e.cls)
    if not cls then return nil end
    local ok, a = pcall(function()
        local act = GS:BeginDeferredActorSpawnFromClass(FindFirstOf("PlayerController"), cls, xf, 1, nil)
        return GS:FinishSpawningActor(act, xf)
    end)
    if not (ok and alive(a)) then return nil end
    local look = {}
    for k, v in (e.loot or ""):gmatch("(%a+)=([^~]*)") do look[k] = v end
    pcall(function()
        if look.m and look.m ~= "" then
            local comp = a.StaticMeshComponent
            comp:SetMobility(2)
            local mesh = SFO(look.m)
            if not (mesh and mesh:IsValid()) then pcall(function() LoadAsset(look.m) end) mesh = SFO(look.m) end
            if mesh and mesh:IsValid() then comp:SetStaticMesh(mesh) end
            local i = 0
            for mp in ((look.t or "") .. ";"):gmatch("([^;]*);") do
                if mp ~= "" then
                    local m = SFO(mp)
                    if not (m and m:IsValid()) then pcall(function() LoadAsset(mp) end) m = SFO(mp) end
                    if m and m:IsValid() then comp:SetMaterial(i, m) end
                end
                i = i + 1
            end
            if look.c and look.c ~= "" then comp:SetCollisionProfileName(FName(look.c), true) end
            if look.v == "0" then comp:SetVisibility(false, false) end
        elseif look.i then
            local lc = a.LightComponent
            lc:SetIntensity(tonumber(look.i) or 1)
            local r, g, b = (look.col or ""):match("(%d+),(%d+),(%d+)")
            if r then lc:SetLightColor({ R = tonumber(r) / 255, G = tonumber(g) / 255, B = tonumber(b) / 255, A = 1 }, true) end
        end
    end)
    return a
end
-- As a job step (see M.runJob): cur keeps its place. The first call matches (and removes) in one frame, the host rows
-- missing here are spawned a slice per frame (660 at once held the guest's frame 0.4-0.6 s). true = done, cur.info.
function M.alignDressingStep(list, cur)
    if not cur.todo then
        local host = {}
        for _, e in ipairs(list) do
            if e.kind == "P" then
                local c = e.cls:match("[^%.]+$")
                local id = c .. "|" .. ((e.loot or ""):match("^m=([^~]*)") or "")
                host[id] = host[id] or {}
                table.insert(host[id], { e = e, used = false })
            end
        end
        if next(host) == nil then cur.info = "dressing: none listed" return true end
        local removed, kept = 0, 0
        for _, d in ipairs(dressing()) do
            local id = d.cls .. "|" .. (d.look:match("^m=([^~]*)") or "")
            local hit
            for _, h in ipairs(host[id] or {}) do
                if not h.used and dist2(h.e.loc, d.loc) < DRESS_TOL2 then hit = h break end
            end
            -- (an actor this side spawned or kept earlier is matched, never removed)
            if hit then hit.used = true kept = kept + 1
            elseif not (CoopSyncKeep or {})[d.a:GetFullName()] then pcall(function() d.a:K2_DestroyActor() end) removed = removed + 1 end
        end
        cur.todo, cur.i, cur.kept, cur.removed, cur.spawned, cur.failed = {}, 1, kept, removed, 0, 0
        for _, hs in pairs(host) do
            for _, h in ipairs(hs) do if not h.used then cur.todo[#cur.todo + 1] = h.e end end
        end
        return false
    end
    CoopSyncKeep = CoopSyncKeep or {}
    CoopSyncDress = CoopSyncDress or {} -- what this side spawned (not under a prefab): still dressing next time
    while cur.i <= #cur.todo do
        local e = cur.todo[cur.i]
        cur.i = cur.i + 1
        local a = spawnDress(e)
        if a then
            cur.spawned = cur.spawned + 1
            CoopSyncKeep[a:GetFullName()] = true
            CoopSyncDress[a:GetFullName()] = true
        else cur.failed = cur.failed + 1 end
        if M.overBudget() then return false end
    end
    cur.info = string.format("dressing: kept=%d removed=%d spawned=%d failed=%d", cur.kept, cur.removed, cur.spawned, cur.failed)
    return true
end
function M.alignDressing(list)
    local cur = {}
    while not M.alignDressingStep(list, cur) do end
    return cur.info
end

-- phase times of the last import / cleanup (ms), for the hitch log and the tests: M.phases
M.phases = {}
local phaseT0, phaseList
local function phaseStart() phaseT0, phaseList = os.clock(), {} end
local function phase(name)
    local now = os.clock()
    local ms = (now - phaseT0) * 1000
    phaseList[#phaseList + 1] = string.format("%s=%.0f", name, ms)
    if CoopSyncHitch then CoopSyncHitch.op("phase " .. name, ms) end
    phaseT0 = os.clock()
end
local function phaseEnd(what) M.phases[what] = table.concat(phaseList, ",") end

-- The import as job steps (see M.runJob): decide, destroy, spawn the building sites, spawn the rest, map, loot,
-- the loot's sub-containers. Objects are only used in the frame they were found in (kept / spawned actors by path).
local function importSteps(path)
    local list, hostLevel, keptKeys, doomed = nil, {}, {}, {}
    local kept, moved, spawned, failed, missing, adopted = 0, 0, 0, 0, {}, 0
    local why = {} -- why client actors were not kept, counted
    local destroyCur = {}
    local function spawnStep(sites, label)
        return function(job)
            local k = "spawn_" .. tostring(sites)
            job[k] = job[k] or 1
            while job[k] <= #list do
                local e = list[job[k]]
                job[k] = job[k] + 1
                local need = (e.kind == "R" or e.kind == "L") and not keptKeys[e.key]
                if need and M.isSiteSpawner(e.cls:match("[^%.]+$") or "") == sites then
                    local a, err = M.spawnEntry(e)
                    if a then
                        spawned = spawned + 1
                        CoopSyncKeep[a:GetFullName()] = true
                        e.actorPath = M.ref(a)
                    else
                        failed = failed + 1
                        failedKeys[e.key] = true
                        if err then missing[err] = true end
                    end
                    if M.overBudget() then return false end
                end
            end
            if not sites then lastList = list end
            phase(label)
            return true
        end
    end
    return {
        function()
            phaseStart()
            -- classes / assets cached by an earlier import may be gone with that world (going home unloads the
            -- zone's blueprints): a late join into the same zone crashed spawning from a cached class
            classCache, rootCache = {}, {}
            M.forgetRefs()
            -- lists of an earlier visit to a zone name objects of that world, gone now (a late join's dressing step
            -- looked up ~940 of them: 31 s while each miss cost 33-50 ms)
            CoopSyncDress, rootPaths, scan = {}, nil, nil
            Loot.resetCache()
            list = readList(path)
            phase("read")
            local hostSpots = {} -- class -> its host R and L entries
            for _, e in ipairs(list) do
                if e.kind == "L" then hostLevel[e.key] = e end
                if e.kind == "L" or e.kind == "R" then
                    local c = e.cls:match("[^%.]+$")
                    hostSpots[c] = hostSpots[c] or {}
                    table.insert(hostSpots[c], e)
                end
            end
            -- the nearest host entry of the class within RUNTIME_TOL that no client actor holds yet
            local function spotOnHost(a)
                local es = hostSpots[clsName(a)]
                if not es then return nil, "nocls" end
                local l, best, hit = a:K2_GetActorLocation(), math.huge, nil
                for _, e in ipairs(es) do
                    if not keptKeys[e.key] then
                        local d = dist2(l, e.loc)
                        if d < best then best, hit = d, e end
                    end
                end
                if hit and best < RUNTIME_TOL * RUNTIME_TOL then return hit end
                return nil, (best < 1000 * 1000) and "lt10m" or "far"
            end
            -- host derived actors by class, to keep the client's identical ones
            local hostDerived = {}
            for _, e in ipairs(list) do
                if e.kind == "D" then
                    local c = e.cls:match("[^%.]+$")
                    hostDerived[c] = hostDerived[c] or {}
                    table.insert(hostDerived[c], e.loc)
                end
            end
            local function derivedOnHost(a)
                local spots = hostDerived[clsName(a)]
                if not spots then return false end
                local l = a:K2_GetActorLocation()
                for i, p in ipairs(spots) do
                    if dist2(l, p) < DERIVED_TOL * DERIVED_TOL then table.remove(spots, i) return true end
                end
                return false
            end
            -- 1) decide per client root: keep (level actor the host also has), else destroy.
            --    Derived actors are removed unless the host has the same one there: a kept creator (a level gas
            --    pump) does not re-create its handle, a replaced one does.
            --    First by name (level actors), then the rest by class and spot: over the host's exact zone its
            --    runtime actors come back under new names (32 hex digits: 1589 of 1822 removed sat 0 cm from the
            --    host's own of their class - 2026-11-12)
            CoopSyncKeep = {}
            local doomedSet, doomedSpots, pending = {}, {}, {}
            local function keep(a, e)
                if dist2(a:K2_GetActorLocation(), e.loc) > 1 then
                    pcall(function() a:K2_SetActorLocationAndRotation(e.loc, e.rot, false, {}, true) end)
                    moved = moved + 1
                    -- static actors ignore the move (a pneumatic mailbox stayed 5 km off): replace it instead
                    if dist2(a:K2_GetActorLocation(), e.loc) > 100 then return false end
                end
                CoopSyncKeep[a:GetFullName()] = true
                keptKeys[e.key] = true
                e.actorPath = M.ref(a)
                kept = kept + 1
                return true
            end
            local function doom(a, why1)
                doomedSet[a:GetFullName()] = true
                if M.isSiteSpawner(clsName(a)) then doomedSpots[#doomedSpots + 1] = a:K2_GetActorLocation() end
                if why1 then why[why1] = (why[why1] or 0) + 1 end
            end
            for _, a in ipairs(M.collect()) do
                if M.isDerived(clsName(a)) then
                    if derivedOnHost(a) then CoopSyncKeep[a:GetFullName()] = true kept = kept + 1
                    else doomedSet[a:GetFullName()] = true end
                else
                    local e = (not isRuntime(a)) and hostLevel[key(a)] or nil
                    if e and not keptKeys[e.key] then
                        if not keep(a, e) then doom(a, "static") end
                    else pending[#pending + 1] = a end
                end
            end
            for _, a in ipairs(pending) do
                local e, why1 = spotOnHost(a)
                if e and keep(a, e) then adopted = adopted + 1
                else doom(a, why1 or "static") end
            end
            -- what the doomed site spawners built goes with them (building frame, prefab settings, container)
            for _, p in ipairs(siteProducts(doomedSpots)) do doomedSet[p.a:GetFullName()] = true end
            for k in pairs(doomedSet) do doomed[#doomed + 1] = k end
            failedKeys = {}
            phase("decide")
            return true
        end,
        function()
            if not destroyTrees(doomed, destroyCur) then return false end
            phase("destroy")
            return true
        end,
        -- 2) spawn host actors the client does not have: all runtime ones + level ones it culled. Buildings first
        --    (site spawners, then the frames aligned): a building built after the things around it were placed
        --    shoved them aside (crates, cones, a gas cylinder cabinet broke and dropped its items).
        spawnStep(true, "spawn_sites"),
        spawnStep(false, "spawn"),
        function()
            -- host key -> client actor, used by statesync for later events (by the path taken at spawn: an actor
            -- gone again since - fell before its building stood - stays mapped, so the cleanup puts it back)
            CoopSyncMap = {}
            for _, e in ipairs(list) do if e.actorPath then CoopSyncMap[e.key] = e.actorPath end end
            phase("map")
            -- 3) loot: make every matched actor carry the host's contents
            Loot.resetStats()
            Loot.beginBatch() -- the items' sub-containers filled once at the end (Loot.fillDeferred)
            return true
        end,
        function(job)
            job.li = job.li or 1
            while job.li <= #list do
                local e = list[job.li]
                job.li = job.li + 1
                local a = e.loot ~= "" and e.actorPath and M.deref(e.actorPath) or nil
                if a then
                    local ok, err = pcall(function() Loot.apply(a, e.loot) end)
                    if not ok then CoopSyncLootErr = tostring(err) end
                    if M.overBudget() then return false end
                end
            end
            return true
        end,
        function()
            local okB, errB = pcall(Loot.endBatch, true)
            if not okB then CoopSyncLootErr = tostring(errB) end
            return true
        end,
        function(job)
            -- the items' sub-containers, a slice per frame
            job.fill = job.fill or {}
            local okF, fin = pcall(Loot.fillStep, job.fill, M.overBudget)
            if not okF then CoopSyncLootErr = tostring(fin) elseif not fin then return false end
            phase("loot")
            -- (no forced GC any more: a full CollectGarbage stalled the frame; the engine's own GC frees them)
            phaseEnd("import")
            local miss = {}
            for k in pairs(missing) do miss[#miss + 1] = k end
            local wt = {}
            for k, v in pairs(why) do wt[#wt + 1] = k .. "=" .. v end
            job.result = string.format("kept=%d adopted=%d moved=%d removed=%d (%s) spawned=%d failed=%d %s | loot: %s %s | %s",
                kept, adopted, moved, destroyCur.n or 0, table.concat(wt, ","), spawned, failed, table.concat(miss, " "), Loot.stats(), CoopSyncLootErr or "", "frames: at cleanup")
            return true
        end,
    }
end
function M.import(path) return runNow(importSteps(path)) end
function M.importJob(path, onDone) M.runJob("import", importSteps(path), onDone) end

-- Writes class, location and loot string of every replicated root that carries loot (for scoring).
function M.exportLoot(path)
    local f = assert(io.open(path, "wb"))
    local n = 0
    Loot.beginPass()
    for _, a in ipairs(M.collect()) do
        local loot = Loot.serialize(a)
        if loot then
            local l = a:K2_GetActorLocation()
            f:write(string.format("%s\t%.0f\t%.0f\t%.0f\t%s\n", clsName(a), l.X, l.Y, l.Z, loot))
            n = n + 1
        end
    end
    Loot.endPass()
    f:close()
    return n
end

-- Removes replicated root actors that appeared after import() as side effects (e.g. generators re-creating radiation
-- cascades), a few seconds after the import, as job steps (see M.runJob; the cleanup took one frame of up to 3 s):
-- building frames and dressing to the host's, the loot's pending sub-containers, the extra roots (destroyed a slice
-- per frame), the derived actors, actors pushed away, repairs. M.cleanup() runs them all at once (tests).
local function cleanupSteps()
    local okA, framesInfo, okD, dressInfo, okF, filled
    local removed, names, diag, victims = 0, {}, {}, {}
    local extra, ei
    return {
        function()
            phaseStart()
            -- building frames to the host's here, not at the import: a host site spawner builds its building some
            -- frames after it was spawned, and aligning before that added a frame the spawner then built again
            okA, framesInfo = pcall(M.alignFrames, lastList or {})
            phase("align_frames")
            return true
        end,
        function(job)
            job.dress = job.dress or {}
            local ok, fin = pcall(M.alignDressingStep, lastList or {}, job.dress)
            if ok and not fin then return false end
            okD, dressInfo = ok, ok and job.dress.info or fin
            phase("align_dressing")
            return true
        end,
        function(job)
            job.flush = job.flush or {}
            local ok, fin = pcall(Loot.flushStep, job.flush, M.overBudget)
            if ok and not fin then return false end
            okF, filled = ok, ok and job.flush.filled or fin
            phase("loot_flush")
            return true
        end,
        function()
            -- the extra roots: found in one frame, destroyed a slice per frame (by path)
            if not extra then
                extra, ei = {}, 1
                for _, a in ipairs(M.collect()) do
                    local c = clsName(a)
                    if not M.isDerived(c) and not (CoopSyncKeep or {})[a:GetFullName()] then
                        local l = a:K2_GetActorLocation()
                        extra[#extra + 1] = { p = M.ref(a), cls = c, d = string.format("%s@%.0f,%.0f", a:GetFName():ToString(), l.X, l.Y) }
                    end
                end
                if M.overBudget() then return false end
            end
            while ei <= #extra do
                local v = extra[ei]
                ei = ei + 1
                local a = M.deref(v.p)
                if a then
                    names[v.cls] = (names[v.cls] or 0) + 1
                    victims[#victims + 1] = v
                    a:K2_DestroyActor()
                    removed = removed + 1
                end
                if M.overBudget() then return false end
            end
            phase("remove_extra")
            return true
        end,
        function()
            -- a derived actor kept at import whose creator was replaced anyway: the new creator made its own copy
            -- next to it, drop the kept one
            local fresh = {}
            for _, a in ipairs(M.collect()) do
                local c = clsName(a)
                if M.isDerived(c) and alive(a) and not (CoopSyncKeep or {})[a:GetFullName()] then
                    fresh[c] = fresh[c] or {}
                    table.insert(fresh[c], a:K2_GetActorLocation())
                end
            end
            for _, a in ipairs(M.collect()) do
                local c = clsName(a)
                if M.isDerived(c) and alive(a) and (CoopSyncKeep or {})[a:GetFullName()] and fresh[c] then
                    local l = a:K2_GetActorLocation()
                    for _, p in ipairs(fresh[c]) do
                        if dist2(l, p) < DERIVED_TOL * DERIVED_TOL then
                            names[c] = (names[c] or 0) + 1
                            a:K2_DestroyActor()
                            removed = removed + 1
                            break
                        end
                    end
                end
            end
            -- derived actors the host has and no creator made here (seen: 9 radiation cascades of a zone, all at one
            -- height): spawn them ourselves
            local have = {}
            for _, a in ipairs(M.collect()) do
                local c = clsName(a)
                if M.isDerived(c) and alive(a) then have[c] = have[c] or {} table.insert(have[c], a:K2_GetActorLocation()) end
            end
            local dfilled = 0
            for _, e in ipairs(lastList or {}) do
                -- not world items (gas pump handles): those need their item, which D rows do not carry
                if e.kind == "D" and not e.cls:find("WorldItem", 1, true) then
                    local c, hit = e.cls:match("[^%.]+$"), false
                    for _, p in ipairs(have[c] or {}) do
                        if dist2(p, e.loc) < DERIVED_TOL * DERIVED_TOL then hit = true break end
                    end
                    if not hit then
                        local b = M.spawnEntry(e)
                        if b then dfilled = dfilled + 1 CoopSyncKeep[b:GetFullName()] = true end
                    end
                end
            end
            if dfilled > 0 then diag[#diag + 1] = "derived_filled=" .. dfilled end
            phase("derived")
            return true
        end,
        function()
            diag[#diag + 1] = okA and tostring(framesInfo):gsub(" ", "_") or ("frames_ERROR " .. tostring(framesInfo))
            diag[#diag + 1] = okD and tostring(dressInfo):gsub(" ", "_") or ("dressing_ERROR " .. tostring(dressInfo))
            -- derived actors on no host spot: made by a creator the client spawned on its own after the import (removed
            -- above as a side effect; its radiation cascade stayed - observed one extra in a new zone)
            local hostD = {}
            for _, e in ipairs(lastList or {}) do
                if e.kind == "D" then local c = e.cls:match("[^%.]+$") hostD[c] = hostD[c] or {} table.insert(hostD[c], e.loc) end
            end
            local dremoved = 0
            for _, a in ipairs(M.collect()) do
                local c = clsName(a)
                if M.isDerived(c) and not c:find("WorldItem", 1, true) and alive(a) then
                    local l, hit = a:K2_GetActorLocation(), false
                    for _, p in ipairs(hostD[c] or {}) do
                        if dist2(l, p) < DERIVED_TOL * DERIVED_TOL then hit = true break end
                    end
                    if not hit then a:K2_DestroyActor() dremoved = dremoved + 1 end
                end
            end
            if dremoved > 0 then diag[#diag + 1] = "derived_removed=" .. dremoved end
            -- imported actors pushed away since the import: a host building spawner builds its building on the client
            -- after the import placed what stands around it, and physics shoved crates / pallets / cones aside (seen
            -- 9 km off and under the ground): put them back where the host has them
            local placed = 0
            for _, e in ipairs(lastList or {}) do
                if e.kind ~= "D" and e.kind ~= "F" and e.kind ~= "P" and CoopSyncMap and CoopSyncMap[e.key] then
                    local a = M.deref(CoopSyncMap[e.key])
                    if a and not inPool(a) and dist2(a:K2_GetActorLocation(), e.loc) > 100 * 100 then
                        pcall(function() a:K2_SetActorLocationAndRotation(e.loc, e.rot, false, {}, true) end)
                        pcall(function() a.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName("None")) end)
                        placed = placed + 1
                    end
                end
            end
            if placed > 0 then diag[#diag + 1] = "put_back=" .. placed end
            phase("derived_removed_put_back")
            return true
        end,
        function(job)
            local survivors = 0
            for _, v in ipairs(victims) do
                -- (by path: the destroyed objects themselves may be freed since an earlier frame of a sliced job)
                local x = M.deref(v.p)
                if x and usable(x) then survivors = survivors + 1 diag[#diag + 1] = "STILL ALIVE " .. v.d
                elseif not v.cls:find("WorldItem") and #diag < 12 then diag[#diag + 1] = v.d end
            end
            -- repair: host actors whose client copy died since the import get spawned again (observed: a few
            -- imported landmines went off on the client within the first seconds, the host's stayed)
            local repaired, rnames = 0, {}
            -- Only when truly destroyed (an object that broke, a mine that went off), not world items (picking up). A
            -- first wider version (pooled counted as dead) spawned duplicates; the crash seen then was UE4SS's loops.
            for _, e in ipairs(lastList or {}) do
                if e.kind ~= "D" and e.kind ~= "F" and e.kind ~= "P" and e.loot:sub(1, 2) ~= "W|" and CoopSyncMap and CoopSyncMap[e.key] then
                    local a = M.deref(CoopSyncMap[e.key])
                    if not a then
                        local b = M.spawnEntry(e)
                        if b then
                            CoopSyncKeep[b:GetFullName()] = true
                            CoopSyncMap[e.key] = M.ref(b)
                            if e.loot ~= "" then pcall(function() Loot.apply(b, e.loot) end) end
                            repaired = repaired + 1
                            local c = e.cls:match("[^%.]+$")
                            rnames[c] = (rnames[c] or 0) + 1
                        end
                    end
                end
            end
            -- entries whose spawn failed at the import: one more try now that the zone has settled. Only real failures
            -- with nothing of the class on the spot: retrying every unmapped entry (spawned, then gone by itself before
            -- the map was made) put duplicates in (5 extra in one run).
            local retried = 0
            local function classNear(e)
                local c = e.cls:match("[^%.]+$")
                for _, a in ipairs(FindAllOf(c) or {}) do
                    if alive(a) and inWorld(a) and dist2(a:K2_GetActorLocation(), e.loc) < 50 * 50 then return true end
                end
                return false
            end
            for _, e in ipairs(lastList or {}) do
                if failedKeys[e.key] and CoopSyncMap and not CoopSyncMap[e.key] and not classNear(e) then
                    local b = M.spawnEntry(e)
                    if b then
                        CoopSyncKeep[b:GetFullName()] = true
                        CoopSyncMap[e.key] = M.ref(b)
                        if e.loot ~= "" and e.loot:sub(1, 2) ~= "W|" then pcall(function() Loot.apply(b, e.loot) end) end
                        retried = retried + 1
                    end
                end
            end
            phase("repair_retry")
            if retried > 0 then diag[#diag + 1] = "spawn_retried=" .. retried end
            local rt = {}
            for k, v in pairs(rnames) do rt[#rt + 1] = k .. "=" .. v end
            diag[#diag + 1] = string.format("repaired=%d %s", repaired, table.concat(rt, " "))
            phaseEnd("cleanup")
            local t = {}
            for k, v in pairs(names) do t[#t + 1] = k .. "=" .. v end
            job.result = string.format("removed=%d %s survivors=%d | loot sub-containers filled: %s | %s", removed, table.concat(t, " "),
                survivors, okF and tostring(filled) or ("ERROR " .. tostring(filled)), table.concat(diag, " "))
            return true
        end,
    }
end
function M.cleanup() return runNow(cleanupSteps()) end
function M.cleanupJob(onDone) M.runJob("cleanup", cleanupSteps(), onDone) end

-- FRotator (degrees) -> FQuat, same convention as UE4 FRotator::Quaternion()
function M.quat(pitch, yaw, roll)
    local d = math.pi / 360
    local sp, cp = math.sin(pitch * d), math.cos(pitch * d)
    local sy, cy = math.sin(yaw * d), math.cos(yaw * d)
    local sr, cr = math.sin(roll * d), math.cos(roll * d)
    return {
        X = cr * sp * sy - sr * cp * cy,
        Y = -cr * sp * cy - sr * cp * sy,
        Z = cr * cp * sy - sr * sp * cy,
        W = cr * cp * cy + sr * sp * sy,
    }
end

return M




