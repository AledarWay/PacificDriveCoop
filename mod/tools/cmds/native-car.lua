-- Probes of the native car rework (2026-10-30): the other's car (twin) worked by the game itself, the car manager
-- pointed at it. Run on a cars-test -SetupOnly -NoMute pair (the twins keep the game's own handlers).
--   NC_OP = "freeze"   the player sync of this side stops (its loops end), the twin stays as it is
--   NC_OP = "state"    (default) who holds what: the character's car, the manager's car, ignition / gear, the twin's
--                      physics / vehicle controller / speed, door n (NC_N, 1) open on both cars, manager door flags
--   NC_OP = "mgr"      the manager's car := NC_TO ("twin" | "own")
--   NC_OP = "phys"     the twin simulates (NC_ON true / false) and its vehicle controller ticks
--   NC_OP = "drive"    the vehicle controller of the manager's car: throttle NC_TH (0.6), steer NC_ST (0) for NC_S s (3)
local T = _G.CoopPlayers.twinModule()
local twin
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then twin = c end end
local own = T.ownCar()
local cm = FindFirstOf("BP_CarManager_C")
local pc = FindFirstOf("PlayerController")
local pawn = pc.Pawn
local op = NC_OP or "state"
NC_OP = nil
local function name(a)
    if not (a and a:IsValid()) then return "none" end
    if twin and a:GetAddress() == twin:GetAddress() then return "twin" end
    if own and a:GetAddress() == own:GetAddress() then return "own" end
    return a:GetFName():ToString()
end
local function vcOf(car)
    for _, c in ipairs(FindAllOf("VehicleControllerComponent") or {}) do
        if c:IsValid() and c:GetOuter():IsValid() and c:GetOuter():GetAddress() == car:GetAddress() then return c end
    end
end
if op == "freeze" then
    _G.CoopPlayers.stopped = true
    return "player sync of this side frozen"
elseif op == "mgr" then
    local to = NC_TO == "own" and own or twin
    cm.NewCarActor = to
    return "manager -> " .. name(cm.NewCarActor)
elseif op == "phys" then
    local on = NC_ON ~= false
    local vc = vcOf(twin)
    local ok1 = pcall(function() twin.RootComponent:SetSimulatePhysics(on) end)
    local ok2 = vc and pcall(function() vc:SetComponentTickEnabled(on) end)
    return string.format("twin physics %s: %s, vc tick: %s", tostring(on), tostring(ok1), tostring(ok2))
elseif op == "drive" then
    local car = cm.NewCarActor
    local vc = vcOf(car)
    if not vc then return "no vehicle controller on " .. name(car) end
    local th, stv, s = NC_TH or 0.6, NC_ST or 0, NC_S or 3
    local t0 = os.clock()
    local h
    h = LoopInGameThreadWithDelay(1, function()
        if os.clock() - t0 > s then
            pcall(function() vc:SetThrottleInput(0) vc:SetSteeringInput(0) end)
            CancelDelayedAction(h)
            return
        end
        pcall(function() vc:SetThrottleInput(th) vc:SetSteeringInput(stv) end)
    end)
    return "driving " .. name(car) .. " " .. s .. " s"
end
-- state
local n = NC_N or 1
local o = {}
o[#o + 1] = "pawn_in=" .. name(pawn:GetAttachParentActor())
o[#o + 1] = "mgr=" .. name(cm.NewCarActor)
pcall(function() o[#o + 1] = "ign=" .. tostring(cm.CarIgnitionState) end)
pcall(function() local out = {} cm:GetCarGearBoxState(out) for k, v in pairs(out) do o[#o + 1] = "gear=" .. tostring(v) end end)
pcall(function() o[#o + 1] = "carstate=" .. tostring(cm.PlayerCarState) end)
if twin then
    pcall(function() o[#o + 1] = "twin_sim=" .. tostring(twin.RootComponent:IsSimulatingPhysics(FName("None"))) end)
    local vc = vcOf(twin)
    pcall(function() o[#o + 1] = "twin_vc_tick=" .. tostring(vc:IsComponentTickEnabled()) end)
    pcall(function() local v = twin:GetVelocity() o[#o + 1] = string.format("twin_speed=%.0f", math.sqrt(v.X * v.X + v.Y * v.Y)) end)
    pcall(function() local l = twin:K2_GetActorLocation() o[#o + 1] = string.format("twin_at=%.0f,%.0f,%.0f", l.X, l.Y, l.Z) end)
    o[#o + 1] = "twin_door" .. n .. "=" .. tostring(T.doorOpen(twin, n))
end
if own then
    o[#o + 1] = "own_door" .. n .. "=" .. tostring(T.doorOpen(own, n))
    pcall(function() local v = own:GetVelocity() o[#o + 1] = string.format("own_speed=%.0f", math.sqrt(v.X * v.X + v.Y * v.Y)) end)
end
local s = {}
pcall(function() cm.DoorStates:ForEach(function(k, v) if v:get() then s[#s + 1] = tostring(k:get()) end end) end)
o[#o + 1] = "mgr_doors_open=" .. (#s == 0 and "none" or table.concat(s, ","))
local hm = FindFirstOf("BP_HighlightManager_C")
pcall(function() local h = hm.CurrentHighlight o[#o + 1] = "hl=" .. (h and h:IsValid() and (name(h:GetOwner()) .. "." .. h:GetFName():ToString()) or "none") end)
return table.concat(o, " ")
