-- Twin cars (own-car mode, owner's choice 2026-10-23): the other player's car as a real BP_PlayerCarNew_C.
-- The game has one car manager and one car inventory. The twin gets its own named container while it spawns (see
-- "Equipment" below: its parts are the game's own, from the owner's items - the own car untouched). Probed (NOTES
-- "Twin cars", "Twin rework"):
--   * spawning takes BP_CarManager_C.NewCarActor -> given back to the own car at once;
--   * the twin's doors are the game's (highlight, prompt) with their E handlers removed (M.muteDoors): getting in =
--     manager -> twin + the door's StartEntry / CommandEnterCar; getting out = "Exit Car", then the manager goes back
--     to the own car.
-- The twin is a puppet: its vehicle controller does not tick, it follows the owner's car stream (playersync).
-- Removed before every travel.
local M = {}
-- path lookups: the native one answers a miss at once (UE4SS walks every object then: ~50 ms)
local SFO = StaticFindObject
if CoopNative_HasPath then SFO = function(p) if CoopNative_HasPath(p) then return StaticFindObject(p) end return nil end end
local Sync, Ghost
local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local SSC = StaticFindObject("/Script/PenDriverInventory.SlotSceneComponent")

-- live twins: address -> a weak handle to that twin (CoopNative; true without it). Other modules ask isTwin.
-- By address alone (alpha 9): on a second visit to a zone the player's own car came at an address an earlier twin
-- had - it was taken for a twin: no physics, no control, hanging in the air; the host could not get into its car.
CoopSyncTwins = CoopSyncTwins or {}

function M.init(syncModule, ghostModule)
    Sync, Ghost = syncModule, ghostModule
    -- the cars' storages (trunk, storage attachments): carstore.lua
    M.Store = dofile(Sync.DIR .. "carstore.lua")
    M.Store.init(Sync, M)
end

local function weakOf(a)
    return CoopNative_RefPath and CoopNative_RefPath(a:GetFullName():gsub("^%S+ ", "")) or true
end
function M.isTwin(a)
    if not (a and a:IsValid()) then return false end
    local addr = a:GetAddress()
    local h = CoopSyncTwins[addr]
    if h == nil then return false end
    if h == true then return true end
    local o = CoopNative_Get(h)
    if o and o:GetAddress() == addr then return true end
    CoopSyncTwins[addr] = nil -- that twin is gone; this is another object at its address
    return false
end
-- twins of an earlier world are gone with it (session / player sync start)
function M.forgetGone()
    for addr, h in pairs(CoopSyncTwins) do
        if h == true or not CoopNative_Get(h) then CoopSyncTwins[addr] = nil end
    end
end

-- The game's managers / controller, found once and kept by a weak handle (FindFirstOf walks the objects: 0.3 ms, and
-- the twin code asked for them many times a frame; soak test profile 2026-10-28). Gone (travel): found again.
local firstOf = {}
function CoopSyncFirst(cls)
    local h = firstOf[cls]
    local o = h and CoopNative_Get(h)
    if o then return o end
    o = FindFirstOf(cls)
    if o and o:IsValid() and CoopNative_RefPath then firstOf[cls] = CoopNative_RefPath((o:GetFullName():gsub("^%S+ ", ""))) end
    return o
end
local function manager() return CoopSyncFirst("BP_CarManager_C") end

-- the local player's own car: the manager's, unless the manager points at a twin (someone sits in it)
function M.ownCar()
    local cm = manager()
    local c = cm and cm.NewCarActor
    if c and c:IsValid() and not M.isTwin(c) and c:GetFullName():find(":PersistentLevel.", 1, true) then return c end
    for _, x in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
        if x:IsValid() and x:GetFullName():find(":PersistentLevel.", 1, true) and not M.isTwin(x) then return x end
    end
end

function M.managerToOwn()
    local own = M.ownCar()
    local cm = manager()
    if own and cm then cm.NewCarActor = own end
end

local function underCar(a, car)
    local cur, g = a, 0
    while cur and cur:IsValid() and g < 6 do
        local p = cur:GetAttachParentActor()
        if not (p and p:IsValid()) then return false end
        if p:GetAddress() == car:GetAddress() then return true end
        cur, g = p, g + 1
    end
    return false
end

-- Items of the own car whose actor manifestation is not on it (for the tests: 0 = links whole).
function M.brokenLinks()
    local own = M.ownCar()
    if not own then return -1 end
    local comps = own:K2_GetComponentsByClass(SSC)
    local bad = 0
    for i = 1, #comps do
        local sl = comps[i]:get().ItemSlot
        if sl and sl:IsValid() then
            for j = 1, sl.Items:GetArrayNum() do
                local m = sl.Items[j]:GetActorManifestation()
                if not (m and m:IsValid() and underCar(m, own)) then bad = bad + 1 end
            end
        end
    end
    return bad
end

-- a puppet: no vehicle simulation of its own (the owner's game drives the car, the stream moves the twin)
local VCC = SFO and (SFO("/Script/IWCarPhysics.VehicleControllerComponent") or SFO("/Script/PenDriverPro.VehicleControllerComponent"))
-- a car's own vehicle controllers (by class when found, else among every one of the world)
local function vcsOf(car)
    local out = {}
    if VCC then
        local comps = car:K2_GetComponentsByClass(VCC)
        for i = 1, #comps do local c = comps[i]:get() if c:IsValid() then out[#out + 1] = c end end
        return out
    end
    for _, c in ipairs(FindAllOf("VehicleControllerComponent") or {}) do
        if c:IsValid() and c:GetOuter():IsValid() and c:GetOuter():GetAddress() == car:GetAddress() then out[#out + 1] = c end
    end
    return out
end
local function puppet(twin)
    -- (the twin's own components, not a search over every vehicle controller of the world)
    local comps = VCC and twin:K2_GetComponentsByClass(VCC) or {}
    for i = 1, #comps do
        local c = comps[i]:get()
        if c:IsValid() then pcall(function() c:SetComponentTickEnabled(false) end) end
    end
    if not VCC then
        for _, c in ipairs(FindAllOf("VehicleControllerComponent") or {}) do
            if c:IsValid() and c:GetOuter():IsValid() and c:GetOuter():GetAddress() == twin:GetAddress() then
                pcall(function() c:SetComponentTickEnabled(false) end)
            end
        end
    end
    -- kinematic: a simulated chassis spawned where the car stands (overlapping it, the ground) was flung hundreds of
    -- kilometres between two stream teleports and fell out of the world (the copy was spawned again and again)
    pcall(function()
        local root = twin.RootComponent
        root:SetSimulatePhysics(false)
        root:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName("None"))
    end)
    -- The two cars collide: a car's chassis is of the game's own car channel and ignores that channel (one car in the
    -- game: the cars drove through each other, cmds/collide-probe.lua). The twin's chassis as a world-dynamic object
    -- (the own car blocks those) that blocks the car channel: the own car hits it like a wall that moves (each side's
    -- own car bounces off the other's twin; the twin moving into it pushes it).
    pcall(function()
        local root = twin.RootComponent
        local ch = root:GetCollisionObjectType()
        if ch ~= 1 then M.carChannel = ch end
        M.carChannelOf()
        if M.carChannel then root:SetCollisionResponseToChannel(M.carChannel, 2) end
        root:SetCollisionObjectType(1)
    end)
end

-- Native cars: the car the local player drives simulates on this side (owner, after alpha 17: driving the other's car
-- was jerky - its pedals went to the owner and the car came back by the stream). on: physics + its vehicle controller,
-- at the velocity it had (vel); off: a puppet again (kinematic, moved by the stream) - the other's twin, or the own car
-- while the other player drives it.
function M.setDriven(car, on, vel)
    if on and M.isTwin(car) then M.muteDoorBreak(car) end
    for _, c in ipairs(vcsOf(car)) do
        do
            pcall(function() c:SetComponentTickEnabled(on) end)
            if on then pcall(function() c:SetParkingBrakeActive(false) c:Wake() end) end
        end
    end
    pcall(function()
        local root = car.RootComponent
        root:SetSimulatePhysics(on)
        root:SetPhysicsLinearVelocity(on and vel or { X = 0, Y = 0, Z = 0 }, false, FName("None"))
    end)
    if not on and M.isTwin(car) then M.rejoinDoors(car) end
    M.stats.driven = (M.stats.driven or 0) + 1
end

function M.keepDriven(car)
    for _, c in ipairs(vcsOf(car)) do
        if not c:IsComponentTickEnabled() then
            c:SetComponentTickEnabled(true)
            pcall(function() c:SetParkingBrakeActive(false) c:Wake() end)
            M.stats.drivenKept = (M.stats.drivenKept or 0) + 1
        end
    end
end

-- Collisions with the other's twin. The twin is kinematic (moved by the stream): to physics an infinite mass. Seen in
-- collide-test: a car driven into the other's twin bounced off it as off a wall, and on the other side the striker's
-- twin either barely reached the car hit (the striker had stopped there: pushed 0.5 m) or, ahead by its prediction,
-- threw it with the striker's whole speed (42 m at 15 m/s). Now a hit is seen by its frame (the own car's velocity
-- jumping >= 3 m/s away from the twin within 9 m), on either side - or on both: from the velocities before it, the
-- speed both cars share after it along the line between them (momentum kept, masses from the bodies; equal cars: the
-- mean) - the same number from either side. The side that sees it sets it on its own car, sends it ("BI",
-- playersync), and moves its twin of the other car on at it at once (playersync TD.kick: the stream shows that car
-- pushed only a round trip later); the other side does the same with the number it gets. Setting a speed twice is
-- harmless, so it does not matter who saw it first. For a second after that, no new hit is read between the two (the
-- cars still touching) and the own car moves away no faster than the shared speed (+30 %): the twin, its prediction
-- still ahead, threw it again and again (40 / 58 m/s from 15 m/s hits).
-- Tried before and dropped: "the striker" sends, "the car hit" takes it (a car rolling toward the twin took itself for
-- the striker and the real striker's twin then threw it at 21 m/s); a pass-through of the twin after a hit (the cars
-- ended inside each other: the physics' push apart was such a throw).
-- The car channel, from the own car when no twin showed it here: a twin set up by an earlier load of this module (a
-- player sync started again) is world-dynamic already - the channel stayed unknown and the hits went unseen on that
-- side (collide-test: the guest's car thrown at 47-58 m/s, no hit ever noticed there).
function M.carChannelOf()
    if M.carChannel then return M.carChannel end
    pcall(function()
        local own = M.ownCar()
        local ch = own and own.RootComponent:GetCollisionObjectType()
        if ch and ch ~= 1 then M.carChannel = ch end
    end)
    return M.carChannel
end
local BUMP_DV = 300   -- cm/s in one frame away from the twin: a hit
local BUMP_NEAR = 900 -- cm between the cars' centres
local HIT_S = 1.0     -- s after a hit: no new one read, the own car held to the shared speed
local bump = { t = 0 }
-- the own car moves at vc along (nx, ny) now and is held to it for HIT_S
local function shareSpeed(r, nx, ny, vc, now)
    local none = FName("None")
    local v = r:GetPhysicsLinearVelocity(none)
    local cur = v.X * nx + v.Y * ny
    local nv = { X = v.X + nx * (vc - cur), Y = v.Y + ny * (vc - cur), Z = v.Z }
    r:SetPhysicsLinearVelocity(nv, false, none)
    bump.v = nv
    bump.hit = { nx = nx, ny = ny, vc = vc, untilT = now + HIT_S }
    return cur
end
-- every frame with the other's twin (vel: the other car's velocity from the stream); returns nx, ny, vc when a hit was
-- seen here (for BI and the kick: the unit vector from the twin to the own car and the shared speed along it, cm/s)
function M.bumpTick(twin, vel)
    local own = M.ownCar()
    if not (own and own:IsValid() and M.carChannelOf()) then return end
    bump.twin = Sync.ref(twin)
    local now = os.clock()
    local r = own.RootComponent
    local none = FName("None")
    local v = r:GetPhysicsLinearVelocity(none)
    local h = bump.hit
    if h then
        if now > h.untilT then
            bump.hit = nil
        else
            -- held: no faster than the shared speed (+30 %) in its direction, and not thrown back by the twin (the car
            -- still driven into it: a jump >= 3 m/s against that direction in a frame - a driver's braking is gradual)
            local cur = v.X * h.nx + v.Y * h.ny
            local sgn = h.vc < 0 and -1 or 1
            local was = bump.v and (bump.v.X * h.nx + bump.v.Y * h.ny) or cur
            local back = (was - cur) * sgn >= BUMP_DV and cur * sgn < math.abs(h.vc) * 0.7
            if back then M.stats.rebound = (M.stats.rebound or 0) + 1 end
            if back or cur * sgn > math.abs(h.vc) * 1.3 + 100 then
                v = { X = v.X + h.nx * (h.vc - cur), Y = v.Y + h.ny * (h.vc - cur), Z = v.Z }
                r:SetPhysicsLinearVelocity(v, false, none)
                M.stats.guarded = (M.stats.guarded or 0) + 1
            end
        end
    end
    local ol, tl = own:K2_GetActorLocation(), twin:K2_GetActorLocation()
    local prev, prevT, dt = bump.v, bump.tw, now - bump.t
    bump.v, bump.tw, bump.t = { X = v.X, Y = v.Y, Z = v.Z }, { X = tl.X, Y = tl.Y }, now
    if bump.hit or not (prev and dt > 0 and dt < 0.5) then return end -- (a hitch frame too: the twin ahead then)
    local nx, ny = ol.X - tl.X, ol.Y - tl.Y
    local d = math.sqrt(nx * nx + ny * ny)
    if d > BUMP_NEAR or d < 1 then return end
    nx, ny = nx / d, ny / d
    local dv = (v.X - prev.X) * nx + (v.Y - prev.Y) * ny
    if dv < BUMP_DV then return end
    -- the twin's speed along n (> 0: closing): the other car's from the stream (vel) - the twin's own steps between
    -- frames are smoothed (a hit read at 1 m/s closing from 14)
    local twinN = vel and (vel.X * nx + vel.Y * ny) or ((tl.X - prevT.X) * nx + (tl.Y - prevT.Y) * ny) / dt
    local ownN = prev.X * nx + prev.Y * ny                               -- the own car's along n (< 0: closing)
    local mo, mt = 1, 1
    pcall(function() mo, mt = r:GetMass(), twin.RootComponent:GetMass() end)
    local vc = (mo * ownN + mt * twinN) / (mo + mt)
    shareSpeed(r, nx, ny, vc, now)
    M.stats.firstBumpAt = M.stats.firstBumpAt or now
    M.stats.bumpsSent = (M.stats.bumpsSent or 0) + 1
    M.stats.bumpSeen = string.format("%s|t=%.3f,dv=%.0f,own=%.0f,twin=%.0f,vc=%.0f", tostring(M.stats.bumpSeen or ""):sub(-400),
        now, dv, ownN, twinN, vc)
    -- (the hardest closing speed seen: tests compare the speeds after it)
    local closing = twinN - ownN
    if closing > (M.stats.strikeMax or 0) then
        M.stats.strikeMax = closing
        M.stats.lastBump = string.format("sent %.0f>%.0f", closing, math.abs(vc))
    end
    return nx, ny, vc
end
-- the other side saw a hit (BI): (nx, ny) - from this side's car to the other's - and the shared speed along it.
-- Returns the twin's path (for the kick) unless this side has handled that hit already.
function M.bumpGot(nx, ny, vc)
    local own = M.ownCar()
    if not (own and own:IsValid() and nx and ny and vc) then return nil end
    local now = os.clock()
    M.stats.lastGotAt = now
    M.stats.firstGotAt = M.stats.firstGotAt or now
    -- (seen here too, a moment ago: the same speed from either side - set again, no new kick)
    local again = bump.hit ~= nil
    local cur = shareSpeed(own.RootComponent, nx, ny, vc, now)
    M.stats.bumps = (M.stats.bumps or 0) + 1
    if not again then M.stats.lastBump = string.format("got %.0f>%.0f", math.abs(cur), math.abs(vc)) end
    return (not again) and bump.twin or nil
end

local poseCache = {} -- car address -> pose component paths (see pose below)
local lit = {} -- twin address -> { mirror = true, tried = os.clock() } (see light below)
local mutedDoors = {} -- twin address -> { [n] = door actor address } (see M.muteDoors)
local bodyOf = {} -- twin address -> { highlight name -> the bindings taken off it } (M.muteBody)

M.stats = { spawned = 0, removed = 0, errors = {} }

---------------------------------------------------------------------------------------------------
-- Equipment (twin rework, owner 2026-10-26: the other's car must work like the own one, natively). The twin has its
-- OWN named container (UInventoryBlueprintLibrary CreateNamedContainer with the car container's slot rules) holding
-- item instances of the owner's archetypes. While the twin spawns, the inventory manager's Inventory_CarEquipped
-- points at that container, so the car's own BeginPlay binds its slots there and spawns its parts from those items
-- (probe cmds/twin-clean-spawn.lua: the own car's items and parts untouched - no relink, no unbind, no restyle).
-- The game's own highlight and SwapEquipment (take a part off into the inventory, put one on from it) then work on
-- the twin (probe parts5). The owner's car contents come as EQ lines (M.equipLine / M.parseEquip / M.applyEquip);
-- what the local player changed in the twin's container goes to the owner (M.watchEquip -> EX lines ->
-- M.ownerEquip on the owner's real car).
--   EQ <time> <slot>=<archetype path>@<create context>;...     owner -> the other side (non-empty slots)
--   EX <time> <slot> <archetype path>@<context> | -             the other side -> owner (a part put on / taken off)
local IBL
local function lib()
    IBL = IBL or SFO("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
    return IBL
end
local function invManager() return CoopSyncFirst("BP_InventoryManager_C") end
local function realContainer() local im = invManager() return im and im.Inventory_CarEquipped end
local equipOf = {} -- twin address -> { cont = container path, applied = { slot = "path@ctx" }, pending = { slot = clock } }
M.equipStats = { sent = 0, applied = 0, local_ = 0, owner = 0, errors = 0 }

-- slot name -> "archetype path@context" of a named container's non-empty slots (`insts`: slot -> the item, filled
-- when given)
local function contents(cont, insts)
    local t = {}
    local names = {}
    cont:GetSlotNames(names)
    for i = 1, #names do
        local n = names[i]:get()
        local sl = cont:GetSlot(n)
        local it = sl and sl:IsValid() and sl.Items:GetArrayNum() > 0 and sl.Items[1] or nil
        -- (a slot can hold a dead entry: one bad slot stopped the whole car's EQ line)
        if it and it:IsValid() and it.Archetype and it.Archetype:IsValid() then
            local k = n:ToString()
            t[k] = Sync.ref(it.Archetype) .. "@" .. tostring(it.CreateContext)
            if insts then insts[k] = it end
        end
    end
    return t
end
-- Is this item (one that just left a twin's slot) with the local player now: its inventory, hand, trunk?
local PLAYER_CONTS = { "Inventory_Player", "Inventory_PlayerHand", "Inventory_Trunk", "Inventory_LargeTrunk", "Inventory_OverflowContainer" }
local function heldByPlayer(inst)
    if not (inst and inst:IsValid()) then return false end
    local ok, c = pcall(function()
        local sl = inst:GetOuterSlot()
        return sl and sl:IsValid() and sl:GetOuter() or nil
    end)
    local im = invManager()
    if not (ok and c and c:IsValid() and im) then return false end
    for _, f in ipairs(PLAYER_CONTS) do
        local x = im[f]
        if x and x:IsValid() and x:GetAddress() == c:GetAddress() then return true end
    end
    return false
end
local function archetype(path)
    local a = SFO(path)
    if not (a and a:IsValid()) then pcall(function() LoadAsset((path:gsub("%.[^.]+$", ""))) end) a = SFO(path) end
    return (a and a:IsValid()) and a or nil
end
-- put "path@ctx" (or nothing: "-" / nil) into a slot of a named container; the old item(s) leave the game
local function fillSlot(cont, slotName, want, outer)
    local fn = FName(slotName)
    local sl = cont:FindOrCreateSlot(fn)
    for k = sl.Items:GetArrayNum(), 1, -1 do
        local it = sl.Items[k]
        pcall(function() cont:RemoveItemFromSlot(fn, it) end)
        pcall(function() it:Remove(true) end)
    end
    if not want or want == "-" then return true end
    local path, ctx = want:match("^(.-)@(%d+)$")
    local arch = archetype(path or want)
    if not arch then return false end
    local inst = lib():CreateItemInstance(outer, arch, tonumber(ctx) or 0)
    if sl:AddItem(inst) == false then pcall(function() inst:Remove(true) end) return false end
    return true
end

-- Owner side: its car's contents as one line (nil when the inventory is not there); `cont`: another car's (the
-- tests' state comparison: the twin's in the same form)
function M.equipLine(cont)
    cont = cont or realContainer()
    if not (cont and cont:IsValid()) then return nil end
    local t, keys = contents(cont), {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. t[k] end
    return table.concat(parts, ";")
end
-- Paint (owner, alpha 16: the friend saw the host's painted car's trunk lid in the stock colour): a part's paint and
-- decal are in its manifestation's BP_TintableComponent (GetTintableProperties / SetPaint / SetDecal: palette classes),
-- not in the EQ line - the twin's new parts had the stock ones.
--   EP <time> <slot>=<paint class>|<decal class or ->;...      owner -> the other side (changed: every 3 s, else 15 s)
local TINT
local function tintOf(it)
    TINT = TINT or SFO("/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_TintableComponent.BP_TintableComponent_C")
    local a = TINT and it and it:IsValid() and it:GetActorManifestation()
    if not (a and a:IsValid()) then return nil end
    local cs = a:K2_GetComponentsByClass(TINT)
    return #cs > 0 and cs[1]:get() or nil
end
local function tintNow(tc)
    local p, e, d, v = {}, {}, {}, {}
    if not pcall(function() tc:GetTintableProperties(p, e, d, v) end) or not v.Valid then return nil end
    local paint = p.Paint and p.Paint:IsValid() and Sync.ref(p.Paint) or "-"
    local decal = d.DecalPalette and d.DecalPalette:IsValid() and Sync.ref(d.DecalPalette) or "-"
    return paint, decal
end
function M.paintLine(cont)
    cont = cont or realContainer()
    if not (cont and cont:IsValid()) then return nil end
    local insts = {}
    contents(cont, insts)
    local keys = {}
    for k in pairs(insts) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local tc = tintOf(insts[k])
        local paint, decal
        if tc then paint, decal = tintNow(tc) end
        if paint and paint ~= "-" then parts[#parts + 1] = k .. "=" .. paint .. "|" .. decal end
    end
    return table.concat(parts, ";")
end
local function paletteClass(path)
    if not path or path == "-" then return nil end
    local c = SFO(path)
    if not (c and c:IsValid()) then pcall(function() LoadAsset((path:gsub("%.[^.]+$", ""))) end) c = SFO(path) end
    return (c and c:IsValid()) and c or nil
end
-- the owner's paint onto the twin's parts (again whenever a part differs: a part put on there comes in stock colours)
function M.applyPaint(twin, s)
    local e = equipOf[twin:GetAddress()]
    local cont = e and Sync.deref(e.cont)
    if not (cont and s) then return 0 end
    local insts = {}
    contents(cont, insts)
    local n = 0
    for slot, want in s:gmatch("([^=;]+)=([^;]+)") do
        local paint, decal = want:match("^([^|]*)|(.*)$")
        local tc = insts[slot] and tintOf(insts[slot])
        if tc and paint then
            local curP, curD = tintNow(tc)
            if curP ~= paint then
                local c = paletteClass(paint)
                if c and pcall(function() tc:SetPaint(c, {}) end) then n = n + 1 end
            end
            if decal ~= "-" and curD ~= decal then
                local c = paletteClass(decal)
                if c and pcall(function() tc:SetDecal(c, {}) end) then n = n + 1 end
            end
        end
    end
    M.stats.paintSet = (M.stats.paintSet or 0) + n
    return n
end
function M.parseEquip(s)
    local t = {}
    for k, v in (s or ""):gmatch("([^=;]+)=([^;]+)") do t[k] = v end
    return t
end

-- A new container like the car's, filled with `equip`
local function newContainer(equip)
    local im, real = invManager(), realContainer()
    if not (im and real) then return nil end
    local cont = lib():CreateNamedContainer(SFO("/Engine/Transient") or im, FText("CoopSyncTwin"), real.NewSlotRules, real.NewSlotCapacity, real.NewSlotMaxForceCapacity)
    if not (cont and cont:IsValid()) then return nil end
    local names = {}
    real:GetSlotNames(names)
    for i = 1, #names do
        local n = names[i]:get()
        local sl, tsl = real:GetSlot(n), cont:FindOrCreateSlot(n)
        pcall(function() tsl:SetCapacity(sl:GetCapacity()) end)
    end
    for slot, want in pairs(equip) do
        local okF, done = pcall(fillSlot, cont, slot, want, FindFirstOf("PlayerController"))
        if not (okF and done) then M.equipStats.errors = M.equipStats.errors + 1 end
    end
    return cont
end

-- The other side: the owner's contents onto the twin's container (slots the local player just changed wait until
-- the owner's line has it: PENDING_S)
local PENDING_S = 4
local STRAY_S = 1.5 -- a part gone from a twin slot and not with the local player after this long: not taken (watchEquip)
function M.applyEquip(twin, equip)
    local cm = manager()
    local ign, gear
    pcall(function() ign, gear = cm.CarIgnitionState, cm.MyCarGearBox end)
    local wasOwn = M.ctxIsOwn(cm)
    local n = M._applyEquip(twin, equip)
    -- (parts spawned onto the twin: the own car's key and lever kept, as at its spawn and its removal)
    if n and n > 0 then M.keepEngine(cm, ign, gear, wasOwn) end
    return n
end
function M._applyEquip(twin, equip)
    local e = equipOf[twin:GetAddress()]
    local cont = e and Sync.deref(e.cont)
    if not cont then return 0 end
    local now = os.clock()
    local cur, n = contents(cont), 0
    local slots = {}
    for k in pairs(equip) do slots[k] = true end
    for k in pairs(cur) do slots[k] = true end
    for slot in pairs(slots) do
        local want = equip[slot] or "-"
        local p = e.pending[slot]
        if p and now - p < PENDING_S and want ~= (cur[slot] or "-") then
            -- (the owner has not seen our change yet)
        elseif want ~= (cur[slot] or "-") then
            local ok, done = pcall(fillSlot, cont, slot, want, FindFirstOf("PlayerController"))
            if ok and done then n = n + 1 else M.equipStats.errors = M.equipStats.errors + 1 end
            e.applied[slot] = want
            e.pending[slot] = nil
        else
            e.applied[slot] = want
            e.pending[slot] = nil
        end
    end
    M.equipStats.applied = M.equipStats.applied + n
    return n
end
-- The other side: what the local player changed on the twin since (slot, "path@ctx" | "-") - for EX lines. A part
-- that left a slot without reaching the local player (broke off, fell off, destroyed here) is not the player's doing:
-- the owner's part stays, the twin gets it back (and the loose one here goes).
function M.watchEquip(twin)
    local e = equipOf[twin:GetAddress()]
    local cont = e and Sync.deref(e.cont)
    if not cont then return {} end
    local insts = {}
    local cur, out = contents(cont, insts), {}
    local slots = {}
    for k in pairs(e.applied) do slots[k] = true end
    for k in pairs(cur) do slots[k] = true end
    local restored = false
    e.leftAt = e.leftAt or {}
    for slot in pairs(slots) do
        local now = cur[slot] or "-"
        local was = e.applied[slot] or "-"
        local old = e.inst and e.inst[slot]
        if now == was then
            e.leftAt[slot] = nil
        elseif now == "-" and old and not heldByPlayer(old) then
            -- not (yet) with the player: on the way to the hand the item may be in no slot for a moment
            e.leftAt[slot] = e.leftAt[slot] or os.clock()
            if os.clock() - e.leftAt[slot] < STRAY_S then
                insts[slot] = old
            else
                e.leftAt[slot] = nil
                pcall(function() if old:IsValid() then old:Remove(true) end end)
                local ok, done = pcall(fillSlot, cont, slot, was, FindFirstOf("PlayerController"))
                if not (ok and done) then M.equipStats.errors = M.equipStats.errors + 1 end
                M.equipStats.strays = (M.equipStats.strays or 0) + 1
                restored = true
            end
        else
            e.leftAt[slot] = nil
            out[#out + 1] = { slot = slot, want = now }
            e.applied[slot] = now
            e.pending[slot] = os.clock()
        end
    end
    if restored then insts = {} contents(cont, insts) end
    e.inst = insts
    M.equipStats.local_ = M.equipStats.local_ + #out
    return out
end
-- Owner side: the other player took a part off its twin of this car ("-": the item is in that player's inventory now,
-- it leaves this game) or put one on (a new instance here; the other player's item left its inventory)
function M.ownerEquip(slot, want)
    local cont = realContainer()
    if not (cont and cont:IsValid()) then return "no car container" end
    local ok, done = pcall(fillSlot, cont, slot, want, FindFirstOf("PlayerController"))
    M.equipStats.owner = M.equipStats.owner + 1
    if not (ok and done) then M.equipStats.errors = M.equipStats.errors + 1 return "failed: " .. tostring(done) end
    return "ok"
end
function M.equipInfo(twin)
    local e = twin and equipOf[twin:GetAddress()]
    local cont = e and Sync.deref(e.cont)
    local n = 0
    if cont then for _ in pairs(contents(cont)) do n = n + 1 end end
    local s = M.equipStats
    return string.format("equip_items=%d equip_applied=%d equip_local=%d equip_owner=%d equip_errors=%d equip_strays=%d", n, s.applied, s.local_, s.owner, s.errors, s.strays or 0)
end
-- the twin's container (tests / probes)
function M.twinContainer(twin)
    local e = twin and equipOf[twin:GetAddress()]
    return e and Sync.deref(e.cont)
end
-- the twin's slot contents as "slot=path" (tests)
function M.twinSlot(twin, slot)
    local e = equipOf[twin:GetAddress()]
    local cont = e and Sync.deref(e.cont)
    return cont and (contents(cont)[slot] or "-") or "no container"
end

-- ===== Part state (twin rework stage B) =====
-- The parts' health / fuel / battery, through the parts' own components (BP_HealthComponent_C SetHealth,
-- BP_FuelableComponent_C Set Fuel, BP_BatteryComponent_C Set Battery: what the game's repair, refuel and charge
-- end in). The owner's values go to the twin (ES lines, "slot=h,f,b", empty where the part has no such component);
-- what the local player did on the twin goes to the owner as a change (EY lines: slot, kind, delta). Damage on the
-- twin is not sent: the owner's own physics damages its car (the twin hit here is that car hit there).
-- A part's look is not its health: the wear the player sees (dents, scorch, radiation stain) is the health component's
-- visual damage (ST_VisualDamage Impact / Radiation / Burn, 0..1, kept in the item's properties; each hit adds to it),
-- shown as the part materials' Impact_Amount / Burn_Amount / Radiation_Amount by UpdateDamageVisuals (SetHealth
-- changes no material - probed 2026-11-02; owner's alpha 18 item 14: "an almost broken part of the host's car looks new
-- on the guest"). These three go along as kinds i / r / u: owner -> twin only (the owner's hits make them).
--   ES <time> <slot>=<health>,<fuel>,<battery>,<impact>,<radiation>,<burn>,<break>;...   owner -> the other side
--                                                     (changed: every 1 s, else every 10 s)
--   EY <time> <slot> <h|f|b> <delta>                    the other side -> owner
local COMP = "/Game/Gameplay/Inventory/GenericItemProperties/Components/"
local stateCls
local function stateClasses()
    if not stateCls then
        stateCls = { h = SFO(COMP .. "BP_HealthComponent.BP_HealthComponent_C"), f = SFO(COMP .. "BP_FuelableComponent.BP_FuelableComponent_C"),
            b = SFO(COMP .. "BP_BatteryComponent.BP_BatteryComponent_C") }
        for k, c in pairs(stateCls) do if not (c and c:IsValid()) then stateCls[k] = nil end end
    end
    return stateCls
end
local function outs(obj, fn, n)
    local ts = {}
    for i = 1, n do ts[i] = {} end
    obj[fn](obj, table.unpack(ts))
    local r = {}
    for _, t in ipairs(ts) do for k, v in pairs(t) do r[k] = v end end
    return r
end
-- kind -> { get = function(comp) -> value, set = function(comp, value) }
local KINDS = {
    h = { get = function(c) return c:HC_GetHealth() end, set = function(c, v) c:SetHealth(v) end },
    f = { get = function(c) return outs(c, "GetFuelStatus", 7).Fuel end, set = function(c, v) c["Set Fuel"](c, v) end },
    b = { get = function(c) return outs(c, "GetBatteryStatus", 5).BATTERY end, set = function(c, v) c["Set Battery"](c, v) end },
}
-- the visual damage's fields (their names carry a GUID: matched by the start)
local VIS = { i = "^Impact", r = "^Radiation", u = "^Burn" }
for kind, pat in pairs(VIS) do
    KINDS[kind] = {
        get = function(c)
            local t = {}
            c:GetVisualDamageValues(t)
            for k, x in pairs(t) do if tostring(k):find(pat) then return x end end
        end,
        set = function(c, v)
            local t, w = {}, {}
            c:GetVisualDamageValues(t)
            for k, x in pairs(t) do w[k] = tostring(k):find(pat) and v or x end
            c:SetVisualDamageValues(w)
            c:UpdateDamageVisuals()
        end,
    }
end
-- the break health (k): the red bar, after the white one ran out - hits fill it up to the item's MaxBreak, then the
-- part breaks off (statesync CoopSyncWreck; owner's two-games test 2026-11-11: "a part's bar gone red showed as an
-- empty white bar on the other side" - only the white one went along). The twin's part can break then
-- (CanBeBreaking, as the guest's wreck parts).
KINDS.k = {
    get = function(c) return c:HC_GetBreakHealth() end,
    set = function(c, v) if v > 0 then c.CanBeBreaking = true end c:SetBreakHealth(v) end,
}
local KIND_ORDER = { "h", "f", "b", "i", "r", "u", "k" }
local KIND_FMT = { h = "%.1f", f = "%.1f", b = "%.1f", i = "%.2f", r = "%.2f", u = "%.2f", k = "%.1f" }
local OWNER_ONLY = { i = true, r = true, u = true, k = true } -- (not sent back from the twin: the owner's hits make them)
-- (kept 5 s per item: GetActorManifestation + 3 component lookups per part made the state line 6 ms. As native
-- weak handles: Lua objects kept across a travel were freed memory - IsValid passed, a property read crashed the
-- host, revisit test 2026-10-28. The manifestation's address checked too: a new item can come at an old address.)
local compCache = {}
local function partComps(it)
    if not (CoopNative_RefPath and CoopNative_Get) then return M._partComps(it) end
    local k = it:GetAddress()
    local e = compCache[k]
    if e and os.clock() - e.t < 5 then
        local a = it:GetActorManifestation()
        local t = a and a:IsValid() and a:GetAddress() == e.actor and {}
        for kind, h in pairs(t and e.handles or {}) do
            local c = CoopNative_Get(h)
            if not c then t = nil break end
            t[kind] = c
        end
        if t then return t end
    end
    local t = M._partComps(it)
    if t then
        local hs = {}
        local all = true
        for kind, c in pairs(t) do
            hs[kind] = CoopNative_RefPath((c:GetFullName():gsub("^%S+ ", "")))
            all = all and hs[kind] ~= nil
        end
        local a = it:GetActorManifestation()
        compCache[k] = all and { t = os.clock(), actor = a and a:IsValid() and a:GetAddress(), handles = hs } or nil
    end
    return t
end
function M._partComps(it)
    local a = it:GetActorManifestation()
    if not (a and a:IsValid()) then return nil end
    local t = {}
    for k, c in pairs(stateClasses()) do
        local x = a:GetComponentByClass(c)
        -- (not the charge port's: its battery is the local car's batteries added up - GetBatteryStatus / ModifyBattery
        -- overridden - so on the twin it read the own car, and setting it did nothing; soak test 2026-10-28)
        if x and x:IsValid() and not (k == "b" and x:GetClass():GetFName():ToString() == "BP_BatteryComponent_ChargePort_C") then t[k] = x end
    end
    if t.h then t.i, t.r, t.u, t.k = t.h, t.h, t.h, t.h end -- (the visual damage, the break health: the health component's)
    return t
end
-- slot -> { comps = { kind = component }, v = { kind = value } } of a container's parts with any state
local function stateOf(cont)
    local r = {}
    local names = {}
    cont:GetSlotNames(names)
    for i = 1, #names do
        local n = names[i]:get()
        local sl = cont:GetSlot(n)
        if sl and sl:IsValid() and sl.Items:GetArrayNum() > 0 then
            local comps = partComps(sl.Items[1])
            if comps and next(comps) then
                local v = {}
                for k, c in pairs(comps) do local ok, x = pcall(KINDS[k].get, c) if ok and type(x) == "number" then v[k] = x end end
                r[n:ToString()] = { comps = comps, v = v }
            end
        end
    end
    return r
end
M.stateStats = { applied = 0, local_ = 0, owner = 0, errors = 0 }
-- the twin's parts' health added up (tests: the owner's damage shown on the twin)
function M.twinStateSum(twin)
    local e = twin and equipOf[twin:GetAddress()]
    local cont = e and Sync.deref(e.cont)
    if not cont then return nil end
    local s = 0
    for _, x in pairs(stateOf(cont)) do s = s + (x.v.h or 0) end
    return string.format("%.1f", s)
end
-- Owner side: its parts' state as one line (`cont`: another car's, as equipLine)
function M.stateLine(cont)
    cont = cont or realContainer()
    if not (cont and cont:IsValid()) then return nil end
    local s, keys = stateOf(cont), {}
    for k in pairs(s) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local v, f = s[k].v, {}
        for i, kind in ipairs(KIND_ORDER) do f[i] = v[kind] and string.format(KIND_FMT[kind], v[kind]) or "" end
        parts[#parts + 1] = k .. "=" .. table.concat(f, ",")
    end
    return table.concat(parts, ";")
end
function M.parseState(s)
    local t = {}
    for k, v in (s or ""):gmatch("([^=;]+)=([^;]+)") do
        local x = {}
        for f in (v .. ","):gmatch("([^,]*),") do x[#x + 1] = f end
        local e = {}
        for i, kind in ipairs(KIND_ORDER) do e[kind] = tonumber(x[i]) end
        t[k] = e
    end
    return t
end
local STATE_EPS = { h = 0.5, f = 0.05, b = 0.05, i = 0.015, r = 0.015, u = 0.015, k = 0.5 }
-- the twin is the game's car here (the manager on it) and simulates on this side: the local player drives it
function M.drivenHere(twin)
    local cm = manager()
    local onTwin = cm and cm.NewCarActor
    if not (onTwin and onTwin:IsValid() and onTwin:GetAddress() == twin:GetAddress()) then return false end
    local ok, sim = pcall(function() return twin.RootComponent:IsSimulatingPhysics(FName("None")) end)
    return ok and sim == true
end
-- The other side: the owner's values onto the twin's parts (a slot the local player just changed waits PENDING_S
-- for the owner's line to have it)
function M.applyState(twin, want)
    local e = equipOf[twin:GetAddress()]
    local cont = e and Sync.deref(e.cont)
    if not cont then return 0 end
    e.state = e.state or {}
    e.statePending = e.statePending or {}
    -- (driven here: this side's values are the car's - M.watchState sends them; an owner's line from before the hit
    -- set here first would have wiped the hit before it was seen)
    if e.state and next(e.state) and M.drivenHere(twin) then M.stateStats.heldDriven = (M.stateStats.heldDriven or 0) + 1 return 0 end
    local now, n = os.clock(), 0
    for slot, cur in pairs(stateOf(cont)) do
        local w = want[slot]
        local p = e.statePending[slot]
        if w and not (p and now - p < PENDING_S) then
            local seen = {}
            for kind, c in pairs(cur.comps) do
                local x, have = w[kind], cur.v[kind]
                if x and have and math.abs(x - have) > STATE_EPS[kind] then
                    local ok = pcall(KINDS[kind].set, c, x)
                    if ok then n = n + 1 else M.stateStats.errors = M.stateStats.errors + 1 end
                    local ok2, back = pcall(KINDS[kind].get, c)
                    seen[kind] = ok2 and back or x
                else
                    seen[kind] = have
                end
            end
            e.state[slot] = seen
            e.statePending[slot] = nil
        end
    end
    M.stateStats.applied = M.stateStats.applied + n
    return n
end
-- The other side: what the local player changed on the twin's parts since (slot, kind, delta) - for EY lines.
-- Not driven here: only upwards (repair, refuel, charge) - what runs down on a twin is the owner's car's own business.
-- Driven here (the local player at its wheel, the twin simulating on this side): everything, see `driven` below.
function M.watchState(twin)
    local e = equipOf[twin:GetAddress()]
    local cont = e and Sync.deref(e.cont)
    if not (cont and e.state) then return {} end
    local out = {}
    local cm = manager()
    local onTwin = cm and cm.NewCarActor
    local inside = (onTwin and onTwin:IsValid() and onTwin:GetAddress() == twin:GetAddress()) and true or false
    -- Driven here (native cars: the car simulates on the side of the player at its wheel - its hits, its wear, its
    -- fuel and battery are this side's; the owner's car is a puppet meanwhile): every change goes to the owner, both
    -- ways (owner's two-games test 2026-11-14: the guest drove the host's car into things - its front right panel full
    -- red on the guest, still some white on the host).
    local driven = inside and M.drivenHere(twin)
    for slot, cur in pairs(stateOf(cont)) do
        local was = e.state[slot]
        if was then
            for kind, x in pairs(cur.v) do
                local d = was[kind] and (x - was[kind]) or 0
                if (driven and math.abs(d) > STATE_EPS[kind]) or (inside == false and not OWNER_ONLY[kind] and d > STATE_EPS[kind]) then
                    out[#out + 1] = { slot = slot, kind = kind, delta = d }
                    e.statePending[slot] = os.clock()
                end
                was[kind] = x
            end
        else
            local seen = {}
            for kind, x in pairs(cur.v) do seen[kind] = x end
            e.state[slot] = seen
        end
    end
    -- (fuel siphoned here from the twin's tanks - gascap.lua: downwards, so not seen above)
    for _, x in ipairs(e.siphoned or {}) do out[#out + 1] = x end
    e.siphoned = nil
    M.stateStats.local_ = M.stateStats.local_ + #out
    return out
end
-- fuel taken out of one of the twin's tanks by the local player (the other's car's gas cap): to the owner with the
-- next EY lines (the tank's component: the twin's part's BP_FuelableComponent_C)
function M.noteSiphon(twin, comp, amount)
    local e = twin and equipOf[twin:GetAddress()]
    local cont = e and Sync.deref(e.cont)
    if not (cont and comp and amount and amount > 0) then return false end
    for slot, cur in pairs(stateOf(cont)) do
        local f = cur.comps.f
        if f and f:GetAddress() == comp:GetAddress() then
            e.siphoned = e.siphoned or {}
            table.insert(e.siphoned, { slot = slot, kind = "f", delta = -amount })
            if e.state and e.state[slot] then e.state[slot].f = cur.v.f end
            return true
        end
    end
    return false
end
-- Owner side: the other player repaired / refuelled / charged (or siphoned) a part of this car on its twin
function M.ownerState(slot, kind, delta)
    local cont = realContainer()
    local k = KINDS[kind]
    if not (cont and cont:IsValid() and k and delta) then return "bad" end
    local sl = cont:GetSlot(FName(slot))
    if not (sl and sl:IsValid() and sl.Items:GetArrayNum() > 0) then return "empty slot" end
    local comps = partComps(sl.Items[1])
    local c = comps and comps[kind]
    if not c then return "no component" end
    local ok, err = pcall(function() k.set(c, math.max(0, k.get(c) + delta)) end)
    M.stateStats.owner = M.stateStats.owner + 1
    if not ok then M.stateStats.errors = M.stateStats.errors + 1 return "failed: " .. tostring(err) end
    return "ok"
end
function M.stateInfo()
    local s = M.stateStats
    return string.format("state_applied=%d state_local=%d state_owner=%d state_errors=%d", s.applied, s.local_, s.owner, s.errors)
end

---------------------------------------------------------------------------------------------------
-- Lights (twin rework stage C). The game keeps ONE lights state - the car manager's headlights, top light and
-- ignition (rear and dash lights) - and every car shows it: the twin showed the LOCAL player's lights, never its
-- owner's, and its headlights stayed dark (their battery consumers find the battery through the manager - the own
-- car's: probe cmds/consumer-battery.lua; given the twin's own battery they lit with the LOCAL state). There is no
-- second lights state in the game, so the twin shows what the owner's game made of its car: the intensity and
-- visibility of each of its light components (the body's by component name, a part's by its slot) onto the twin's
-- same components. The headlight parts' own tick (BaseLightTick: their light every frame from the manager) is off on
-- the twin.
--   LI <time> <key>=<intensity>[h];...     owner -> the other side (h: hidden; changed: 5 a second at most, else 5 s)
local LIGHT_CLS
local lightCache = {} -- car address -> { at = clock, list = { { key, light path, headlight part path | nil, body } } }
local function lightsOf(car, cont)
    local now = os.clock()
    local c = lightCache[car:GetAddress()]
    if c and now - c.at < 2 then return c.list end
    LIGHT_CLS = LIGHT_CLS or SFO("/Script/Engine.LightComponent")
    local list = {}
    local comps = car:K2_GetComponentsByClass(LIGHT_CLS)
    for i = 1, #comps do
        local x = comps[i]:get()
        list[#list + 1] = { "body|" .. x:GetFName():ToString(), Sync.ref(x), nil, true }
    end
    local insts = {}
    contents(cont, insts)
    for slot, it in pairs(insts) do
        local a = it:GetActorManifestation()
        if a and a:IsValid() then
            local pc = a:K2_GetComponentsByClass(LIGHT_CLS)
            local head = #pc > 0 and a:GetClass():GetFName():ToString():find("Headlight", 1, true) and Sync.ref(a) or nil
            for i = 1, #pc do
                local x = pc[i]:get()
                list[#list + 1] = { slot .. "|" .. x:GetFName():ToString(), Sync.ref(x), head }
            end
        end
    end
    lightCache[car:GetAddress()] = { at = now, list = list }
    return list
end
-- Owner side: its car's lights as one line (`cont`: the twin's, as equipLine)
function M.lightLine(car, cont)
    cont = cont or realContainer()
    if not (car and cont and cont:IsValid()) then return nil end
    local parts = {}
    for _, l in ipairs(lightsOf(car, cont)) do
        local x = Sync.deref(l[2])
        if x then
            local ok, s = pcall(function() return string.format("%s=%.1f%s", l[1], x.Intensity, x:IsVisible() and "" or "h") end)
            if ok then parts[#parts + 1] = s end
        end
    end
    table.sort(parts)
    return table.concat(parts, ";")
end
-- The other side: the owner's lights onto the twin (again every call: the twin's own car logic sets them from the
-- local state on its events)
function M.applyLights(twin, s)
    local e = equipOf[twin:GetAddress()]
    local cont = e and Sync.deref(e.cont)
    if not (cont and s) then return 0 end
    local want = {}
    for k, v in s:gmatch("([^=;]+)=([^;]+)") do want[k] = v end
    e.lightsWant = want
    e.lightTickOff = e.lightTickOff or {}
    local n = 0
    for _, l in ipairs(lightsOf(twin, cont)) do
        local w = want[l[1]]
        local x = w and Sync.deref(l[2])
        if x then
            if l[3] and not e.lightTickOff[l[3]] then
                local a = Sync.deref(l[3])
                if a then pcall(function() a:SetActorTickEnabled(false) end) end
                e.lightTickOff[l[3]] = true
            end
            local v, hidden = tonumber(w:match("^[%d%.%-]+")), w:sub(-1) == "h"
            pcall(function()
                if v and math.abs(x.Intensity - v) > 0.05 then x:SetIntensity(v) n = n + 1 end
                if x:IsVisible() == hidden then x:SetVisibility(not hidden, false) n = n + 1 end
            end)
        end
    end
    M.stats.lightsSet = (M.stats.lightsSet or 0) + n
    return n
end
-- Every frame the car's ReceiveTick -> ElectronicUpdate_All sets its body lights (top, dash, rear) from the manager's
-- state (counted: both cars, each frame - cmds/car-tick-count.lua): playersync hooks ElectronicUpdate_All (UE4SS runs
-- the hook after the body) and the twin's body lights get the owner's values back right there.
local function setLight(x, w)
    local v, hidden = tonumber(w:match("^[%d%.%-]+")), w:sub(-1) == "h"
    if v and math.abs(x.Intensity - v) > 0.05 then x:SetIntensity(v) end
    if x:IsVisible() == hidden then x:SetVisibility(not hidden, false) end
end
function M.applyBodyLights(twin)
    local e = equipOf[twin:GetAddress()]
    local want = e and e.lightsWant
    local c = want and lightCache[twin:GetAddress()]
    if not c then return end
    for _, l in ipairs(c.list) do
        local w = l[4] and want[l[1]]
        local x = w and Sync.deref(l[2])
        if x then pcall(setLight, x, w) end
    end
end
-- The own car while the local player sits in the other's twin (owner, alpha 16: the guest got into the host's car and
-- its own car's headlights came on): the manager holds the twin owner's lights then, and the own car - its body lights
-- every frame, its headlight parts' own tick - showed those, and its LI lines sent them. Its lights are held as they
-- were when the player got in (like the twin: the line's values, the headlight parts' tick off) until it gets out.
local ownHeld -- { addr, want = { key -> value }, line, ticksOff = { part path -> true } }
function M.holdOwnLights(car)
    local line = car and M.lightLine(car)
    if not line then return false end
    local want = {}
    for k, v in line:gmatch("([^=;]+)=([^;]+)") do want[k] = v end
    ownHeld = { addr = car:GetAddress(), want = want, line = line, ticksOff = {} }
    M.applyHeldLights(car)
    return true
end
function M.applyHeldLights(car)
    if not (ownHeld and car and car:GetAddress() == ownHeld.addr) then return end
    local cont = realContainer()
    if not cont then return end
    for _, l in ipairs(lightsOf(car, cont)) do
        local w = ownHeld.want[l[1]]
        local x = w and Sync.deref(l[2])
        if x then
            if l[3] and not ownHeld.ticksOff[l[3]] then
                local a = Sync.deref(l[3])
                if a then pcall(function() a:SetActorTickEnabled(false) end) end
                ownHeld.ticksOff[l[3]] = true
            end
            pcall(setLight, x, w)
        end
    end
end
function M.releaseOwnLights()
    if not ownHeld then return end
    for p in pairs(ownHeld.ticksOff) do
        local a = Sync.deref(p)
        if a then pcall(function() a:SetActorTickEnabled(true) end) end
    end
    ownHeld = nil
end
function M.heldLightLine() return ownHeld and ownHeld.line or nil end
-- one part's state as "h,f,b" (tests): `twin` nil = the own car
function M.partState(twin, slot)
    local cont = twin and M.twinContainer(twin) or (not twin and realContainer())
    if not cont then return "no container" end
    local s = stateOf(cont)[slot]
    if not s then return "-" end
    local f = {}
    for i, kind in ipairs(KIND_ORDER) do f[i] = s.v[kind] and string.format(KIND_FMT[kind], s.v[kind]) or "" end
    return table.concat(f, ",")
end

-- Spawn a twin at loc / rot carrying `equip` (the owner's EQ contents). Returns the twin or nil, reason.
function M.spawn(loc, rot, equip)
    local own = M.ownCar()
    if not own then return nil, "no own car" end
    local cm, im = manager(), invManager()
    if not im then return nil, "no inventory manager" end
    local xf = KML:MakeTransform(loc, rot, { X = 1, Y = 1, Z = 1 })
    local t0 = os.clock()
    local function op(name) if CoopSyncHitch then CoopSyncHitch.op(name, (os.clock() - t0) * 1000) CoopSyncHitch.crumb("after " .. name) end t0 = os.clock() end
    local okC, cont = pcall(newContainer, equip or {})
    op("twin container")
    if not (okC and cont) then return nil, "no container: " .. tostring(cont) end
    local real = im.Inventory_CarEquipped
    -- (the own car's key and lever: a twin coming stopped the own car's engine too - gascap-test step 5)
    local ign, gear
    pcall(function() ign, gear = cm.CarIgnitionState, cm.MyCarGearBox end)
    local wasOwn = M.ctxIsOwn(cm)
    im.Inventory_CarEquipped = cont
    local ok, twin = pcall(function()
        local b = GS:BeginDeferredActorSpawnFromClass(FindFirstOf("PlayerController"), own:GetClass(), xf, 1, nil)
        return GS:FinishSpawningActor(b, xf)
    end)
    im.Inventory_CarEquipped = real
    if cm then cm.NewCarActor = own end
    M.keepEngine(cm, ign, gear, wasOwn)
    if not (ok and twin and twin:IsValid()) then return nil, "spawn failed: " .. tostring(twin) end
    CoopSyncTwins[twin:GetAddress()] = weakOf(twin)
    local applied = {}
    for k, v in pairs(equip or {}) do applied[k] = v end
    equipOf[twin:GetAddress()] = { cont = Sync.ref(cont), applied = applied, pending = {} }
    op("twin spawn actor")
    pcall(puppet, twin)
    op("twin puppet")
    M.stats.spawned = M.stats.spawned + 1
    -- (the other player's car green on the map, the own one stays the game's blue: marksync.lua, alpha 22 item 4)
    if CoopSyncMarks then pcall(CoopSyncMarks.paintTwin, twin) end
    print(string.format("[CoopSync] twin spawned %s at %.0f,%.0f,%.0f (cars now %d)\n", twin:GetFName():ToString(), loc.X, loc.Y, loc.Z, #(FindAllOf("BP_PlayerCarNew_C") or {})))
    return twin
end

-- InventorySystem.ItemWorldStates keeps every manifestation of an item; the twin's go before it is destroyed.
local function forgetManifestations(twin)
    local sys
    for _, s in ipairs(FindAllOf("InventorySystem") or {}) do
        if s:IsValid() and not s:GetFullName():find("Default__", 1, true) then sys = s end
    end
    if not sys then return end
    sys.ItemWorldStates:ForEach(function(_, v)
        local arr = v:get().ActiveManifestations
        local keep, drop = {}, 0
        for i = 1, #arr do
            local a = arr[i]
            if a and a:IsValid() and underCar(a, twin) then drop = drop + 1 else keep[#keep + 1] = a end
        end
        if drop > 0 then
            arr:Empty()
            for i, a in ipairs(keep) do arr[i] = a end
        end
    end)
end

-- The own car's ignition and lever as they were before a twin went (the car manager's: now and once more after the
-- frames its parts' end ran in); only while the own car is the manager's car, and only a running engine that stopped
-- (its lever with it). (The lever alone was put back too at first: read while the player sat in the other's car - the
-- manager's state then that car's, in drive - it went onto the own car the game had just parked as the player got
-- out, and the own car rolled 60 m down the slope; cars-test 2026-11-10)
-- (the manager's car the own car when its state was read: the state is the context car's)
function M.ctxIsOwn(cm)
    local own = M.ownCar and M.ownCar()
    local ctx = cm and cm:IsValid() and cm.NewCarActor
    return own ~= nil and ctx and ctx:IsValid() and ctx:GetAddress() == own:GetAddress() or false
end
function M.keepEngine(cm, ign, gear, wasOwn)
    if ign ~= 2 or not wasOwn then return end
    local function put()
        if not (cm and cm:IsValid()) then return end
        local own = M.ownCar and M.ownCar()
        local ctx = cm.NewCarActor
        if not (own and own:IsValid() and ctx and ctx:IsValid() and ctx:GetAddress() == own:GetAddress()) then return end
        if cm.CarIgnitionState ~= ign then
            pcall(function() cm:SetCarIgnitionState(ign) end)
            M.stats.engineKept = (M.stats.engineKept or 0) + 1
            if gear ~= nil and cm.MyCarGearBox ~= gear then pcall(function() cm:SetCarGearBoxState(gear) end) end
        end
    end
    put()
    if CoopSyncAfter then CoopSyncAfter(100, put) CoopSyncAfter(500, put) end
end
-- Remove a twin and everything attached under it (a character sitting in it is detached and kept).
function M.destroy(twin)
    if not (twin and twin:IsValid()) then return 0 end
    local cm = manager()
    if cm and cm.NewCarActor and cm.NewCarActor:IsValid() and cm.NewCarActor:GetAddress() == twin:GetAddress() then M.managerToOwn() end
    -- (the own car's key and lever now: destroying the twin's parts stopped the own car's engine - the parts' handlers
    -- are the car manager's, one for both cars; owner 2026-11-09: "the friend connected, my car stalled at once")
    local ign, gear
    pcall(function() ign, gear = cm.CarIgnitionState, cm.MyCarGearBox end)
    local wasOwn = M.ctxIsOwn(cm)
    -- (its container is left alone: emptying it spawns placeholder parts, which inside the travel pre-hook hung both
    -- games in the save's FlushAsyncLoading; the container's outer is the transient package, it goes with the GC)
    pcall(forgetManifestations, twin)
    local pawn = FindFirstOf("PlayerController").Pawn
    local list = Ghost.descendants(twin)
    local n = 0
    for _, a in ipairs(list) do
        if pawn and pawn:IsValid() and a:GetAddress() == pawn:GetAddress() then
            pcall(function() a:K2_DetachFromActor(1, 1, 1) end)
        elseif a:IsValid() and a:GetClass():GetFName():ToString() == "SkeletalMeshActor" then
            pcall(function() a:K2_DetachFromActor(1, 1, 1) end) -- the other player's puppet
        else
            pcall(function() a:K2_DestroyActor() end)
            n = n + 1
        end
    end
    equipOf[twin:GetAddress()] = nil
    CoopSyncTwins[twin:GetAddress()] = nil
    poseCache[twin:GetAddress()] = nil
    lit[twin:GetAddress()] = nil
    mutedDoors[twin:GetAddress()] = nil
    bodyOf[twin:GetAddress()] = nil
    lightCache[twin:GetAddress()] = nil
    local name = twin:GetFName():ToString()
    pcall(function() twin:K2_DestroyActor() end)
    M.keepEngine(cm, ign, gear, wasOwn)
    M.stats.removed = M.stats.removed + 1
    print(string.format("[CoopSync] twin %s removed with %d attached\n", name, n))
    return n + 1
end

-- A second copy of the own car (owner's alpha 17-20 tests: "the guest has its car twice, getting out moves it into
-- the other one"; nextzone "EXTRA CAR: 2 cars, 0 twins"): a zone's load sometimes builds the player's car twice -
-- two BP_PlayerCarNew_C 150 ms apart, the same spot, both manifesting the same equipped items (probed 2026-11-10:
-- 67 of the items with a part on each). The one the player sits in stays (else the manager's); the other's parts are
-- taken out of the items' manifestations and it goes. Only a car sharing items with the kept one: a copy, nothing
-- else. Returns the cars removed.
function M.dropCopies()
    local cm = manager()
    if not (cm and cm:IsValid()) then return 0 end
    local cars = {}
    for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
        local root = c:IsValid() and c.RootComponent
        local at = root and root:IsValid() and c:K2_GetActorLocation()
        if at and (at.X ~= 0 or at.Y ~= 0 or at.Z ~= 0) and c:GetFullName():find(":PersistentLevel.", 1, true)
            and not c:IsActorBeingDestroyed() and not M.isTwin(c) then cars[#cars + 1] = c end
    end
    if #cars < 2 then return 0 end
    -- (not while the player sits in a twin: the next look)
    local pawn = FindFirstOf("PlayerController").Pawn
    local p = pawn and pawn:IsValid() and pawn:GetAttachParentActor()
    local seatCar
    for _ = 1, 6 do
        if not (p and p:IsValid()) then break end
        if M.isTwin(p) then return 0 end
        for _, c in ipairs(cars) do if c:GetAddress() == p:GetAddress() then seatCar = c end end
        if seatCar then break end
        p = p:GetAttachParentActor()
    end
    -- the kept one: the car the items' own manifestation is on (the item's link - GetActorManifestation - points to
    -- one car's part; the first try kept the player's seat's car, the other's parts went, and the game crashed on an
    -- item's link to a freed part 20 s later, 2026-11-10). The player's seat or the manager's only on a tie.
    local keep, best = nil, -1
    for _, c in ipairs(cars) do
        local links = 0
        local okC, comps = pcall(function() return c:K2_GetComponentsByClass(SSC) end)
        for i = 1, (okC and comps and #comps or 0) do
            local sl = comps[i]:get().ItemSlot
            if sl and sl:IsValid() then
                for j = 1, sl.Items:GetArrayNum() do
                    local m = sl.Items[j]:GetActorManifestation()
                    if m and m:IsValid() and underCar(m, c) then links = links + 1 end
                end
            end
        end
        local ctx = cm.NewCarActor
        local tie = (seatCar and seatCar:GetAddress() == c:GetAddress() and 0.2 or 0)
            + ((ctx and ctx:IsValid() and ctx:GetAddress() == c:GetAddress()) and 0.1 or 0)
        if links + tie > best then keep, best = c, links + tie end
    end
    if not keep then return 0 end
    -- (an item linked to a part of a car that would go: a link to a freed part - left as it is, noted once)
    local away = 0
    local okK, kc = pcall(function() return keep:K2_GetComponentsByClass(SSC) end)
    for i = 1, (okK and kc and #kc or 0) do
        local sl = kc[i]:get().ItemSlot
        if sl and sl:IsValid() then
            for j = 1, sl.Items:GetArrayNum() do
                local m = sl.Items[j]:GetActorManifestation()
                if m and m:IsValid() and not underCar(m, keep) then away = away + 1 end
            end
        end
    end
    if away > 0 then
        if not M.copyNoted then M.copyNoted = true print(string.format("[CoopSync] own car's copy kept: %d items linked to it\n", away)) end
        M.stats.copyKept = (M.stats.copyKept or 0) + 1
        return 0
    end
    -- the items with a part on the kept car and one on another: that other is a copy
    local sys
    for _, s in ipairs(FindAllOf("InventorySystem") or {}) do
        if s:IsValid() and not s:GetFullName():find("Default__", 1, true) then sys = s end
    end
    if not sys then return 0 end
    local shared = {}
    sys.ItemWorldStates:ForEach(function(_, v)
        local arr = v:get().ActiveManifestations
        local onKeep, others = false, {}
        for i = 1, #arr do
            local a = arr[i]
            if a and a:IsValid() then
                if underCar(a, keep) then onKeep = true
                else for k, c in ipairs(cars) do if c:GetAddress() ~= keep:GetAddress() and underCar(a, c) then others[k] = true end end end
            end
        end
        if onKeep then for k in pairs(others) do shared[k] = (shared[k] or 0) + 1 end end
    end)
    cm.NewCarActor = keep
    local n = 0
    for k, c in ipairs(cars) do
        if c:GetAddress() ~= keep:GetAddress() and (shared[k] or 0) >= 10 then
            local name, items = c:GetFName():ToString(), shared[k]
            M.destroy(c)
            n = n + 1
            M.stats.copiesDropped = (M.stats.copiesDropped or 0) + 1
            print(string.format("[CoopSync] own car's copy %s removed (%d items on both; kept %s, %d links)\n", name, items, keep:GetFName():ToString(), math.floor(best)))
        end
    end
    -- the player sat in the removed copy (detached with it): into the kept car, the game's way
    if n > 0 and seatCar and seatCar:GetAddress() ~= keep:GetAddress() and pawn and pawn:IsValid() then
        pcall(function() pawn:CommandEnterCar(true, nil, false) end)
        M.stats.copySeat = (M.stats.copySeat or 0) + 1
    end
    return n
end

---------------------------------------------------------------------------------------------------
-- the rear-view mirror (owner, 2026-10-24: on the twin it was dead). The twin's mirror capture (ScenecaptureMirror)
-- drew into the asset RT_Rearview while the twin's interior used the SAME mirror material instance as the own car
-- (its RearviewMirrorRT = the own car's capture): the twin's mirror showed the view behind the own car. A render
-- target of the own one's size for the twin's capture, and a material instance of its own in the twin's interior slot.
-- (The screens - car computer, status box, battery bar - need nothing since the clean spawn: the twin's parts are the
-- game's own and draw their widgets into render targets of their own, seen lit in a graphics run 2026-10-27.)
local KRL = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
function M._fixMirror(own, twin)
    local cap, ownCap = twin.ScenecaptureMirror, own.ScenecaptureMirror
    local ownRT = ownCap.TextureTarget
    if not (ownRT and ownRT:IsValid()) then return "own mirror has no render target" end
    local rt = KRL:CreateRenderTarget2D(twin, ownRT.SizeX, ownRT.SizeY, ownRT.RenderTargetFormat, { R = 0, G = 0, B = 0, A = 1 }, false)
    if not (rt and rt:IsValid()) then return "no render target" end
    cap.TextureTarget = rt
    -- the interior slot whose material samples the own mirror target
    local oi, ti = own.Interior, twin.Interior
    for mi = 0, oi:GetNumMaterials() - 1 do
        local m = oi:GetMaterial(mi)
        local okP = pcall(function()
            for k = 1, #m.TextureParameterValues do
                local x = m.TextureParameterValues[k]
                if x.ParameterValue:IsValid() and x.ParameterValue:GetAddress() == ownRT:GetAddress() then
                    local tm = ti:CreateDynamicMaterialInstance(mi, m.Parent, FName("None"))
                    tm:K2_CopyMaterialInstanceParameters(m, false)
                    tm:SetTextureParameterValue(x.ParameterInfo.Name, rt)
                    M.stats.mirror = string.format("slot %d -> %s", mi, rt:GetFName():ToString())
                end
            end
        end)
        if not okP then M.stats.mirrorErr = "slot " .. mi end
    end
    return M.stats.mirror or "mirror slot not found"
end

-- The side mirrors (alpha 9: the friend's car's mirrors dark): the front door parts' MainMesh slot with a material of
-- MI_Mirror_Rearview samples RearviewMirrorRT - on the own car the car's capture target, on the twin Black (its door
-- parts unbound). Every twin mirror slot (the interior's, the front doors') gets a material of its OWN sampling the
-- twin's capture target. The game hands every car ONE shared mirror MID (outer /Engine/Transient; owner's alpha 18
-- item 34, probe cmds/mirror-shared.lua): set on it, the twin's target went into the own car's mirrors too - the own
-- mirrors showed the parked twin's view, "frozen". So: never set the shared one for the twin, and the own car's slots
-- are put back on its own capture target. Returns how many twin slots, and the slots to watch (both cars).
local MIRROR_PARAM = FName("RearviewMirrorRT")
local function mirrorSlots(car)
    local l = {}
    local function add(mesh)
        for mi = 0, (mesh and mesh:IsValid()) and mesh:GetNumMaterials() - 1 or -1 do
            pcall(function()
                local mat = mesh:GetMaterial(mi)
                for k = 1, #mat.TextureParameterValues do
                    local x = mat.TextureParameterValues[k]
                    if x.ParameterInfo.Name:ToString() == "RearviewMirrorRT" then l[#l + 1] = { mesh = mesh, mi = mi, mat = mat, rt = x.ParameterValue } end
                end
            end)
        end
    end
    pcall(add, car.Interior)
    for _, d in ipairs(FindAllOf("BP_CarPart_Door_Base_C") or {}) do
        local par = d:IsValid() and d:GetAttachParentActor()
        if par and par:IsValid() and par:GetAddress() == car:GetAddress() then add(d.MainMesh) end
    end
    return l
end
local function sameObj(a, b) return a and b and a:IsValid() and b:IsValid() and a:GetAddress() == b:GetAddress() end
function M._mirrorDoors(twin)
    local rt = twin.ScenecaptureMirror.TextureTarget
    if not (rt and rt:IsValid()) then return 0 end
    local n, watch = 0, {}
    for _, s in ipairs(mirrorSlots(twin)) do
        pcall(function()
            local mat = s.mat
            local isMid = mat:GetClass():GetFName():ToString() == "MaterialInstanceDynamic"
            if not (isMid and sameObj(mat:GetOuter(), s.mesh)) then
                -- (a MID of this mesh: made from the slot's material - its parent and parameters when it is a MID)
                local mid = s.mesh:CreateDynamicMaterialInstance(s.mi, isMid and mat.Parent or mat, FName("None"))
                if isMid then mid:K2_CopyMaterialInstanceParameters(mat, false) end
                mid:SetTextureParameterValue(MIRROR_PARAM, rt)
                M.stats.mirrorMids = (M.stats.mirrorMids or 0) + 1
            elseif not sameObj(s.rt, rt) then
                mat:SetTextureParameterValue(MIRROR_PARAM, rt)
            end
            n = n + 1
            watch[#watch + 1] = { Sync.ref(s.mesh), s.mi, s.mesh:GetMaterial(s.mi):GetAddress() }
        end)
    end
    local own = M.ownCar()
    local ownRT = own and own.ScenecaptureMirror.TextureTarget
    if ownRT and ownRT:IsValid() then
        for _, s in ipairs(mirrorSlots(own)) do
            pcall(function()
                if not sameObj(s.rt, ownRT) then
                    s.mat:SetTextureParameterValue(MIRROR_PARAM, ownRT)
                    M.stats.mirrorOwnFixed = (M.stats.mirrorOwnFixed or 0) + 1
                end
                watch[#watch + 1] = { Sync.ref(s.mesh), s.mi, s.mesh:GetMaterial(s.mi):GetAddress() }
            end)
        end
    end
    M.stats.mirrorDoors = n
    M.stats.mirrorDoorsCalls = (M.stats.mirrorDoorsCalls or 0) + 1
    return n, watch
end
-- The doors put a new material (Black again) on the mirror slot now and then - seen ~6 s after getting into the twin:
-- the slots set last time are checked every 0.25 s (one material read each), a changed one -> mirrorDoors at once.
local function mirrorsChanged(watch)
    for _, w in ipairs(watch) do
        local m = Sync.deref(w[1])
        if not m then return true end
        local ok, same = pcall(function() return m:GetMaterial(w[2]):GetAddress() == w[3] end)
        if not (ok and same) then return true end
    end
    return false
end
-- Each car's mirror capture hides its own car's actors (its HiddenActors). Seen on the guest: the own car's list held
-- 124 actors of the twin (made while the manager pointed at it) - the friend's car never showed in the own mirrors -
-- and the twin's list 79 of the own car. Entries of the other car leave both lists (rootless ones stay).
local function rootActor(a)
    local cur, g = a, 0
    while g < 10 do
        local p = cur:GetAttachParentActor()
        if not (p and p:IsValid()) then return cur end
        cur, g = p, g + 1
    end
    return cur
end
local function dropForeignHidden(car, other)
    local cap = car.ScenecaptureMirror
    local arr = cap.HiddenActors
    local keep, dropped = {}, 0
    for i = 1, arr:GetArrayNum() do
        local v = arr[i]
        if v and v:IsValid() then
            local r = rootActor(v)
            if r:GetAddress() == other:GetAddress() then dropped = dropped + 1 else keep[#keep + 1] = v end
        end
    end
    if dropped > 0 then
        arr:Empty()
        for i, v in ipairs(keep) do arr[i] = v end
    end
    return dropped
end
function M._mirrorHidden(own, twin)
    local a = dropForeignHidden(own, twin)
    local b = dropForeignHidden(twin, own)
    M.stats.mirrorHidden = string.format("own-%d twin-%d", a, b)
    return a + b
end

-- Mirror of a twin, once it took (the capture may get its target a little after the spawn): tried at most every 2 s
-- from applyPose until done.
function M._light(twin)
    local k = twin:GetAddress()
    local s = lit[k] or { tried = -1e9 }
    lit[k] = s
    -- the side mirrors (their parts may put Black back, a door may be swapped): every 2 s, at once when a set slot
    -- changed (checked every 0.25 s); the mirrors' hidden lists every 10 s (a scan of ~300 actors)
    local changed = false
    if s.mirror and s.mirrorWatch and os.clock() - (s.watchAt or 0) > 0.25 then
        s.watchAt = os.clock()
        changed = mirrorsChanged(s.mirrorWatch)
    end
    if s.mirror and (changed or os.clock() - (s.doorsAt or 0) > 2) then
        s.doorsAt = os.clock()
        local ok, _, watch = pcall(M.mirrorDoors, twin)
        s.mirrorWatch = ok and watch or nil
        if os.clock() - (s.hiddenAt or 0) > 10 then
            s.hiddenAt = os.clock()
            local own = M.ownCar()
            if own then pcall(M.mirrorHidden, own, twin) end
        end
    end
    if s.mirror then return end
    -- (a mirror that cannot be made, retried every 2 s forever, was a steady stutter: after 5 tries every 30 s)
    s.tries = s.tries or 0
    if os.clock() - s.tried < (s.tries < 5 and 2 or 30) then return end
    s.tried, s.tries = os.clock(), s.tries + 1
    local own = M.ownCar()
    if not own then return end
    local ok, r = pcall(M.fixMirror, own, twin)
    s.mirror = ok and tostring(r):find("^slot") ~= nil
end

---------------------------------------------------------------------------------------------------
-- pose: the moving visuals of the owner's car on the twin (its vehicle simulation does not run, so its wheels,
-- steering wheel and needles stood still). Probed while driving: the car's own components FrontLeftWheel_Mesh ..
-- (spin, steer, suspension; the wheel part actors hang under them through the SLOT_Interior_*_Wheel slots),
-- *Fixture_Mesh (suspension), KeyCylinder_Temp (the key), the steering wheel part's MainMesh, the speedometer
-- part's SpeedArm / FuelArm. Car-relative transforms, as "<name>=x,y,z,pitch,yaw,roll" joined by ";".
local POSE_COMPS = { "FrontLeftWheel_Mesh", "FrontRightWheel_Mesh", "RearLeftWheel_Mesh", "RearRightWheel_Mesh",
    "FrontLeftFixture_Mesh", "FrontRightFixture_Mesh", "RearLeftFixture_Mesh", "RearRightFixture_Mesh", "KeyCylinder_Temp" }
local POSE_PARTS = { BP_CarPart_SteeringWheel_Base_C = { "MainMesh" }, BP_CarPart_Internal_Speedometer_C = { "SpeedArm", "FuelArm" },
    BP_Carpart_Shifter_Base_C = { "MainMesh" } }
-- The dash parts whose readings the owner sends (M.dashLine / applyDash below)
local DASH_CLASSES = { BP_CarPart_Internal_LimBox_C = "LB", BP_PlayerCar_Computer_C = "PC" }
local SC = StaticFindObject("/Script/Engine.SceneComponent")
-- Doors (and the trunk lid): a door part's MainMesh simulates physics while the door is open (the game's AttemptOpen
-- turns it on, AttemptShut snaps it back and off; probed: front doors yaw +-50..55, the trunk pitch -80) - on the
-- kinematic twin AttemptOpen moves nothing, so the owner's door meshes go in the pose as "D<n>.MainMesh".
-- n by the car-local spot: 1 front left, 2 front right, 3 back left, 4 back right, 5 trunk; 6 the hood (a
-- BP_Panel_Base_C whose IsHood(): it opens the same way - AttemptOpen, its MainMesh simulating, pitch ~50 - and had no
-- pose: owner's alpha 18 item 30, "the hood did not open at all").
-- On the twin a door eases toward its newest pose every frame (M.doorEase): set as each pose line came (10 a second) it
-- moved in steps (item 30: "the host's doors jerky and late").
local DOOR_CLASS = "/Game/Gameplay/Inventory/Items/Car/Doors/BP_CarPart_Door_Base.BP_CarPart_Door_Base_C"
local PANEL_CLASS = "/Game/Gameplay/Inventory/Items/Car/Panels/BP_Panel_Base.BP_Panel_Base_C"
local DOOR_EASE = 0.35 -- the share of the way to the pose per 33 ms
local function doorNumber(x, y)
    if x < -100 then return 5 end
    return (x > 70 and 1 or 3) + (y > 0 and 1 or 0)
end
M.doorNumber = doorNumber
-- name -> component path of a car (the car's components and its steering wheel / speedometer / door parts), cached
-- (rebuilt when a cached path is gone: a new map, a part swapped)
local function poseComps(car)
    local key = car:GetAddress()
    local c = poseCache[key]
    if c and c.FrontLeftWheel_Mesh and Sync.deref(c.FrontLeftWheel_Mesh) then
        -- the part actors (doors, steering wheel...) are spawned again when a part is swapped (the twin's EQ lines,
        -- the player's own E): their old paths are gone - checked once a second
        local now = os.clock()
        if now - (c.checkedAt or 0) < 1 then return c end
        c.checkedAt = now
        local fresh = true
        for n, p in pairs(c) do
            if type(p) == "string" and n:find("@actor", 1, true) and not Sync.deref(p) then fresh = false break end
        end
        if fresh then return c end
    end
    c = {}
    local want = {}
    for _, n in ipairs(POSE_COMPS) do want[n] = true end
    local comps = car:K2_GetComponentsByClass(SC)
    for i = 1, #comps do
        local x = comps[i]:get()
        local n = x:GetFName():ToString()
        if want[n] then c[n] = Sync.ref(x) end
    end
    local doorCls, panelCls = SFO(DOOR_CLASS), SFO(PANEL_CLASS)
    for _, a in ipairs(Ghost.descendants(car)) do
        if a:IsValid() and panelCls and panelCls:IsValid() and a:IsA(panelCls) then
            local p = a:GetAttachParentActor()
            local m = a.MainMesh
            local okH, hood = pcall(function() return a:IsHood() end)
            if okH and hood == true and p and p:IsValid() and p:GetAddress() == car:GetAddress() and m and m:IsValid() then
                c["D6.MainMesh"] = Sync.ref(m)
                c["D6@actor"] = Sync.ref(a)
            end
        elseif a:IsValid() and doorCls and doorCls:IsValid() and a:IsA(doorCls) then
            local p = a:GetAttachParentActor()
            local m = a.MainMesh
            if p and p:IsValid() and p:GetAddress() == car:GetAddress() and m and m:IsValid() then
                local l = KML:InverseTransformLocation(car:GetTransform(), a:K2_GetActorLocation())
                local n = doorNumber(l.X, l.Y)
                c["D" .. n .. ".MainMesh"] = Sync.ref(m)
                c["D" .. n .. "@actor"] = Sync.ref(a)
            end
        elseif a:IsValid() and DASH_CLASSES[a:GetClass():GetFName():ToString()] then
            local p = a:GetAttachParentActor()
            if p and p:IsValid() and p:GetAddress() == car:GetAddress() then c[DASH_CLASSES[a:GetClass():GetFName():ToString()] .. "@actor"] = Sync.ref(a) end
        elseif a:IsValid() then
            local list = POSE_PARTS[a:GetClass():GetFName():ToString()]
            local p = list and a:GetAttachParentActor()
            if p and p:IsValid() and p:GetAddress() == car:GetAddress() then
                local cn = a:GetClass():GetFName():ToString()
                local short = cn:find("Speedometer") and "SP" or (cn:find("Shifter") and "SH" or "SW")
                local pc = a:K2_GetComponentsByClass(SC)
                for i = 1, #pc do
                    local x = pc[i]:get()
                    for _, n in ipairs(list) do if x:GetFName():ToString() == n then c[short .. "." .. n] = Sync.ref(x) end end
                end
                c[short .. "@actor"] = Sync.ref(a)
            end
        end
    end
    poseCache[key] = c
    return c
end
-- the pose components of a car (name -> component path; for the twin driver's key / lever)
function M.poseParts(car) return poseComps(car) end
function M.pose(car)
    local out = {}
    local inv = KML:InvertTransform(car:GetTransform())
    local c = poseComps(car)
    c.doorOpenAt = c.doorOpenAt or {}
    local now = os.clock()
    for n, p in pairs(c) do
        if type(p) == "string" and not n:find("@") then
            local x = Sync.deref(p)
            -- a door only while open and 3 s after (its closed pose is the twin's own)
            if x and n:find("^D%d%.") then
                -- (a hidden one is shut for the other side: the driver's door swinging unseen for a back seat's exit, playersync
                -- TD.backSeatExit)
                local ok, open = pcall(function() return x:IsSimulatingPhysics(FName("None")) and x:IsVisible() end)
                if ok and open then c.doorOpenAt[n] = now end
                if now - (c.doorOpenAt[n] or -1e9) > 3 then x = nil end
            end
            if x then
                -- (the vehicle code moves these by their world transform: Relative* stay 0) - car-relative
                local rel = KML:ComposeTransforms(x:K2_GetComponentToWorld(), inv)
                local l, r = rel.Translation, KML:Quat_Rotator(rel.Rotation)
                out[#out + 1] = string.format("%s=%.1f,%.1f,%.1f,%.1f,%.1f,%.1f", n, l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll)
            end
        end
    end
    -- the wiper blades: their timeline's position, last ("WT=<pos>", no commas: the entries' pattern skips it)
    -- the dash's readings ("DB=...", no commas either; before WT, which ends the line)
    pcall(function() out[#out + 1] = M.dashLine(c) end)
    pcall(function() out[#out + 1] = string.format("WT=%.3f", car.Timeline_wiperblade:GetPlaybackPosition()) end)
    return table.concat(out, ";")
end
-- Wiper blades (probe cmds/wiper-probe.lua): every car plays its wiper timeline from the manager's one wipers state,
-- so the twin's swept with the LOCAL player's wipers. The owner's timeline position comes in the pose and the twin's
-- goes there with the game's own SetWiperTimeline (the blades follow it) - except while the local player sits in this
-- twin: the manager then holds the owner's wipers and the twin's timeline plays them itself.
local function applyWipers(twin, s)
    local wt = tonumber(s:match("WT=([%d%.%-]+)$") or "")
    if not wt then return end
    local cm = manager()
    if cm and cm.NewCarActor and cm.NewCarActor:IsValid() and cm.NewCarActor:GetAddress() == twin:GetAddress() then return end
    pcall(function() twin:SetWiperTimeline(wt) end)
end
-- The dash (owner's alpha 19 item 12: "the dashboard readings - durability, battery charge - differ"). The twin's dash
-- parts read the LOCAL car: the battery bar (the LimBox actor's tick) and its digits (the digit widgets' own Tick) and
-- the computer's health bar (its actor's tick: UpdateHealthBar) read the game instance's BP_ResourceManager_C (CarLim,
-- CarHealth: the local player's car), and the computer's part icons (UMG_CarComputer_Part_C) hold the manager's car's
-- items. Probed with graphics 2026-11-04: the guest's own charge 0.4 showed on its twin of the host's car (35 there),
-- also while the guest sat in it. So the owner puts its readings in the pose ("DB=<charge>/<max charge>/<car health>")
-- and the twin's dash parts stop reading their own: the LimBox and computer actors' ticks and the digit widgets' script
-- Tick off, the owner's values set, the part icons pointed at the twin's own items (their health is the owner's:
-- applyState). (Not done: the computer's overall status text and its clock still come from this side.)
function M.dashLine(c)
    local lb = c["LB@actor"] and Sync.deref(c["LB@actor"])
    local rm = CoopSyncFirst("BP_ResourceManager_C")
    if not (lb and rm) then return nil end
    return string.format("DB=%.2f/%.2f/%.1f", lb.CurrentBattery, lb.CurrentMaxBattery, rm.CarHealth.Current)
end
M.DASH_PARTS_S = 1 -- the part icons refreshed at most this often
local function dashParts(twin, pc)
    local cont = M.twinContainer(twin)
    if not cont then return 0 end
    local kids = pc.Widget:GetUserWidgetObject().ChildrenArray
    local n = 0
    for i = 1, kids:GetArrayNum() do
        pcall(function()
            local p = kids[i]
            local sl = cont:GetSlot(p["Gameplay Tag"].TagName)
            local it = sl and sl:IsValid() and sl.Items:GetArrayNum() > 0 and sl.Items[1] or nil
            if it and it:IsValid() then
                local cur = p.ItemInstance
                if not (cur and cur:IsValid() and cur:GetAddress() == it:GetAddress()) then p.ItemInstance = it M.stats.dashRebound = (M.stats.dashRebound or 0) + 1 end
                p:ItemHealthChanged(0)
                n = n + 1
            end
        end)
    end
    return n
end
local function applyDash(twin, c, s)
    local key = s:match("DB=([^;]+)")
    local bat, bmax, hp = (key or ""):match("^([%d%.%-]+)/([%d%.%-]+)/([%d%.%-]+)$")
    bat, bmax, hp = tonumber(bat), tonumber(bmax), tonumber(hp)
    if not (bat and bmax and hp) then return end
    local now = os.clock()
    if key == c.dashKey and now - (c.dashAt or 0) < 1 then return end
    c.dashKey, c.dashAt = key, now
    local lb = c["LB@actor"] and Sync.deref(c["LB@actor"])
    if lb then
        pcall(function()
            if lb:IsActorTickEnabled() then lb:SetActorTickEnabled(false) end
            lb.CurrentBattery, lb.TargetBattery, lb.CurrentMaxBattery, lb.TargetMaxBattery = bat, bat, bmax, bmax
            local w = lb.BatteryWidget:GetUserWidgetObject()
            if c.dashMax ~= bmax then w:SetupBatteryBar(bmax, w["Max Lim"], w.LowBatt, w.WarnBatt) c.dashMax = bmax end
            w:ChangeCurrentBattery(bat)
            for _, dv in ipairs({ { w.UMG_BatteryCurrentDisplay_1, bat }, { w.UMG_BatteryMaxDisplay_1, bmax } }) do
                local d, v = dv[1], dv[2]
                -- (the game's decimal separator: the own car's digits - the twin's showed the widget's default "8.8")
                if not c.dashSep then
                    local own = M.ownCar()
                    local ol = own and poseComps(own)["LB@actor"]
                    ol = ol and Sync.deref(ol)
                    c.dashSep = ol and ol.BatteryWidget:GetUserWidgetObject().UMG_BatteryCurrentDisplay_1.CurrentText:GetText():ToString():match("[,.]")
                end
                d.bHasScriptImplementedTick = false
                d.CurrentBattery, d.TargetBattery = v, v
                d.CurrentText:SetText(FText((string.format("%.1f", v):gsub("%.", c.dashSep or "."))))
            end
        end)
    end
    local pc = c["PC@actor"] and Sync.deref(c["PC@actor"])
    if pc then
        pcall(function()
            if pc:IsActorTickEnabled() then pc:SetActorTickEnabled(false) end
            pc.WidgetBar:GetUserWidgetObject():UpdateCurrentHealth(hp)
            pc:UpdateMaterialWithWidgetData()
        end)
        if now - (c.dashPartsAt or -1e9) >= M.DASH_PARTS_S then
            c.dashPartsAt = now
            local ok, n = pcall(dashParts, twin, pc)
            M.stats.dashParts = ok and n or -1
        end
    end
    M.stats.dash = (M.stats.dash or 0) + 1
end
M.doorLocal = {} -- door n of the other's twin opened by the game on this side (it simulates): not posed
-- the next pose moves door n again (its parts were put back by playersync)
function M.forgetDoorPose(twin, n)
    local c = poseComps(twin)
    if c then c.lastPose = nil end -- (the same pose line again is applied once a second only)
    if c and c.last then for k in pairs(c.last) do if k:sub(1, 3) == "D" .. n .. "." then c.last[k] = nil end end end
end
-- A twin's door coming off here must not touch the own car. The twin's doors hang on its chassis by a physics
-- constraint (Chassis - MainMesh); kinematic while it was built, they are not welded into its body as the own car's
-- are, so when this side drives the twin the constraints take the strain and break at once (a door held as unbreakable
-- held the whole car: it did not move). The door's OnConstraintBroken handler then destroys "the car's" door of that
-- number - the OWN car's (traced: the guest drove the host's car, the twin's doors 3, 5, 1 broke and the guest's own
-- parked car lost those doors, no item left; owner's alpha 18 "doors missing"). So the twin's doors lose that handler
-- (the owner's car breaks its own doors; the equipment line takes them off the twin), and their constraints are made
-- again when this side stops driving it (an open door would fall off).
function M.muteDoorBreak(twin)
    for n = 1, 6 do
        local d = M.door(twin, n)
        if d then
            pcall(function()
                local del = d.PhysicsConstraint.OnConstraintBroken
                for _, b in ipairs(del:GetBindings() or {}) do
                    local o = b.Object
                    if o and o:IsValid() and o:GetAddress() == d:GetAddress() then
                        del:Remove(o, b.FunctionName:ToString())
                        M.stats.doorBreakMuted = (M.stats.doorBreakMuted or 0) + 1
                    end
                end
            end)
        end
    end
end
function M.rejoinDoors(twin)
    M.muteDoorBreak(twin)
    for n = 1, 6 do
        local d = M.door(twin, n)
        if d then
            pcall(function()
                local pc = d.PhysicsConstraint
                if pc:IsBroken() then
                    pc:SetConstrainedComponents(twin.Chassis, FName("None"), d.MainMesh, FName("None"))
                    M.stats.doorsRejoined = (M.stats.doorsRejoined or 0) + 1
                end
            end)
        end
    end
end
function M.applyPose(twin, s)
    M.light(twin)
    local c = poseComps(twin)
    -- the twin's speedometer would set its needles from the twin (speed 0, the local fuel) every frame
    local sp = c["SP@actor"] and Sync.deref(c["SP@actor"])
    if sp and not c.spStopped then pcall(function() sp:SetActorTickEnabled(false) end) c.spStopped = true end
    local n = 0
    local carXf = twin:GetTransform()
    -- (a door that did not move in the car since the last pose is left alone: the twin's door parts are attached and
    -- follow it; all again once a second in case something else moved one)
    local now = os.clock()
    -- (the same pose again - 3 applies per pose line, a parked car's pose unchanged for minutes - only once a second:
    -- 4 ms an apply, the costliest part of the mod's frame; soak test 2026-10-28)
    if s == c.lastPose and now - (c.fullAt or 0) <= 1 then return 0 end
    c.lastPose = s
    if not c.last or now - (c.fullAt or 0) > 1 then c.last, c.fullAt = {}, now M.muteDoorBreak(twin) end
    for name, x, y, z, p, yw, r in s:gmatch("([%w_%.]+)=([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^;]+)") do
        local comp
        if name:byte(1) == 68 and name:find("^D%d%.") then -- "D<n>."
            local key = x .. "," .. y .. "," .. z .. "," .. p .. "," .. yw .. "," .. r
            -- (native cars: a door the game opened here simulates - the pose leaves it, M.doorLocal: playersync)
            -- (and not while a shut this side did holds: M.shutEase's hold)
            local dn = tonumber(name:sub(2, 2))
            if c.last[name] ~= key and not M.doorLocal[dn] and not (M.doorHold[dn] and now < M.doorHold[dn]) then
                -- (eased there by M.doorEase)
                c.doorGoal = c.doorGoal or {}
                c.doorGoal[name] = { l = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, r = { Pitch = tonumber(p), Yaw = tonumber(yw), Roll = tonumber(r) } }
                n = n + 1
            end
            c.last[name] = key
        else
            comp = c[name] and Sync.deref(c[name])
        end
        if comp then
            pcall(function()
                local w = KML:ComposeTransforms(KML:MakeTransform({ X = tonumber(x), Y = tonumber(y), Z = tonumber(z) },
                    { Pitch = tonumber(p), Yaw = tonumber(yw), Roll = tonumber(r) }, { X = 1, Y = 1, Z = 1 }), carXf)
                comp:K2_SetWorldLocationAndRotation(w.Translation, KML:Quat_Rotator(w.Rotation), false, {}, true)
            end)
            n = n + 1
        end
    end
    applyWipers(twin, s)
    applyDash(twin, c, s)
    M.stats.poses = (M.stats.poses or 0) + 1
    return n
end
-- Door n of the twin eased shut from where its mesh is (the shut pose: the mesh on its door's root), with the doors
-- hold: seconds the owner's pose lines leave that door alone - this side's own shut, whose last open poses were still on
-- their way: the door eased shut, then swung open again to 42 deg and shut a second time (owner's two-games test
-- 2026-11-11: "the back door tries to shut, stays open, then shuts"; backseat-test)
M.doorHold = {}
function M.shutEase(twin, n, hold)
    if hold then M.doorHold[n] = os.clock() + hold end
    local c = poseComps(twin)
    local d = M.door(twin, n)
    if not (c and d) then return false end
    local rel = KML:ComposeTransforms(d.RootComponent:K2_GetComponentToWorld(), KML:InvertTransform(twin:GetTransform()))
    c.doorGoal = c.doorGoal or {}
    c.doorGoal["D" .. n .. ".MainMesh"] = { l = rel.Translation, r = KML:Quat_Rotator(rel.Rotation) }
    if c.last then c.last["D" .. n .. ".MainMesh"] = nil end
    return true
end
-- Door n of the twin on its way shut now (its newest pose nearer the shut one than where it stands): its mesh, else nil
function M.doorClosing(twin, n)
    local c = poseCache[twin:GetAddress()]
    local name = "D" .. n .. ".MainMesh"
    local g = c and c.doorGoal and c.doorGoal[name]
    local comp = g and c[name] and Sync.deref(c[name])
    if not comp then return nil end
    local rel = KML:ComposeTransforms(comp:K2_GetComponentToWorld(), KML:InvertTransform(twin:GetTransform()))
    local r = KML:Quat_Rotator(rel.Rotation)
    -- (the angle of the turn from the car's frame: a rotator's pitch + yaw sum jumped where the same open lid read
    -- (50, 180, 180) or (130, 0, 0) - 208 -> 80, a "closing" hit before the shut, runover-test)
    local function turn(q)
        local h = math.pi / 360
        local cp, sp, cy, sy, cr, sr = math.cos(q.Pitch * h), math.sin(q.Pitch * h), math.cos(q.Yaw * h), math.sin(q.Yaw * h), math.cos(q.Roll * h), math.sin(q.Roll * h)
        return math.deg(2 * math.acos(math.min(1, math.abs(cr * cp * cy + sr * sp * sy))))
    end
    local cur, goal = turn(r), turn(g.r)
    -- (and 15 degrees under its widest open: a lid bouncing back at its stop when opened read "closing" - a hit on
    -- whoever stood under it, runover-test)
    c.openMax = c.openMax or {}
    c.openMax[name] = cur < 5 and cur or math.max(c.openMax[name] or 0, cur)
    if goal < cur - 2 and cur < c.openMax[name] - 15 then return comp, string.format("cur=%.0f_goal=%.0f_max=%.0f", cur, goal, c.openMax[name]) end
    return nil
end
-- Every frame: the twin's doors a share of the way toward their newest pose (car-relative), dt the frame's time
function M.doorEase(twin, dt)
    local c = poseCache[twin:GetAddress()]
    if not (c and c.doorGoal and next(c.doorGoal)) then return end
    local carXf = twin:GetTransform()
    local inv = KML:InvertTransform(carXf)
    local f = 1 - (1 - DOOR_EASE) ^ (math.max(dt, 0.001) / 0.033)
    for name, g in pairs(c.doorGoal) do
        local comp = c[name] and Sync.deref(c[name])
        if not comp then
            c.doorGoal[name] = nil
        elseif not M.doorLocal[tonumber(name:sub(2, 2))] then -- (simulating here: kept for when it is posed again)
            pcall(function()
                local rel = KML:ComposeTransforms(comp:K2_GetComponentToWorld(), inv)
                local l, r = rel.Translation, KML:Quat_Rotator(rel.Rotation)
                local d = math.abs(l.X - g.l.X) + math.abs(l.Y - g.l.Y) + math.abs(l.Z - g.l.Z)
                local nl, nr
                if d < 0.5 and KML:NormalizedDeltaRotator(r, g.r).Yaw ^ 2 + KML:NormalizedDeltaRotator(r, g.r).Pitch ^ 2 < 0.25 then
                    nl, nr = g.l, g.r
                    c.doorGoal[name] = nil
                else
                    nl = { X = l.X + (g.l.X - l.X) * f, Y = l.Y + (g.l.Y - l.Y) * f, Z = l.Z + (g.l.Z - l.Z) * f }
                    nr = KML:RLerp(r, g.r, f, true)
                end
                local w = KML:ComposeTransforms(KML:MakeTransform(nl, nr, { X = 1, Y = 1, Z = 1 }), carXf)
                comp:K2_SetWorldLocationAndRotation(w.Translation, KML:Quat_Rotator(w.Rotation), false, {}, true)
            end)
        end
    end
end

---------------------------------------------------------------------------------------------------
-- getting in / out with the game's own seat logic

-- In: the manager points at the twin while the local player sits in it (camera, dash, HUD, input).
function M.enter(twin, pawn)
    local cm = manager()
    if not cm then return false end
    cm.NewCarActor = twin
    local ok = pcall(function() pawn:CommandEnterCar(true, nil, false) end)
    if not ok then M.managerToOwn() end
    return ok
end

-- In through door n like the game's own driver door does it on a tap (probed: AttemptOpen, StartEntry(true), then
-- CommandEnterCar(false, door, false) 0.2 s later; the character walks from that door to the car's TempSocket_Seat,
-- through any door - the game itself offers it only at the driver door). Step 1: the manager on the twin, the door's
-- entry; step 2 (finishEntry, 0.2 s later) the character's entry.
function M.door(car, n)
    local p = poseComps(car)["D" .. n .. "@actor"]
    return p and Sync.deref(p) or nil
end
-- The twin's doors are real parts: the game highlights them like the own car's, and its own E there (probed) opened
-- the door's physics on the kinematic twin (it came off, and the guest's EX took the owner's real door) and got the
-- player into the car the manager holds - the OWN car (alpha 12's "teleported into my car"). A Lua hook cannot get
-- in first (UE4SS runs a BP function's "pre" hook after its body: traced). So the twin's door actors lose the game's
-- own handlers of their Highlight (OnInteract / OnInteractShort / OnInteractLong -> the door's BndEvt: AttemptOpen,
-- StartEntry): the prompt stays, the game's E does nothing there, and playersync (TD.onHighlightPress) sends the door
-- to its owner (DR) / gets the player in the twin's way. Its interactive part (taking the door off) keeps its own.
local MUTE_DELS = { "OnInteract", "OnInteractShort", "OnInteractLong" }
local CAT_DELS = { "OnInteract", "OnInteractShort", "OnInteractLong", "OnInteractStart", "OnInteractEnd" }
local DOOR_SLOT -- (below: highlightedDoor)
local HCC
function M.muteDoors(twin)
    if CoopSyncNoMute then return 0 end -- (probes of the native car interactions: the game's own handlers kept)
    local key = twin:GetAddress()
    local m = mutedDoors[key] or {}
    mutedDoors[key] = m
    HCC = HCC or SFO("/Script/PenDriverPro.HighlightComponent")
    local n = 0
    for d = 1, 5 do
        local door = M.door(twin, d)
        if door and door:IsValid() and m[d] ~= door:GetAddress() then
            m[d] = door:GetAddress()
            local comps = door:K2_GetComponentsByClass(HCC)
            for i = 1, #comps do
                local hc = comps[i]:get()
                for _, dn in ipairs(MUTE_DELS) do
                    pcall(function()
                        for _, b in ipairs(hc[dn]:GetBindings() or {}) do
                            local o = b.Object
                            if o and o:IsValid() and o:GetAddress() == door:GetAddress() then hc[dn]:Remove(o, b.FunctionName) n = n + 1 end
                        end
                    end)
                end
            end
        end
    end
    -- The slots' interactive spots of the doors and the trunk lid (BP_CarPart_Interactive_C, what the game highlights
    -- at a shut door) run handlers of their own on E (OnInteractStart / OnInteractEnd) that work the car manager's door
    -- states - the LOCAL player's own car (owner, alpha 16: "the friend could not shut my trunk"; probed: the guest's
    -- taps at the host's twin had opened the guest's own driver door, back door and trunk, far away). Muted the same way.
    -- (with the doors: the first time and when a door actor is new - parts spawned again)
    local cat = m.cat or {}
    m.cat = cat
    local att = {}
    if n > 0 or not m.catDone then pcall(function() twin:GetAttachedActors(att, true) end) end
    m.catDone = true
    for i = 1, #att do
        local a = att[i]:get()
        if a and a:IsValid() and not cat[a:GetAddress()] and a:GetClass():GetFName():ToString() == "BP_CarPart_Interactive_C" then
            local out = {}
            local okS = pcall(function() a:GetSlotComponent(out) end)
            local sc = okS and out.SlotSceneComponent
            local slot = sc and sc:IsValid() and sc.SlotName.TagName:ToString() or ""
            cat[a:GetAddress()] = true
            if DOOR_SLOT[slot] or slot == "Car.Equip.Body.PanelHood" then
                local comps = a:K2_GetComponentsByClass(HCC)
                for j = 1, #comps do
                    local hc = comps[j]:get()
                    for _, dn in ipairs(CAT_DELS) do
                        pcall(function()
                            for _, b in ipairs(hc[dn]:GetBindings() or {}) do
                                local o = b.Object
                                if o and o:IsValid() and o:GetAddress() == a:GetAddress() then hc[dn]:Remove(o, b.FunctionName) n = n + 1 end
                            end
                        end)
                    end
                end
            end
        end
    end
    -- The car manager's OnDoorChanged (the LOCAL player's own car's door states) also drove the twin: its car, doors,
    -- panels and slot spots are bound to it (probed) - the player opening its own driver door opened the twin's (stuck
    -- half open, its pose came later) and hid the twin's driver door spot, so the other's driver door could not be
    -- taken while the own one was open (cars-test). The twin's bindings there go (its doors follow the owner's pose).
    if n > 0 or not m.mgrDone then
        m.mgrDone = true
        local cm = manager()
        -- (only actors and their components are walked: calling an actor's function on a widget raises an error
        -- through Lua - those break the Lua state)
        local ACT, COMP = SFO("/Script/Engine.Actor"), SFO("/Script/Engine.ActorComponent")
        pcall(function()
            for _, b in ipairs(cm.OnDoorChanged:GetBindings() or {}) do
                local o = b.Object
                local root
                if o and o:IsValid() then
                    if o:IsA(ACT) then root = o elseif o:IsA(COMP) then root = o:GetOwner() end
                end
                local g = 0
                while root and root:IsValid() and g < 10 do
                    local p = root:GetAttachParentActor()
                    if not (p and p:IsValid()) then break end
                    root, g = p, g + 1
                end
                if root and root:IsValid() and root:GetAddress() == key then
                    cm.OnDoorChanged:Remove(o, b.FunctionName)
                    n = n + 1
                end
            end
        end)
    end
    M.stats.doorsMuted = (M.stats.doorsMuted or 0) + n
    return n
end
-- The driver's door while the other player sits at that wheel (owner's alpha 20 test: "with somebody at the wheel the
-- door cannot be put on or taken off"): the door and its slot spot used to be hidden (K2_ShouldHighlight false: the
-- game's E would get the player onto the taken seat - its own entry cannot be stopped from a hook), and with them the
-- taking off / putting on. Now only their E handlers (open, get in) are parked while the seat is taken and put back
-- once it is free; the highlight and the part's own interactive spot (taking the door off) stay.
M.PARK_SLOT_SPOT = false
local parkedEntry = {} -- actor address -> { actor, list of { hc, del, obj, fn } }
local function entryActors(car, n)
    local r = {}
    local d = M.door(car, n)
    if d and d:IsValid() then r[#r + 1] = { a = d, dels = MUTE_DELS } end
    -- (the door only: parking the handlers of its slot spot - BP_CarPart_Interactive_C - too broke cars: the driver's
    -- doors of both cars came off after a ride in the other's car, cars-test 11 failed, the owner's alpha 20 item 9)
    if not M.PARK_SLOT_SPOT then return r end
    local att = {}
    pcall(function() car:GetAttachedActors(att, true) end)
    for i = 1, #att do
        local a = att[i]:get()
        if a and a:IsValid() and a:GetClass():GetFName():ToString() == "BP_CarPart_Interactive_C" then
            local out = {}
            local okS = pcall(function() a:GetSlotComponent(out) end)
            local sc = okS and out.SlotSceneComponent
            local slot = sc and sc:IsValid() and sc.SlotName.TagName:ToString() or ""
            if DOOR_SLOT[slot] == n then r[#r + 1] = { a = a, dels = CAT_DELS } end
        end
    end
    return r
end
function M.parkEntry(car, n, park)
    if not (car and car:IsValid()) then return 0 end
    HCC = HCC or SFO("/Script/PenDriverPro.HighlightComponent")
    local done = 0
    if park then
        for _, e in ipairs(entryActors(car, n)) do
            local key = e.a:GetAddress()
            if not parkedEntry[key] then
                local list = {}
                local comps = e.a:K2_GetComponentsByClass(HCC)
                for i = 1, #comps do
                    local hc = comps[i]:get()
                    for _, dn in ipairs(e.dels) do
                        pcall(function()
                            for _, b in ipairs(hc[dn]:GetBindings() or {}) do
                                local o = b.Object
                                if o and o:IsValid() and o:GetAddress() == key then
                                    local fn = b.FunctionName
                                    hc[dn]:Remove(o, fn)
                                    list[#list + 1] = { hc = hc, del = dn, obj = o, fn = fn:ToString() }
                                end
                            end
                        end)
                    end
                end
                parkedEntry[key] = { actor = e.a, list = list, car = car:GetAddress() }
                done = done + #list
            end
        end
    else
        for key, p in pairs(parkedEntry) do
            if p.car == car:GetAddress() then
                for _, b in ipairs(p.list) do
                    pcall(function() if b.hc:IsValid() and b.obj:IsValid() then b.hc[b.del]:Add(b.obj, b.fn) end end)
                    done = done + 1
                end
                parkedEntry[key] = nil
            end
        end
    end
    M.stats.entryParked = (M.stats.entryParked or 0) + (park and done or 0)
    return done
end
M.entryParked = function() local n = 0 for _ in pairs(parkedEntry) do n = n + 1 end return n end
-- The twin's door the game highlights now (twin, door number), else nil
DOOR_SLOT = { ["Car.Equip.Body.DoorsFL"] = 1, ["Car.Equip.Body.DoorsFR"] = 2, ["Car.Equip.Body.DoorsRL"] = 3,
    ["Car.Equip.Body.DoorsRR"] = 4, ["Car.Equip.Body.DoorsTrunk"] = 5 }
function M.highlightedDoor()
    local hm = CoopSyncFirst("BP_HighlightManager_C")
    local h = hm and hm.CurrentHighlight
    if not (h and h:IsValid()) then return nil end
    local a = h:GetOwner()
    if not (a and a:IsValid()) then return nil end
    local car, g = a, 0
    while g < 10 do
        local p = car:GetAttachParentActor()
        if not (p and p:IsValid()) then break end
        car, g = p, g + 1
    end
    if not M.isTwin(car) then return nil end
    -- the door actor itself (an open door, the open trunk lid: owner, alpha 16 - "the friend could not shut my trunk":
    -- door actors have no GetSlotComponent, the lookup below failed for them)
    for k = 1, 5 do
        local d = M.door(car, k)
        if d and d:GetAddress() == a:GetAddress() then return car, k end
    end
    -- the slot's interactive spot (a shut door); only that class has GetSlotComponent (a call on another one is an
    -- error raised through Lua: those break the Lua state, memory ue4ss-errors-not-free)
    if a:GetClass():GetFName():ToString() ~= "BP_CarPart_Interactive_C" then return nil end
    local out = {}
    if not pcall(function() a:GetSlotComponent(out) end) then return nil end
    local sc = out.SlotSceneComponent
    local n = sc and sc:IsValid() and DOOR_SLOT[sc.SlotName.TagName:ToString()]
    if not n then return nil end
    return car, n
end
-- The twin's car body highlights (the dash levers, the top light, the key, the "enter" spot at the driver's side) run
-- the car's own handlers, and those act on the car manager - its car and its one state of lights / ignition: from
-- outside (probe cmds/twin-body-press.lua) the twin's left lever toggled the OWN car's headlights and EnterDoor got
-- the player into the OWN car. So they lose those handlers: the key and EnterDoor always (the key in a twin is
-- playersync's twinInteract, EnterDoor its driver's door), the levers and the top light while the local player is
-- not in this twin (inside, the manager is on the twin holding its owner's state - playersync twinControls - and the
-- game's own lever works on it). ExitDoor keeps its own (used from inside only).
local BODY_HL = { Key = "always", EnterDoor = "always", TopLight = "outside", LeftHandle = "outside", RightHandle = "outside" }
local BODY_DELS = { "OnInteract", "OnInteractShort", "OnInteractLong", "OnInteractStart", "OnInteractEnd", "OnInteractStartLong" }
-- A part of a car (an actor of class cls attached to it), nil without one. Its path is kept per class and car path for
-- 2 s (FindAllOf walks every object of the class).
local partCache = {} -- cls .. "|" .. car full name -> { at = os.clock(), ref = Sync.ref(part) | false }
local function partOf(car, cls)
    local k = cls .. "|" .. car:GetFullName()
    local c = partCache[k]
    if c and os.clock() - c.at < 2 then
        local r = c.ref and Sync.deref(c.ref)
        if r then
            local p = r:GetAttachParentActor()
            if p and p:IsValid() and p:GetAddress() == car:GetAddress() then return r end
        elseif c.ref == false then return nil end
    end
    local found = false
    for _, r in ipairs(FindAllOf(cls) or {}) do
        local p = r:IsValid() and r:GetAttachParentActor()
        if p and p:IsValid() and p:GetAddress() == car:GetAddress() then found = r break end
    end
    partCache[k] = { at = os.clock(), ref = found and Sync.ref(found) or false }
    return found or nil
end
function M.radioOf(car) return partOf(car, "BP_CarPart_Internal_Radio_C") end
-- The gear lever. The car's GetGearboxActor finds the newest shifter of the world, not its own (probed: with a twin
-- both cars' answered the twin's): the own car's lever animation (SetGearboxRotationFromAnimPosition) moved the
-- twin's lever, its own stood still - and so did the other side's twin of it, which follows the owner's lever pose.
-- playersync hooks GetGearboxActor (UE4SS runs the hook after the body) and sets its result to M.shifterOf(self).
function M.shifterOf(car) return partOf(car, "BP_Carpart_Shifter_Base_C") end
-- The twin's radio button (its part's Highlight1) likewise acts on the manager: from outside it switched the OWN
-- radio. Off while the local player is not in this twin (bodyOf entry "Radio", with the part it was taken from).
local function muteRadio(twin, b, inside)
    local r = M.radioOf(twin)
    local cur = b.Radio
    if cur and not (r and cur.part == r:GetFullName()) then b.Radio, cur = nil, nil end -- (part gone / swapped)
    if not r then return 0 end
    local hc = r.Highlight1
    if not (hc and hc:IsValid()) then return 0 end
    if not inside and not cur then
        local removed = {}
        pcall(function()
            for _, e in ipairs(hc.OnInteract:GetBindings() or {}) do
                local o = e.Object
                if o and o:IsValid() and o:GetAddress() == r:GetAddress() then
                    local fn = e.FunctionName:ToString()
                    hc.OnInteract:Remove(o, fn)
                    removed[#removed + 1] = fn
                end
            end
        end)
        b.Radio = { part = r:GetFullName(), fns = removed }
        M.stats.bodyMuted = (M.stats.bodyMuted or 0) + #removed
        return #removed
    elseif inside and cur then
        local n = 0
        for _, fn in ipairs(cur.fns) do
            if pcall(function() hc.OnInteract:Add(r, fn) end) then n = n + 1 end
        end
        M.stats.bodyRestored = (M.stats.bodyRestored or 0) + n
        b.Radio = nil
        return n
    end
    return 0
end
-- The highlighted part of a twin's radio: true when the game highlights the radio button of a twin.
function M.highlightedRadio()
    local hm = CoopSyncFirst("BP_HighlightManager_C")
    local h = hm and hm.CurrentHighlight
    if not (h and h:IsValid()) then return false end
    local part = h:GetOwner()
    if not (part and part:IsValid() and part:GetClass():GetFName():ToString() == "BP_CarPart_Internal_Radio_C") then return false end
    local car = part:GetAttachParentActor()
    return car ~= nil and car:IsValid() and M.isTwin(car)
end
-- Radio music. The radio is one playlist on the music manager (BaseMusicManager.RadioPlaylist: 61 built-in tracks
-- + the player's own files from Custom/Radio), no stations: the channel buttons (BP_RadioComponent ChangeChannel)
-- skip in it (SkipTrack). Probed (cmds/music-probe.lua; music plays only with sound, COOPTEST_SOUND=1): the playlist
-- is a queue (the track picked is removed - every entry of it - and added at the end), SkipTrack picks the next
-- track ~50 ms later. A given track: every playlist entry set to it, SkipTrack(1) (the playlist is that one track
-- then), the playlist written back as soon as it plays (Empty + entries; a TArray grows when written past its end),
-- the track at its end like the game's own pick.
-- Position: Wwise has a seek (CoopNative_AkSeek: the exe's AK::SoundEngine::SeekOnEvent, event short id + the track
-- player's AkComponent address as the game object) but no position for these tracks (GetSourcePlayPosition answers
-- 94: posted without its flag), so each side keeps a clock: a new playing id of the track's event = the track began
-- (clock 0), a seek here moves the clock. Radio off does not stop the track (same playing id, only silent). The
-- player's own files play in the media player: its own time and Seek. (cmds/ak-probe.lua)
local function music() return CoopSyncFirst("BP_MusicManager_C") end
-- a track's id for the other side: the asset path of a built-in one, "x:<file name>" of a player's own file
function M.trackId(t)
    if not (t and t:IsValid()) then return nil end
    local url = ""
    pcall(function() url = t.ExternalUrl:ToString() end)
    if url ~= "" then return "x:" .. (url:match("([^/\\]+)$") or url):gsub("%s", " ") end
    return (t:GetFullName():gsub("^%S+%s+", ""))
end
-- the track the local radio plays now (nil: radio off, between tracks, a DJ break)
function M.currentTrack()
    local mm = music()
    if not (mm and mm:IsValid()) then return nil end
    local ok, t = pcall(function() return mm:CurrentRadioTrack() end)
    return ok and M.trackId(t) or nil
end
M.musicBusy = false
-- The player's own files (Custom/Radio next to the game's Saved folder) are not in the playlist: the game's library
-- picks them (settings RadioSource 1 = built-in + own, 2 = own only) and makes their MusicTrack then (ExternalUrl
-- file://...). The other player's file this side has too (the same name): that track object, or one made here.
local customMade = {} -- id -> path of a MusicTrack made here
local function customDir()
    local ksl = SFO("/Script/Engine.Default__KismetSystemLibrary")
    local saved = ksl:GetProjectSavedDirectory():ToString()
    pcall(function() saved = ksl:ConvertToAbsolutePath(saved):ToString() end)
    saved = saved:gsub("\\", "/"):gsub("/+$", "")
    return saved:gsub("[^/]+$", "") .. "Custom/Radio/"
end
function M.customTrack(id)
    local name = id:match("^x:(.+)$")
    if not name then return nil end
    for _, t in ipairs(FindAllOf("MusicTrack") or {}) do
        if t:IsValid() and M.trackId(t) == id then return t end
    end
    local made = customMade[id] and SFO(customMade[id])
    if made and made:IsValid() then return made end
    local file = customDir() .. name
    local f = io.open(file, "rb")
    if not f then return nil end
    f:close()
    local t = StaticConstructObject(SFO("/Script/PenDriverPro.MusicTrack"), music())
    if not (t and t:IsValid()) then return nil end
    t.ExternalUrl = "file://" .. file
    customMade[id] = t:GetFullName():gsub("^%S+%s+", "")
    M.stats.customMade = (M.stats.customMade or 0) + 1
    return t
end
-- The playlist as the one track with this id (the game's next pick, natural or a skip, is that track); the paths to
-- write back once it plays (M.restoreQueue), the track last. nil: this side has no such track.
local queued -- { id, keep = paths, at = os.clock() } while the playlist is the one track
function M.queueTrack(id)
    local mm = music()
    if not (mm and mm:IsValid()) then return nil end
    if queued then M.restoreQueue() end
    local pl = mm.RadioPlaylist
    local n = #pl
    local keep, target = {}, nil
    for i = 1, n do
        local t = pl[i]
        if not target and M.trackId(t) == id then target = t
        else keep[#keep + 1] = (t:GetFullName():gsub("^%S+%s+", "")) end
    end
    -- (a player's own file: not in the playlist, which stays as it was)
    if not target then target = M.customTrack(id) else keep[#keep + 1] = target:GetFullName():gsub("^%S+%s+", "") end
    if not target then return nil end
    for i = 1, n do pl[i] = target end
    queued = { id = id, keep = keep, at = os.clock() }
    return queued
end
function M.restoreQueue()
    if not queued then return end
    local keep = queued.keep
    queued = nil
    local mm = music()
    if not (mm and mm:IsValid()) then return end
    local q = mm.RadioPlaylist
    q:Empty()
    for _, p in ipairs(keep) do
        local t = StaticFindObject(p)
        if t and t:IsValid() then q[#q + 1] = t end
    end
end
function M.queuedTrack() return queued and queued.id or nil, queued and queued.at or nil end
-- the queued track began (or never did: 20 s) -> the playlist back
function M.queueTick()
    if queued and (M.currentTrack() == queued.id or os.clock() - queued.at > 20) then M.restoreQueue() end
end
-- a track of the local playlist other than cur, at random (the game's own pick is random too)
function M.pickNext(cur)
    local mm = music()
    if not (mm and mm:IsValid()) then return nil end
    local ids = {}
    local pl = mm.RadioPlaylist
    for i = 1, #pl do
        local id = M.trackId(pl[i])
        if id and id ~= cur then ids[#ids + 1] = id end
    end
    return #ids > 0 and ids[math.random(#ids)] or nil
end
-- Play the track with this id on the local radio; at() (optional) -> the ms to seek to once it plays. false: this side
-- has no such track (a file only the other player has) or a switch is still under way.
function M.playTrack(id, at)
    local mm = music()
    if M.musicBusy or not (mm and mm:IsValid()) then return false end
    if not M.queueTrack(id) then return false end
    pcall(function() mm:SkipTrack(1) end)
    M.musicBusy = true
    local t0 = os.clock()
    local function poll()
        local playing = M.currentTrack() == id
        if playing or os.clock() - t0 > 2 then
            M.restoreQueue()
            M.musicBusy = false
            if playing and at then pcall(M.seekTrack, at()) end
            return
        end
        CoopSyncAfter(20, poll)
    end
    CoopSyncAfter(20, poll)
    M.stats.tracksPlayed = (M.stats.tracksPlayed or 0) + 1
    return true
end
-- the playing track in Wwise: its event's short id (unsigned), the game object, the playing id of that event there
local function akTrack()
    local mm = music()
    if not (mm and mm:IsValid() and CoopNative_AkPlaying) then return nil end
    local p = mm.MusicTrackPlayer
    local ev, src = p.AudioEvent, p.PlaybackSource
    if not (ev and ev:IsValid() and src and src:IsValid()) then return nil end
    local evId = ev:GetWwiseShortID()
    if evId < 0 then evId = evId + 4294967296 end
    local go = src:GetAddress()
    local pid
    for p2, e2 in CoopNative_AkPlaying(go):gmatch("(%d+) (%d+)\n") do
        if tonumber(e2) == evId then pid = tonumber(p2) end
    end
    return evId, go, pid, ev.MaximumDuration * 1000
end
local function media(mm)
    if not mm then return nil end
    local mp
    pcall(function() mp = mm.MusicTrackPlayer.ExternalMediaPlayer end)
    if not (mp and mp:IsValid()) then mp = mm.ExternalMediaPlayer end
    return mp and mp:IsValid() and mp or nil
end
-- (a global: this module is loaded again at every sync start, and a clock made then took the playing track as
-- beginning then - owner, alpha 16: the same track at different places after a join in the garage)
CoopSyncRadioClock = CoopSyncRadioClock or { id = nil, pid = nil, start = 0, len = 0 }
M.clock = CoopSyncRadioClock
-- The local track, how far it is (ms) and how long (ms; 0 unknown). nil: no track.
function M.trackPos()
    local id = M.currentTrack()
    if not id then return nil end
    local now = os.clock() * 1000
    local c = M.clock
    if id:sub(1, 2) == "x:" then
        local mp = media(music())
        if not mp then return nil end
        -- (the media player's FTimespan reaches Lua as an empty table: read in C++)
        local pos, len = CoopNative_MediaTime and CoopNative_MediaTime(mp:GetAddress())
        if not pos then return nil end
        if id ~= c.id then c.changedAt = now end
        c.id, c.pid, c.start, c.len, c.calibrated = id, nil, now - pos, len or 0, true
        return id, pos, len or 0
    end
    local _, _, pid, len = akTrack()
    if id ~= c.id or (pid and pid ~= c.pid) then
        if id ~= c.id then c.changedAt = now end
        c.id, c.pid, c.start, c.len, c.calibrated = id, pid, now, len or 0, false
    end
    return id, now - c.start, c.len
end
-- Seek the local track to ms (true: done).
function M.seekTrack(ms)
    if not ms then return false end
    local id = M.trackPos()
    if not id then return false end
    ms = math.max(0, math.floor(ms))
    if id:sub(1, 2) == "x:" then
        local mp = media(music())
        local done = mp and CoopNative_MediaSeek and CoopNative_MediaSeek(mp:GetAddress(), ms) or false
        if done then M.stats.trackSeeks = (M.stats.trackSeeks or 0) + 1 end
        return done
    end
    local evId, go, pid, len = akTrack()
    if not (evId and pid) or (len and len > 0 and ms > len - 1000) then return false end
    local r = CoopNative_AkSeek(evId, go, ms, pid)
    if r ~= 1 then return false end
    M.clock.start = os.clock() * 1000 - ms
    M.clock.calibrated = true
    M.stats.trackSeeks = (M.stats.trackSeeks or 0) + 1
    return true
end
-- Every 0.1 s from the session (session.lua) as long as the game runs: a track that begins is seen when it begins.
-- calibrate (in a co-op session): 2.5 s into a new built-in track it is sought to where its clock says. The clock
-- starts when the track's event is posted, the music may start later (the channel change's static: the two radios
-- were 1-2 s apart after a skip, owner alpha 16); after a seek the clock and the music agree.
local CALIB_MS = 2500
function M.clockTick(calibrate)
    local id, pos = M.trackPos()
    local c = M.clock
    if not (calibrate and id and not c.calibrated) then return end
    if pos >= CALIB_MS then
        c.calibrated = true -- (once: a failed seek is not tried again)
        if pos < CALIB_MS + 5000 and M.seekTrack(pos) then M.stats.calibrated = (M.stats.calibrated or 0) + 1 end
    end
end
-- The radio DJ's breaks: the music manager (RequestInterstitial: after a number of tracks, a chance mid-song, the
-- channel button; allowed only past the first story mission and off the critical path) has the dialogue manager play a
-- DialogueSequence of the event "Ambient" (DJ Garlic, Flash Wednesday, ...; ~20 s over the music). Probed
-- (cmds/dj-probe.lua): IsAnyoneTalking + GetCurrentlyPlayingSequence show it while it plays; PlaySequence plays a given
-- one. Each side picks its own at random, so the owner's goes to the follower, whose own are held off (both counters
-- kept high) and any that starts anyway is stopped.
local function dialogue() return CoopSyncFirst("BP_DialogueManager_C") end
local dj = { seq = nil, want = nil, wantAt = -1e9, held = nil }
-- a DJ break that began here since the last call: its sequence's path (nil: none)
function M.djStarted()
    local dm = dialogue()
    if not (dm and dm:IsValid()) then return nil end
    local path
    pcall(function()
        if not dm:IsAnyoneTalking() then return end
        local s = dm:GetCurrentlyPlayingSequence()
        if s and s:IsValid() and s.DialogueEvent.Name:ToString() == "Ambient" then path = s:GetFullName():gsub("^%S+%s+", "") end
    end)
    local new = path and path ~= dj.seq
    if dj.seq and not path then dj.ended = true end
    dj.seq = path
    return new and path or nil
end
-- the break seen by djStarted ended since the last call (by itself or skipped with the channel button)
function M.djEnded()
    local e = dj.ended
    dj.ended = false
    return e == true
end
-- the owner's break ended there (owner, alpha 16: the host skipped the DJ, the guest's went on): stop it here too
function M.djStop()
    local want = dj.want
    dj.want = nil
    if not want then return false end
    local stopped = false
    pcall(function()
        local dm = dialogue()
        if not dm:IsAnyoneTalking() then return end
        local s = dm:GetCurrentlyPlayingSequence()
        if s and s:IsValid() and s:GetFullName():gsub("^%S+%s+", "") == want then dm:StopCurrentSequence() stopped = true end
    end)
    if stopped then M.stats.djStoppedByOwner = (M.stats.djStoppedByOwner or 0) + 1 end
    return stopped
end
-- following the other's radio: this side's own breaks held off, one that starts anyway (not the owner's) stopped
function M.djFollow()
    local mm = music()
    if mm and mm:IsValid() then
        if not dj.held then dj.held = { mm.NextNaturalInterstitialCounter, mm.NextManualInterstitialCounter } end
        mm.NextNaturalInterstitialCounter = 99
        mm.NextManualInterstitialCounter = 99
    end
    local s = M.djStarted()
    if s and (s ~= dj.want or os.clock() - dj.wantAt > 5) then
        pcall(function() dialogue():StopCurrentSequence() end)
        M.stats.djStopped = (M.stats.djStopped or 0) + 1
    end
end
-- not following any more: the own breaks' counters back
function M.djRelease()
    if not dj.held then return end
    local mm = music()
    if mm and mm:IsValid() then
        mm.NextNaturalInterstitialCounter = dj.held[1]
        mm.NextManualInterstitialCounter = dj.held[2]
    end
    dj.held = nil
end
-- the owner's break (its sequence's path) played here
function M.djPlay(path)
    local dm = dialogue()
    if not (dm and dm:IsValid()) then return false end
    local s = SFO(path)
    if not (s and s:IsValid()) then pcall(function() LoadAsset((path:gsub("%.[^.]+$", ""))) end) s = SFO(path) end
    if not (s and s:IsValid()) then return false end
    dj.want, dj.wantAt = path, os.clock()
    return (pcall(function() dm:PlaySequence(s, 4, nil) end))
end
-- The other's twin's channel button pressed: its radio part's BP_RadioComponent ChangeChannel(dir) (on the own car's
-- radio: the game's channel change with its static).
function M.changeChannel(car, dir)
    local r = M.radioOf(car)
    if not r then return false end
    return pcall(function() r.BP_RadioComponent:ChangeChannel(dir) end)
end
function M.muteBody(twin, inside)
    if CoopSyncNoMute then return 0 end
    local key = twin:GetAddress()
    local b = bodyOf[key] or {} -- highlight name -> the bindings taken off it ({ delegate, function name }): muted
    bodyOf[key] = b
    local n = muteRadio(twin, b, inside)
    for name, when in pairs(BODY_HL) do
        local mute = when == "always" or not inside
        if mute and not b[name] then
            local hc = twin["Highlight_" .. name]
            if hc and hc:IsValid() then
                local removed = {}
                for _, dn in ipairs(BODY_DELS) do
                    pcall(function()
                        for _, e in ipairs(hc[dn]:GetBindings() or {}) do
                            local o = e.Object
                            if o and o:IsValid() and o:GetAddress() == key then
                                local fn = e.FunctionName:ToString()
                                hc[dn]:Remove(o, fn)
                                removed[#removed + 1] = { dn, fn }
                            end
                        end
                    end)
                end
                b[name] = removed
                M.stats.bodyMuted = (M.stats.bodyMuted or 0) + #removed
                n = n + #removed
            end
        elseif not mute and b[name] then
            local hc = twin["Highlight_" .. name]
            for _, r in ipairs(b[name]) do
                if hc and hc:IsValid() and pcall(function() hc[r[1]]:Add(twin, r[2]) end) then
                    M.stats.bodyRestored = (M.stats.bodyRestored or 0) + 1
                    n = n + 1
                end
            end
            b[name] = nil
        end
    end
    return n
end
-- The twin's body highlight the game highlights now (twin, its name without "Highlight_"), else nil
function M.highlightedBody()
    local hm = CoopSyncFirst("BP_HighlightManager_C")
    local h = hm and hm.CurrentHighlight
    if not (h and h:IsValid()) then return nil end
    local car = h:GetOwner()
    if not M.isTwin(car) then return nil end
    local name = h:GetFName():ToString():match("^Highlight_(.+)$")
    if not name then return nil end
    return car, name
end
function M.startEntry(twin, door)
    local cm = manager()
    if not cm then return false end
    cm.NewCarActor = twin
    if not door then return true end -- (an empty doorway: the walk in starts at finishEntry)
    local ok = pcall(function() door:StartEntry(true) end)
    if not ok then M.managerToOwn() end
    return ok
end
function M.finishEntry(pawn, door)
    -- (a doorway: its slot's EmptyDoor is the door here - playersync. CommandEnterCar with no door at all made the game
    -- take the car's driver's door off, the OWN car's: never called so - backseat-test 2026-11-11)
    if not door then return false end
    return pcall(function() pawn:CommandEnterCar(false, door, false) end)
end
-- The owner's real door n: "open" | "shut" | "toggle" (open = its mesh simulates). Returns what was done.
function M.doorOpen(car, n)
    local d = M.door(car, n)
    local ok, r = pcall(function() return d.MainMesh:IsSimulatingPhysics(FName("None")) end)
    return ok and r == true
end
function M.setDoor(car, n, op)
    local d = M.door(car, n)
    if not d then return "no door " .. tostring(n) end
    if op == "toggle" then op = M.doorOpen(car, n) and "shut" or "open" end
    local ok = pcall(function() if op == "open" then d:AttemptOpen() else d:AttemptShut() end end)
    return ok and op or ("failed " .. op)
end

-- Out: the game's exit; the manager goes back to the own car once the character is free (playersync), or at once
-- with now = true (the twin is about to go).
function M.leave(pawn, now)
    pcall(function() pawn["Exit Car"](pawn, false, true) end)
    if now then
        pcall(function() pawn:K2_DetachFromActor(1, 1, 1) end)
        M.managerToOwn()
    end
end

function M.info()
    local n = 0
    for _ in pairs(CoopSyncTwins) do n = n + 1 end
    local cm = manager()
    local onTwin = cm and M.isTwin(cm.NewCarActor)
    return (string.format("twins=%d spawned=%d removed=%d manager_on_twin=%s doors_muted=%d break_muted=%d rejoined=%d body_muted=%d body_restored=%d lights_set=%d broken_links=%d poses=%d mirror=%s errors=%s", n, M.stats.spawned,
        M.stats.removed, tostring(onTwin == true), M.stats.doorsMuted or 0, M.stats.doorBreakMuted or 0, M.stats.doorsRejoined or 0, M.stats.bodyMuted or 0, M.stats.bodyRestored or 0, M.stats.lightsSet or 0, M.brokenLinks(), M.stats.poses or 0, tostring(M.stats.mirror):gsub(" ", "_"), table.concat(M.stats.errors, ";")))
end

-- the heavy twin work in the hitch log (owner's stalls: a twin's light took seconds in a big zone)
for _, name in ipairs({ "fixMirror", "light", "mirrorDoors", "mirrorHidden" }) do
    local impl = M["_" .. name]
    M[name] = function(...)
        if CoopSyncHitch then CoopSyncHitch.crumb("twin " .. name) end
        local t0 = os.clock()
        local r = table.pack(impl(...))
        if CoopSyncHitch then CoopSyncHitch.op("twin " .. name, (os.clock() - t0) * 1000) end
        return table.unpack(r, 1, r.n)
    end
end

return M
