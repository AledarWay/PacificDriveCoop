-- Collision between the own car and the other's twin. COL_OP:
--   info    the twin's chassis: collision enabled / object type / response to the vehicle channels, physics, mass
--   ram     the own car put COL_BACK units behind the twin, facing it, launched at COL_SPEED cm/s
--   where   both cars: location, the own car's speed, the distance between them along the twin's forward axis
local T = rawget(_G, "CoopPlayers").twinModule()
local own = T.ownCar()
local twin
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then twin = c end end
if not (own and twin) then return "own=" .. tostring(own) .. " twin=" .. tostring(twin) end
local function info(car)
    local r = car.RootComponent
    local o = {}
    pcall(function() o[#o + 1] = "class=" .. r:GetClass():GetFName():ToString() end)
    pcall(function() o[#o + 1] = "enabled=" .. tostring(r:GetCollisionEnabled()) end)
    pcall(function() o[#o + 1] = "objtype=" .. tostring(r:GetCollisionObjectType()) end)
    pcall(function() o[#o + 1] = "profile=" .. r:GetCollisionProfileName():ToString() end)
    pcall(function() o[#o + 1] = "sim=" .. tostring(r:IsSimulatingPhysics()) end)
    local rs = {}
    for ch = 0, 31 do pcall(function() rs[#rs + 1] = tostring(r:GetCollisionResponseToChannel(ch)) end) end
    o[#o + 1] = "resp0-31=" .. table.concat(rs, "")
    -- one attached part: its object type / responses (do the car's own parts share the car's channel?)
    pcall(function()
        for _, a in ipairs(FindAllOf("BP_CarPart_Door_Base_C") or {}) do
            local p = a:GetAttachParentActor()
            if p and p:IsValid() and p:GetAddress() == car:GetAddress() then
                local m = a.RootComponent
                local prs = {}
                for ch = 0, 31 do pcall(function() prs[#prs + 1] = tostring(m:GetCollisionResponseToChannel(ch)) end) end
                o[#o + 1] = "door: " .. m:GetClass():GetFName():ToString() .. " enabled=" .. tostring(m:GetCollisionEnabled()) .. " objtype=" .. tostring(m:GetCollisionObjectType()) .. " resp=" .. table.concat(prs, "")
                break
            end
        end
    end)
    pcall(function() o[#o + 1] = "mass=" .. string.format("%.0f", r:GetMass()) end)
    return table.concat(o, " ")
end
local op = COL_OP
if op == "peak" then
    -- the own car's top speed over the next COL_MS ms, sampled every 30 ms (CoopDevPeak; "peakget" reads it)
    CoopDevPeak = { max = 0, n = 0, samples = {} }
    local t0 = os.clock()
    local function sample()
        local c = T.ownCar()
        if c then
            local v = c.RootComponent:GetPhysicsLinearVelocity(FName("None"))
            local s = math.sqrt(v.X ^ 2 + v.Y ^ 2)
            if s > CoopDevPeak.max then CoopDevPeak.max = s end
            CoopDevPeak.n = CoopDevPeak.n + 1
            local smp = { os.clock(), s, v = string.format("%.0f,%.0f,%.0f", v.X, v.Y, v.Z) }
            table.insert(CoopDevPeak.samples, smp)
            -- the closest the cars' centres came (through each other: near 0)
            local tw2
            for _, x in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if x:IsValid() and T.isTwin(x) then tw2 = x end end
            if tw2 then
                local a, b = c:K2_GetActorLocation(), tw2:K2_GetActorLocation()
                local dd = math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2)
                if not CoopDevPeak.minD or dd < CoopDevPeak.minD then CoopDevPeak.minD = dd end
                smp.d = dd
                smp.tw = string.format("%.0f,%.0f", b.X, b.Y)
                smp.g = T.stats.guarded or 0
            end
        end
        if (os.clock() - t0) * 1000 < (COL_MS or 5000) then Dev.after(30, sample) end
    end
    Dev.after(30, sample)
    return "recording"
elseif op == "peakget" then
    -- after=: the speed 0.25 s after this side's first hit sent (twincar firstBumpAt), before= just before it
    local after, before = -1, -1
    -- (this side's own hit first: the other side may have read one earlier from the twin's glide after the test's
    -- teleport - the striker's after= then fell before its real hit, 2026-11-04)
    local at = T.stats.firstBumpAt or T.stats.firstGotAt
    if at and CoopDevPeak then
        for _, smp in ipairs(CoopDevPeak.samples) do
            if smp[1] < at - 0.02 then before = smp[2] end
            if after < 0 and smp[1] >= at + 0.25 then after = smp[2] end
        end
    end
    -- (COL_CTX: the samples around the top speed: time from the first, speed, velocity, twin distance / spot, guard count)
    local ctx = ""
    if COL_CTX and CoopDevPeak then
        local sm, im = CoopDevPeak.samples, 1
        for i = 1, #sm do if sm[i][2] > sm[im][2] then im = i end end
        local o = {}
        for i = math.max(1, im - 6), math.min(#sm, im + 3) do
            local q = sm[i]
            o[#o + 1] = string.format("\n  t=%.3f s=%.0f v=%s d=%s tw=%s g=%s", q[1] - sm[1][1], q[2], q.v or "", tostring(q.d and math.floor(q.d)), tostring(q.tw), tostring(q.g))
        end
        ctx = table.concat(o) .. string.format("\n  lastGot=%s firstBump=%s start=%.3f", tostring(T.stats.lastGotAt and (T.stats.lastGotAt - sm[1][1])),
            tostring(T.stats.firstBumpAt and (T.stats.firstBumpAt - sm[1][1])), sm[1][1]) .. " seen=" .. tostring(T.stats.bumpSeen)
    end
    -- held=: the top speed held over two samples in a row (one frame's speed right after the physics pushed the car out
    -- of the twin is overwritten in that frame - BI / the guard - before the car moves on it)
    local held = -1
    if CoopDevPeak then
        local sm = CoopDevPeak.samples
        for i = 1, #sm - 1 do held = math.max(held, math.min(sm[i][2], sm[i + 1][2])) end
    end
    -- dv=: the speed the hit gave - the top held within 1 s from the cars' closest moment minus the speed 0.1 s before
    -- it (a car parked on a slope rolled down at 3.5 m/s before the hit and on after: its top speed was the slope's,
    -- quick suite 2026-11-10)
    local dv, hitV = -1, -1
    if CoopDevPeak then
        local sm, im = CoopDevPeak.samples, nil
        -- (the hit: the first jump of the speed between two samples, > 100 cm/s in 30 ms - the slope's roll is ~3; the
        -- closest moment came after the push had begun, its speed already the push's. Else the closest moment)
        for i = 1, #sm - 1 do if sm[i + 1][2] - sm[i][2] > 100 then im = i + 1 break end end
        if not im then for i = 1, #sm do if sm[i].d and (not im or sm[i].d < sm[im].d) then im = i end end end
        if im then
            local t0 = sm[im][1]
            local b = im
            while b > 1 and sm[b][1] > t0 - 0.1 do b = b - 1 end
            hitV = sm[b][2]
            -- (as vectors: the change of the velocity, whichever way the car rolled)
            local function vec(q) local x, y = (q.v or ""):match("^(-?[%d.]+),(-?[%d.]+)") return tonumber(x) or 0, tonumber(y) or 0 end
            local bx, by = vec(sm[b])
            local function dvAt(q) local x, y = vec(q) return math.sqrt((x - bx) ^ 2 + (y - by) ^ 2) end
            local top = -1
            for i = im, #sm - 1 do
                if sm[i][1] > t0 + 1.0 then break end
                top = math.max(top, math.min(dvAt(sm[i]), dvAt(sm[i + 1])))
            end
            dv = top
        end
    end
    return string.format("held=%.0f peak=%.0f n=%d before=%.0f after=%.0f mind=%.0f dv=%.0f hitv=%.0f", held, CoopDevPeak and CoopDevPeak.max or -1, CoopDevPeak and CoopDevPeak.n or 0,
        before, after, CoopDevPeak and CoopDevPeak.minD or -1, dv, hitV) .. ctx
end
if op == "hp" then
    -- the own car's parts' health (twincar stateLine: slot=health,fuel,battery;...): sum and the parts with health
    local line = T.stateLine() or ""
    local sum, n = 0, 0
    for _, v in line:gmatch("([^=;]+)=([^;]+)") do
        local h = tonumber(v:match("^([^,]*)"))
        if h then sum, n = sum + h, n + 1 end
    end
    return string.format("hp=%.1f parts=%d", sum, n)
elseif op == "info" then
    return "own: " .. info(own) .. "\ntwin: " .. info(twin)
elseif op == "aim" then
    -- the own car (its player at the wheel) put COL_BACK units behind the twin, facing it
    local tl, f = twin:K2_GetActorLocation(), twin:GetActorForwardVector()
    local back = COL_BACK or 1200
    local at = { X = tl.X - f.X * back, Y = tl.Y - f.Y * back, Z = tl.Z + 30 }
    own:K2_SetActorLocationAndRotation(at, twin:K2_GetActorRotation(), false, {}, true)
    -- COL_SPEED: already moving at it (a driven car: no parking brake to hold it)
    if COL_SPEED then own.RootComponent:SetPhysicsLinearVelocity({ X = f.X * COL_SPEED, Y = f.Y * COL_SPEED, Z = 0 }, false, FName("None")) end
    return string.format("own at %.0f,%.0f facing the twin at %.0f,%.0f", at.X, at.Y, tl.X, tl.Y)
elseif op == "launch" then
    -- the own car where it is, at COL_SPEED cm/s along the twin's forward axis (no teleport: a teleport near the other
    -- car glides its twin there - the other side read that as a hit and the striker was held to its shared speed)
    local f = twin:GetActorForwardVector()
    local sp = COL_SPEED or 1500
    own.RootComponent:SetPhysicsLinearVelocity({ X = f.X * sp, Y = f.Y * sp, Z = 0 }, false, FName("None"))
    local ol, tl = own:K2_GetActorLocation(), twin:K2_GetActorLocation()
    return string.format("own at %.0f,%.0f launched at %d cm/s toward the twin at %.0f,%.0f", ol.X, ol.Y, sp, tl.X, tl.Y)
elseif op == "ram" then
    local tl, f = twin:K2_GetActorLocation(), twin:GetActorForwardVector()
    local back = COL_BACK or 1200
    local at = { X = tl.X - f.X * back, Y = tl.Y - f.Y * back, Z = tl.Z + 30 }
    own:K2_SetActorLocationAndRotation(at, twin:K2_GetActorRotation(), false, {}, true)
    -- (parked: the parking brake stopped a launched car at once)
    local vcc = StaticFindObject("/Script/PenDriverPro.VehicleControllerComponent")
    local comps = own:K2_GetComponentsByClass(vcc)
    for i = 1, #comps do
        local c = comps[i]:get()
        pcall(function() c:SetParkingBrakeActive(false) end)
        pcall(function() c:Wake() end)
    end
    local sp = COL_SPEED or 1500
    own.RootComponent:SetPhysicsLinearVelocity({ X = f.X * sp, Y = f.Y * sp, Z = 0 }, false, FName("None"))
    return string.format("own at %.0f,%.0f launched at %d cm/s toward the twin at %.0f,%.0f", at.X, at.Y, sp, tl.X, tl.Y)
else
    local tl, ol, f = twin:K2_GetActorLocation(), own:K2_GetActorLocation(), twin:GetActorForwardVector()
    local v = own.RootComponent:GetPhysicsLinearVelocity(FName("None"))
    local along = (ol.X - tl.X) * f.X + (ol.Y - tl.Y) * f.Y
    return string.format("along=%.0f own=%.0f,%.0f,%.0f twin=%.0f,%.0f,%.0f speed=%.0f", along, ol.X, ol.Y, ol.Z, tl.X, tl.Y, tl.Z,
        math.sqrt(v.X ^ 2 + v.Y ^ 2 + v.Z ^ 2))
end
