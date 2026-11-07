-- Car ghosts (own-car mode): the other player's car shown as plain mesh actors, no game logic.
-- A spawned second BP_PlayerCarNew_C hooks itself into the game (car manager, ~70 part items, events) and made
-- travels crash now and then however it was removed; a ghost is only StaticMeshActors (+ SkeletalMeshActors)
-- with the owner's visible meshes at their car-relative transforms, attached to a root (the chassis), no
-- collision, moved by the stream like the old copy.
--   layout(car)            -> { "kind|mesh|x|y|z|pitch|yaw|roll|sx|sy|sz", ... } of the car's visible meshes
--   build(lines, loc, rot) -> root actor (attached parts under it)
--   destroy(root)          -> number of actors removed
local M = {}
-- path lookups: the native one answers a miss at once (UE4SS walks every object then: ~50 ms)
local SFO = StaticFindObject
if CoopNative_HasPath then SFO = function(p) if CoopNative_HasPath(p) then return StaticFindObject(p) end return nil end end
local Sync
local ghosts = {} -- root path -> its part paths

local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")

function M.init(syncModule) Sync = syncModule end

-- The actors attached under root: every actor of the world with its parent chain, compared by address (the full
-- names before: ~3x slower). A walk over the car's scene components' AttachChildren was faster still but crashed
-- UE4SS (null read) right after a twin's spawn, when the car's parts had just been spawned again (stale entries).
local function descendants(root)
    -- (native: the same walk in C++, every link checked against the engine's object array)
    if CoopNative_Under then return CoopNative_Under(root:GetAddress()) end
    local out = {}
    local r = root:GetAddress()
    for _, a in ipairs(FindAllOf("Actor") or {}) do
        if Sync.alive(a) then
            local cur, g = Sync.parentOf(a), 0
            while cur and g < 8 do
                if cur:GetAddress() == r then out[#out + 1] = a break end
                cur = Sync.parentOf(cur)
                g = g + 1
            end
        end
    end
    return out
end
M.descendants = descendants

local function short(o) return (o:GetFullName():gsub("^%S+ ", "")) end

-- a dynamic material instance (the car's paint, decals, wear) as "parent path|params":
--   params = s:<name>=<v>~v:<name>=<r>,<g>,<b>,<a>~t:<name>=<texture path>   (its own values only)
--   a material-layer parameter's name carries its layer: <name>@<association>,<index> (0 = layer, 1 = blend;
--   2 = global, written bare): set by name alone it misses the layer (the hood kept its default orange look)
local function pname(info)
    local n = info.Name:ToString()
    local a, i = 2, -1
    pcall(function() a, i = tonumber(info.Association) or 2, tonumber(info.Index) or -1 end)
    if a ~= 2 then n = string.format("%s@%d,%d", n, a, i) end
    return n
end
local function midParams(m)
    local p = {}
    pcall(function()
        for k = 1, #m.ScalarParameterValues do
            local x = m.ScalarParameterValues[k]
            p[#p + 1] = string.format("s:%s=%.3f", pname(x.ParameterInfo), x.ParameterValue)
        end
        for k = 1, #m.VectorParameterValues do
            local x = m.VectorParameterValues[k]
            local v = x.ParameterValue
            p[#p + 1] = string.format("v:%s=%.3f,%.3f,%.3f,%.3f", pname(x.ParameterInfo), v.R, v.G, v.B, v.A)
        end
        for k = 1, #m.TextureParameterValues do
            local x = m.TextureParameterValues[k]
            local tex = x.ParameterValue
            if tex and tex:IsValid() then
                -- a run-time texture (a screen's render target) exists only in the owner's game: "-"
                local path = short(tex)
                if path:find("/Engine/Transient", 1, true) then path = "-" end
                p[#p + 1] = string.format("t:%s=%s", pname(x.ParameterInfo), path)
            end
        end
    end)
    return table.concat(p, "~")
end

-- Every visible mesh component of a real car and its attached part actors: fn(actor, comp, kind, mesh path, relative
-- transform to the car). Characters and plain mesh actors under the car (a seated player, the other's puppet,
-- a twin's added parts) are not the car's.
local function partOfCar(a)
    local cls = a:GetClass():GetFName():ToString()
    return cls ~= "SkeletalMeshActor" and cls ~= "StaticMeshActor" and not cls:find("Character")
end
function M.eachPart(car, fn)
    local SMC = StaticFindObject("/Script/Engine.StaticMeshComponent")
    local SKC = StaticFindObject("/Script/Engine.SkeletalMeshComponent")
    local inv = KML:InvertTransform(car:GetTransform())
    local actors = descendants(car)
    table.insert(actors, 1, car)
    for _, a in ipairs(actors) do
        if partOfCar(a) then
            for kind, cls in pairs({ static = SMC, skeletal = SKC }) do
                local ok, comps = pcall(function() return a:K2_GetComponentsByClass(cls) end)
                if ok and comps then
                    for i = 1, #comps do
                        local c = comps[i]:get() -- TArray elements are wrapped
                        local okM, mesh = pcall(function() return kind == "static" and c.StaticMesh or c.SkeletalMesh end)
                        local okV, vis = pcall(function() return c:IsVisible() end)
                        -- hidden in game (helper shapes: engine Cube / Cylinder / Plane, a spare windshield with the
                        -- engine's default material) is visible in the editor sense: the ghost drew them as stubs
                        local hiddenInGame = false
                        pcall(function() hiddenInGame = c.bHiddenInGame or a.bHidden end)
                        -- highlight shells (CarHighlightMesh of the car's soul: the whole chassis with the default
                        -- orange / blue-stripe paint, door highlight meshes) are not drawn in the main pass: in the
                        -- ghost the default-painted chassis covered the real paint (owner's screenshot)
                        pcall(function() if c.bRenderInMainPass == false then hiddenInGame = true end end)
                        if okM and mesh and mesh:IsValid() and not (okV and not vis) and not hiddenInGame then
                            fn(a, c, kind, (mesh:GetFullName():gsub("^%S+ ", "")), KML:ComposeTransforms(c:K2_GetComponentToWorld(), inv))
                        end
                    end
                end
            end
        end
    end
end

-- Lines: first the material table ("mat|<id>|<parent>|<params>", one per distinct dynamic material: the
-- car's ~230 instances share a few dozen looks), then the parts; a part's slot is a material path or "@<id>".
function M.layout(car)
    local out, matLines, matIds = {}, {}, {}
    M.eachPart(car, function(_, c, kind, meshPath, rel)
        local l, r, s = rel.Translation, KML:Quat_Rotator(rel.Rotation), rel.Scale3D
        -- the slots' materials (a dynamic instance - paint, wear - goes into the material table)
        local mats = {}
        pcall(function()
            for mi = 0, c:GetNumMaterials() - 1 do
                local m = c:GetMaterial(mi)
                local e = ""
                if m and m:IsValid() and m:GetClass():GetFName():ToString() == "MaterialInstanceDynamic" and m.Parent and m.Parent:IsValid() then
                    local key = short(m.Parent) .. "|" .. midParams(m)
                    local id = matIds[key]
                    if not id then
                        id = #matLines + 1
                        matIds[key] = id
                        matLines[id] = "mat|" .. id .. "|" .. key
                    end
                    e = "@" .. id
                elseif m and m:IsValid() then e = short(m) end
                mats[#mats + 1] = e
            end
        end)
        -- a part drawn only with the engine's default material is not drawn in the game (a spare
        -- windshield layer): in the ghost it was an opaque dark sheet over the glass
        local real = false
        for _, e in ipairs(mats) do
            local p = e
            local id = e:match("^@(%d+)$")
            if id then p = (matLines[tonumber(id)] or ""):match("^mat|%d+|([^|]+)|") or "" end
            if p ~= "" and not p:find("^/Engine/EngineMaterials/") then real = true end
        end
        if #mats > 0 and not real then mats = nil end
        if mats then
            out[#out + 1] = string.format("%s|%s|%.2f|%.2f|%.2f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%s", kind,
                meshPath, l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll, s.X, s.Y, s.Z, table.concat(mats, ";"))
        end
    end)
    for i = #matLines, 1, -1 do table.insert(out, 1, matLines[i]) end
    return out
end

local asset
M.stats = { mids = 0, midFails = 0, params = 0, paramFails = 0 }
-- a slot of a ghost part gets its own dynamic material (the component makes it) with the owner's values
local function applyMaterial(comp, slot, def)
    local parent = asset(def.parent)
    if not parent then M.stats.midFails = M.stats.midFails + 1 return end
    local ok, mid = pcall(function() return comp:CreateDynamicMaterialInstance(slot, parent, FName("None")) end)
    if not (ok and mid and mid:IsValid()) then
        M.stats.midFails = M.stats.midFails + 1
        pcall(function() comp:SetMaterial(slot, parent) end)
        return
    end
    M.stats.mids = M.stats.mids + 1
    for e in (def.params .. "~"):gmatch("([^~]*)~") do
        local t, name, val = e:match("^(%a):([^=]+)=(.*)$")
        if t then
            -- "<name>@<association>,<index>" = a layer / blend parameter: set by its full info
            local pn, assoc, idx = name:match("^(.-)@(%d+),(%-?%d+)$")
            local info = pn and { Name = FName(pn), Association = tonumber(assoc), Index = tonumber(idx) } or nil
            local okP = pcall(function()
                if t == "s" then
                    if info then mid:SetScalarParameterValueByInfo(info, tonumber(val)) else mid:SetScalarParameterValue(FName(name), tonumber(val)) end
                elseif t == "v" then
                    local r, g, b, al = val:match("([^,]+),([^,]+),([^,]+),([^,]+)")
                    local c = { R = tonumber(r), G = tonumber(g), B = tonumber(b), A = tonumber(al) }
                    if info then mid:SetVectorParameterValueByInfo(info, c) else mid:SetVectorParameterValue(FName(name), c) end
                elseif t == "t" then
                    -- a screen's picture is a render target the owner's game draws at run time (no path to load):
                    -- black, a screen that is off, instead of the material's own placeholder texture
                    local tex = (val ~= "-" and asset(val)) or asset("/Engine/EngineResources/Black.Black")
                    if not tex then error("no texture " .. val) end
                    if info then mid:SetTextureParameterValueByInfo(info, tex) else mid:SetTextureParameterValue(FName(name), tex) end
                end
            end)
            if okP then M.stats.params = M.stats.params + 1 else M.stats.paramFails = M.stats.paramFails + 1 end
        end
    end
end
function M.statsInfo()
    return string.format("mids=%d mid_fails=%d params=%d param_fails=%d", M.stats.mids, M.stats.midFails, M.stats.params, M.stats.paramFails)
end
local assetCache = {}
asset = function(path)
    local a = assetCache[path]
    if a == nil then
        a = SFO(path)
        if not (a and a:IsValid()) then pcall(function() LoadAsset(path) end) a = SFO(path) end
        a = (a and a:IsValid()) and a or false
        assetCache[path] = a
    end
    return a or nil
end

local function spawnMeshActor(kind, mesh, xf)
    local cls = SFO(kind == "static" and "/Script/Engine.StaticMeshActor" or "/Script/Engine.SkeletalMeshActor")
    local ok, a = pcall(function()
        local act = GS:BeginDeferredActorSpawnFromClass(FindFirstOf("PlayerController"), cls, xf, 1, nil)
        return GS:FinishSpawningActor(act, xf)
    end)
    if not (ok and a and a:IsValid()) then return nil end
    pcall(function()
        if kind == "static" then
            local c = a.StaticMeshComponent
            c:SetMobility(2) -- Movable: it rides along with the car
            if mesh then c:SetStaticMesh(mesh) end
        else
            local c = a.SkeletalMeshComponent
            c:SetMobility(2)
            c:SetSkeletalMesh(mesh, true)
        end
    end)
    -- solid like a car (owner's ask): a walker is blocked, a real car bumps into it. The ghost is moved by
    -- teleports, so it pushes nothing itself; a player sitting in it has its own collision off (setWalking).
    pcall(function()
        local c = kind == "static" and a.StaticMeshComponent or a.SkeletalMeshComponent
        c:SetCollisionProfileName(FName("BlockAllDynamic"), true)
        c:SetCollisionEnabled(3) -- QueryAndPhysics
    end)
    pcall(function() a:SetActorEnableCollision(true) end)
    return a
end

-- A part's slots get the owner's materials ("@<id>" = a dynamic material from the table, else a material path).
-- keepScreens: a slot whose owner material has a run-time render target ("t:...=-") keeps its own material (a
-- twin's screens are live; a ghost shows them black).
function M.applyMaterials(comp, matList, defs, keepScreens)
    if not matList or matList == "" then return end
    local mi = 0
    for mp in (matList .. ";"):gmatch("([^;]*);") do
        local id = mp:match("^@(%d+)$")
        if id then
            local d = defs[id]
            local screen = keepScreens and d and (d.params:find("=%-~") or d.params:find("=%-$"))
            if d and not screen then applyMaterial(comp, mi, d) end
        else
            local m = mp ~= "" and asset(mp) or nil
            if m then pcall(function() comp:SetMaterial(mi, m) end) end
        end
        mi = mi + 1
    end
end

-- One plain mesh actor with the owner's mesh and materials at a world transform (nil when the mesh is unknown).
function M.spawnPart(kind, path, world, matList, defs)
    local mesh = path and asset(path)
    if not mesh then return nil end
    local a = spawnMeshActor(kind, mesh, world)
    if not a then return nil end
    M.applyMaterials(kind == "static" and a.StaticMeshComponent or a.SkeletalMeshComponent, matList, defs, false)
    return a
end

function M.build(lines, loc, rot)
    local carXf = KML:MakeTransform(loc, rot, { X = 1, Y = 1, Z = 1 })
    -- an empty mesh actor exactly at the car's transform stands for the car; every part is attached to it
    local root = spawnMeshActor("static", nil, carXf)
    if not root then return nil, 0 end
    local n, parts = 0, {}
    local defs = {}
    for _, line in ipairs(lines) do
        local id, parent, params = line:match("^mat|(%d+)|([^|]+)|(.*)$")
        if id then defs[id] = { parent = parent, params = params } end
    end

    for _, line in ipairs(lines) do
        local kind, path, x, y, z, p, yw, r, sx, sy, sz, matList = line:match("^(%a+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|?([^|]*)$")
        if kind then
            local rel = KML:MakeTransform({ X = tonumber(x), Y = tonumber(y), Z = tonumber(z) },
                { Pitch = tonumber(p), Yaw = tonumber(yw), Roll = tonumber(r) }, { X = tonumber(sx), Y = tonumber(sy), Z = tonumber(sz) })
            local a = M.spawnPart(kind, path, KML:ComposeTransforms(rel, carXf), matList, defs)
            if a then
                n = n + 1
                parts[#parts + 1] = Sync.ref(a)
                pcall(function() a:K2_AttachToActor(root, FName("None"), 1, 1, 1, false) end) -- KeepWorld
            end
        end
    end
    ghosts[Sync.ref(root)] = parts
    return root, n
end

-- Only the ghost's own parts go: a character sitting in the ghost (the local player, the other player's puppet)
-- is attached under it too and is detached and kept.
function M.destroy(root)
    if not root then return 0 end
    local key = Sync.ref(root)
    local parts = ghosts[key] or {}
    ghosts[key] = nil
    local mine = {}
    for _, p in ipairs(parts) do mine[p] = true end
    for _, a in ipairs(descendants(root)) do
        if not mine[Sync.ref(a)] then pcall(function() a:K2_DetachFromActor(1, 1, 1) end) end
    end
    local n = 0
    for _, p in ipairs(parts) do
        local a = Sync.deref(p)
        if a then a:K2_DestroyActor() n = n + 1 end
    end
    root:K2_DestroyActor()
    return n + 1
end

return M
