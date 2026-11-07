-- Probe: how the player car takes driver input. Stages via global CAR_PROBE_STAGE:
--   "info"  state of the car + install call counters on the input events
--   "count" read the counters
--   "drive" call AccelerateBrake(CAR_PROBE_AXIS or 1) every frame for 4 s (and SteerLeftRight(CAR_PROBE_STEER))
--   "after" state again (run ~5 s after "drive")
local function liveCar()
    for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
        if c:IsValid() and c:GetFullName():find(":PersistentLevel.", 1, true) then return c end
    end
end
local car = liveCar()
if not car then return "no car" end
local function f(v) return v and string.format("%.2f", v) or "nil" end
local function vc()
    for _, c in ipairs(FindAllOf("VehicleControllerComponent") or {}) do
        if c:IsValid() and c:GetOuter():GetFullName() == car:GetFullName() then return c end
    end
end
local function state()
    local l, v = car:K2_GetActorLocation(), car:GetVelocity()
    local c = vc()
    local pawn = FindFirstOf("PDP_MainCharacter_C")
    local parent = pawn and pawn.RootComponent and pawn.RootComponent.AttachParent
    local seated = parent and parent:IsValid() and parent:GetOwner():GetFullName() == car:GetFullName()
    return string.format("loc=%.0f,%.0f speed=%.0f engineOn=%s user T=%s S=%s B=%s HB=%s | thrTarget=%s thrCur=%s brakeCur=%s raw=%s | vc T=%s S=%s B=%s HB=%s park=%s | seated=%s",
        l.X, l.Y, math.sqrt(v.X * v.X + v.Y * v.Y), tostring(car.EngineOn),
        f(car.UserThrottleInput), f(car.UserSteerInput), f(car.UserBrakeInput), f(car.UserHandBrakeInput),
        f(car.ThrottleTarget), f(car.ThrottleCurrent), f(car.BrakeCurrent), f(car.RawThrottle),
        f(c and c.ThrottleInput), f(c and c.SteerInput), f(c and c.BrakeInput), f(c and c.HandbrakeInput),
        tostring(c and c:GetParkingBrakeActive()), tostring(seated))
end

local stage = CAR_PROBE_STAGE or "info"
if stage == "info" then
    local cls = car:GetClass():GetFullName():gsub("^%S+%s+", "")
    if not CoopDevCarHooks then
        CoopDevCarHooks = { n = {}, last = {} }
        for _, fn in ipairs({ "SteerLeftRight", "AccelerateBrake", "ToggleGearBoxState", "ToggleIgnitionState" }) do
            local function pre(self, a)
                if CoopDevCarHooks.busy then return end
                CoopDevCarHooks.n[fn] = (CoopDevCarHooks.n[fn] or 0) + 1
                local okv, v = pcall(function() return a:get() end)
                CoopDevCarHooks.last[fn] = okv and tostring(v) or "?"
            end
            -- post: re-run the input event with our value right after the game's own call (override test)
            local function post(self, a)
                local o = CoopDevCarOverride
                if CoopDevCarHooks.busy or not (o and os.clock() < o.untilT) then return end
                local v = (fn == "AccelerateBrake" and o.axis) or (fn == "SteerLeftRight" and o.steer) or nil
                if not v then return end
                CoopDevCarHooks.busy = true
                pcall(function() local c = self:get() if fn == "AccelerateBrake" then c:AccelerateBrake(v) else c:SteerLeftRight(v) end
                    CoopDevCarHooks.postUser = string.format("T=%.2f B=%.2f S=%.2f", c.UserThrottleInput, c.UserBrakeInput, c.UserSteerInput) end)
                CoopDevCarHooks.busy = false
                CoopDevCarHooks.n[fn .. "_post"] = (CoopDevCarHooks.n[fn .. "_post"] or 0) + 1
            end
            local ok, e = pcall(RegisterHook, cls .. ":" .. fn, pre, post)
            CoopDevCarHooks.n[fn .. "_hook"] = ok and "ok" or tostring(e)
        end
        CoopDevCarHooks.t0 = os.clock()
    end
    return "class=" .. cls .. " | " .. state()
elseif stage == "count" then
    local r = {}
    for k, v in pairs(CoopDevCarHooks.n) do r[#r + 1] = k .. "=" .. tostring(v) .. (CoopDevCarHooks.last[k] and ("(last " .. CoopDevCarHooks.last[k] .. ")") or "") end
    table.sort(r)
    return string.format("after %.1f s: ", os.clock() - CoopDevCarHooks.t0) .. table.concat(r, " ") .. " postUser=" .. tostring(CoopDevCarHooks.postUser)
elseif stage == "override" then
    CoopDevCarOverride = { axis = CAR_PROBE_AXIS or 1.0, steer = CAR_PROBE_STEER, untilT = os.clock() + 4 }
    return "override 4 s axis=" .. tostring(CoopDevCarOverride.axis) .. " steer=" .. tostring(CoopDevCarOverride.steer) .. " | " .. state()
elseif stage == "drive" then
    local axis, steer = CAR_PROBE_AXIS or 1.0, CAR_PROBE_STEER
    local untilT = os.clock() + 4
    local frames = 0
    LoopInGameThreadWithDelay(1, function()
        if os.clock() > untilT then return true end
        local c = liveCar()
        if not c then return true end
        frames = frames + 1
        CoopDevCarFrames = frames
        local before = string.format("pre T=%.2f thrT=%.2f thrC=%.2f vcT=%.2f", c.UserThrottleInput, c.ThrottleTarget, c.ThrottleCurrent, (vc() or {}).ThrottleInput or -1)
        if CAR_PROBE_MODE == "field" then
            c.UserThrottleInput = axis
            if steer then c.UserSteerInput = steer end
        else
            c:AccelerateBrake(axis)
            if steer then c:SteerLeftRight(steer) end
        end
        if frames % 60 == 5 then
            CoopDevCarLoop = (CoopDevCarLoop or "") .. string.format(" [f%d %s -> T=%.2f S=%.2f thrT=%.2f]", frames, before, c.UserThrottleInput, c.UserSteerInput, c.ThrottleTarget)
        end
    end)
    return "driving 4 s axis=" .. axis .. " steer=" .. tostring(steer) .. " | " .. state()
else
    local s = "frames=" .. tostring(CoopDevCarFrames) .. " loop:" .. tostring(CoopDevCarLoop) .. " | " .. state()
    CoopDevCarLoop = nil
    return s
end
