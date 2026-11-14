-- Why the car's own pipeline holds the throttle at 0 (reference saves, 2026-11-14: the User* input written, the
-- vehicle controller's ThrottleInput stayed 0). Stage TP_STAGE = "go": writes UserThrottleInput 1 every frame for
-- 3 s; "read" (after): the controller's inputs seen meanwhile, the move, ignition / gear, fuel components' amounts.
local stage = TP_STAGE or "read"
TP_STAGE = nil
local car = FindFirstOf("BP_CarManager_C").NewCarActor
local vc
for _, c in ipairs(FindAllOf("VehicleControllerComponent") or {}) do
    if c:IsValid() and c:GetOuter():GetAddress() == car:GetAddress() then vc = c end
end
if stage == "go" then
    TP = { l0 = car:K2_GetActorLocation(), maxT = 0, n = 0 }
    local t0 = os.clock()
    local h h = LoopInGameThreadWithDelay(1, function()
        if os.clock() - t0 > 3 then CancelDelayedAction(h) car.UserThrottleInput = 0 return end
        car.UserThrottleInput = 1
        TP.n = TP.n + 1
        local t = vc.ThrottleInput
        if t > TP.maxT then TP.maxT = t end
    end)
    return "going"
end
local m = FindFirstOf("BP_CarManager_C")
local l = car:K2_GetActorLocation()
local mv = TP and math.sqrt((l.X - TP.l0.X) ^ 2 + (l.Y - TP.l0.Y) ^ 2) or -1
local out = { string.format("frames=%d maxVcThrottle=%.2f moved=%.0f ign=%s gear=%s park=%s", TP and TP.n or 0, TP and TP.maxT or -1, mv,
    tostring(m.CarIgnitionState), tostring(m.MyCarGearBox), tostring(select(2, pcall(function() return vc:IsParkingBrakeActive() end)))) }
for _, f in ipairs(FindAllOf("BP_FuelableComponent_C") or {}) do
    if f:IsValid() then
        local o = f:GetOwner()
        local s = "?"
        pcall(function() local t = { {}, {}, {}, {}, {}, {}, {} } f:GetFuelStatus(t[1], t[2], t[3], t[4], t[5], t[6], t[7]) s = string.format("%.1f", tonumber(t[1].Fuel) or -1) end)
        out[#out + 1] = (o and o:IsValid() and o:GetFName():ToString() or "nil") .. " " .. s
    end
end
return table.concat(out, " | ")
