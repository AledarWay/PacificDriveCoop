-- Native cars (owner, after the alpha 17 test, 2026-10-30: "the cars as natively as possible - the game's own
-- interactions, the cars only shared"). The game has one car: one car manager (BP_CarManager_C.NewCarActor, its
-- state: ignition, gear, lights, door flags ...), one car input controller (BP_Controller_PlayerCar_C.
-- PlayerCarReference: every in-car key - pedals, wheel, look, horn, levers - goes there) and the manager's delegates,
-- which every car binds itself to at its BeginPlay. With two cars in the world both were bound: the player's door
-- opened the other car's, the pedals in the other's car drove the own one (NOTES "Native cars: probes").
-- Here the game's "one car" is the CONTEXT car: the car the local player sits in, or works on from outside (aims at),
-- else its own. M.use(car) points the manager and the input controller at it and keeps only its bindings on the
-- manager's delegates (the other car's are parked: removed, kept, added back when it is the context again); the
-- manager's door flags are per car. Then the game's own E at a door of the other's car gets the player in (its door
-- animation, the walk to the seat), its key / levers / horn / pedals work on it, its exit gets out.
local M = {}
local Sync

M.DELS = { "SetControllerInput", "UnflipCar", "OnPlayerFinishEnterCar", "OnPlayerFinishExitCar", "WiperBladeTrigger",
    "OnTrunkUsed", "RecenterView", "OnPlayerStartEnterCar", "OnPlayerStartExitCar", "OnCarLightsChanged", "OnPartBroken",
    "OnInteriorLightsChanged", "OnDoorChanged", "MechanicModeChanged", "OnSwapPartStart", "OnSwapPartEnd",
    "OnCarIgnitionChanged", "OnCarGearboxChanged", "OnAnchorGobbled", "OnPartUnderwaterChanged", "OnPlayerCarStateChange",
    "OnCarRadioStateChanged", "OnDistanceTraveled", "OnCarResetState", "OnHeadlightsUsed", "OnWipersUsed",
    "RetriggerAutoControlDelay", "OnEnableCarStabalize", "OnDisableCarStabalize", "OnWipersToggle", "OnHornStarted",
    "OnHornStopped", "OnCarOutOfBoundsChanged", "OnPreTeleport", "OnPostTeleport", "OnAnchorDeposited",
    "OnDebugAddedAllHardpointUpgrades", "OnCarUpgradeAdded", "OnDoorBreakableChanged", "PrintCarStabilizer",
    "CarFlippedOver", "OnBecameBelowProtectionThreshold", "OnGobblerScreenSignalChanged", "FuelCanReturn",
    "OnAttemptHoodShut", "OnAggregatedInventoriesUpdated", "OnPartFlatChanged", "CarComputerWidgetsChanged" }

M.stats = { switches = 0, parked = 0, unparked = 0, lost = 0, sweeps = 0, ms = 0, lastMs = 0 }
M.ctx = nil -- the context car's path
local parked = {} -- car path -> { { d = delegate, p = bound object's path, f = function name }, ... }
local ACT, COMP
local CAR_CLASS = "BP_PlayerCarNew_C"

function M.init(syncModule)
    Sync = syncModule
    ACT = ACT or StaticFindObject("/Script/Engine.Actor")
    COMP = COMP or StaticFindObject("/Script/Engine.ActorComponent")
end

local function first(cls) return (CoopSyncFirst or FindFirstOf)(cls) end
function M.manager() return first("BP_CarManager_C") end
function M.controller() return first("BP_Controller_PlayerCar_C") end

-- the car an object belongs to (an actor or a component of a car, or of a part hanging under it), else nil
-- (only actors and components are asked: an actor's function on a widget raises an error through Lua)
function M.carOf(o)
    local root
    if not (o and o:IsValid()) then return nil end
    if o:IsA(ACT) then root = o elseif o:IsA(COMP) then root = o:GetOwner() end
    local g = 0
    while root and root:IsValid() and g < 10 do
        local p = root:GetAttachParentActor()
        if not (p and p:IsValid()) then break end
        root, g = p, g + 1
    end
    if root and root:IsValid() and root:GetClass():GetFName():ToString() == CAR_CLASS then return root end
    return nil
end

-- Park the bindings of every car but `keep` (its path): removed from the manager's delegates, kept by path.
-- Also what a car bound afresh (a part spawned again binds itself at its BeginPlay): sweep() calls it.
function M.park(keep)
    local m = M.manager()
    if not (m and m:IsValid()) then return 0 end
    local n = 0
    for _, dn in ipairs(M.DELS) do
        pcall(function()
            local del = m[dn]
            for _, b in ipairs(del:GetBindings() or {}) do
                local o = b.Object
                local car = o and M.carOf(o)
                if car then
                    local cp = Sync.ref(car)
                    if cp ~= keep or (M.stayParked and M.stayParked(dn, o, b.FunctionName:ToString())) then
                        local fn = b.FunctionName:ToString()
                        del:Remove(o, fn)
                        local l = parked[cp] or {}
                        parked[cp] = l
                        l[#l + 1] = { d = dn, p = Sync.ref(o), f = fn }
                        n = n + 1
                    end
                end
            end
        end)
    end
    M.stats.parked = M.stats.parked + n
    return n
end

-- Put a car's parked bindings back (it is the context car now). M.stayParked(d, object, function) (playersync): a
-- binding that stays off even then (the other's car's doors: posed by their owner, never worked by this game).
function M.unpark(cp)
    local l = parked[cp]
    parked[cp] = nil
    if not l then return 0 end
    local m = M.manager()
    local n = 0
    local keep = {}
    for _, e in ipairs(l) do
        local o = Sync.deref(e.p)
        if o and M.stayParked and M.stayParked(e.d, o, e.f) then keep[#keep + 1] = e
        elseif o and pcall(function() m[e.d]:Add(o, e.f) end) then n = n + 1
        else
            M.stats.lost = M.stats.lost + 1
            M.lostList = M.lostList or {}
            if #M.lostList < 20 then M.lostList[#M.lostList + 1] = e.d .. ":" .. e.f .. "@" .. tostring(e.p):sub(-60) end
        end
    end
    if #keep > 0 then parked[cp] = keep end
    M.stats.unparked = M.stats.unparked + n
    return n
end

-- The manager's door flags (DoorStates: door enum -> open) are the context car's. Kept per car while another is.
M.doors = {} -- car path -> { [enum] = bool }
local function readDoors(m)
    local s = {}
    pcall(function() m.DoorStates:ForEach(function(k, v) s[k:get()] = v:get() end) end)
    return s
end
local function writeDoors(m, s)
    if not s then return end
    local cur = readDoors(m)
    for k, v in pairs(s) do
        if cur[k] ~= nil and cur[k] ~= v then pcall(function() m:SetDoorState(k, v) end) end
    end
end

-- Point the game's "one car" at car (an actor). Hooks for the rest of the car's state (ignition, gear, lights:
-- playersync): M.onLeave(m, oldCar), M.onEnter(m, newCar) - called while neither car is bound (no broadcast reaches a
-- car then). Returns true when it switched.
function M.use(car)
    if not (car and car:IsValid()) then return false end
    local m, ctl = M.manager(), M.controller()
    if not (m and m:IsValid()) then return false end
    local cp = Sync.ref(car)
    local cur = m.NewCarActor
    local curOk = cur and cur:IsValid()
    if M.ctx == cp and curOk and cur:GetAddress() == car:GetAddress() then return false end
    local t0 = os.clock()
    if curOk then
        local op = Sync.ref(cur)
        M.doors[op] = readDoors(m)
        if M.onLeave then pcall(M.onLeave, m, cur) end
    end
    M.park(cp) -- (every other car's bindings off: the old context's among them)
    m.NewCarActor = car
    if ctl and ctl:IsValid() then pcall(function() ctl.PlayerCarReference = car end) end
    -- (the flags kept for it, the doors' own state over them: a door that moved while another car was the context -
    -- its shut after the player's exit - wrote nothing; M.realDoors: playersync)
    local want = {}
    for k, v in pairs(M.doors[cp] or {}) do want[k] = v end
    if M.realDoors then
        local ok, r = pcall(M.realDoors, car)
        if ok and r then for k, v in pairs(r) do want[k] = v end end
    end
    writeDoors(m, want)
    if M.onEnter then pcall(M.onEnter, m, car) end
    M.unpark(cp)
    M.ctx = cp
    M.stats.switches = M.stats.switches + 1
    M.stats.lastMs = (os.clock() - t0) * 1000
    M.stats.ms = M.stats.ms + M.stats.lastMs
    return true
end

-- Every so often (and after a car's parts were spawned again): bindings of other cars made since are parked too.
-- (the context this module set, else the own car: M.ownCar, playersync - not the manager's car: spawning a car points
-- the manager at the new one for a moment, and a sweep then parked the OWN car's bindings; 8 never came back and its
-- driver's door broke off at the next exit, cars-test)
function M.sweep()
    local keep = M.ctx
    if not keep then
        local own = M.ownCar and M.ownCar()
        if not own then return 0 end
        keep = Sync.ref(own)
    end
    M.stats.sweeps = M.stats.sweeps + 1
    return M.park(keep)
end

-- A car is gone (the twin destroyed, a travel): its parked bindings with it
function M.forget(cp) parked[cp] = nil M.doors[cp] = nil end
function M.reset() parked, M.doors, M.ctx = {}, {}, nil end

function M.info()
    local cars = 0
    for _, l in pairs(parked) do cars = cars + 1 end
    local m = M.manager()
    local c = m and m.NewCarActor
    local ctl = M.controller()
    local r = ctl and ctl:IsValid() and ctl.PlayerCarReference
    local same = c and r and c:IsValid() and r:IsValid() and c:GetAddress() == r:GetAddress()
    return string.format("ctx=%s ctl_same=%s switches=%d parked=%d unparked=%d lost=%d sweeps=%d parked_cars=%d last_ms=%.1f",
        c and c:IsValid() and c:GetFName():ToString() or "none", tostring(same == true), M.stats.switches, M.stats.parked,
        M.stats.unparked, M.stats.lost, M.stats.sweeps, cars, M.stats.lastMs)
end

return M
