-- The long bot session's own steps (soak-test.ps1). SOAK_OP:
--   where      where the player is: own (in the own car) / twin (in the other's car, seat n) / foot; the cars' distance
--   regroup    the own car put SOAK_SIDE units beside the other's car, as it stands, stopped (bots drift apart)
--   face       the character turned to yaw SOAK_YAW (the next walk goes there)
--   horn       the horn for 1.5 s (the car manager, as the horn key)
--   drivetwin  in the other's car at the wheel: throttle SOAK_THR, steer SOAK_STEER for SOAK_S s, then the handbrake
--              (the game calls the car interface on the own car with the driver's axes; the mod sends them on)
--   interact   E down, up after SOAK_MS (100: a tap)
local P = rawget(_G, "CoopPlayers")
local T = P.twinModule()
local own = T.ownCar()
local twin
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then twin = c end end
local pc = FindFirstOf("PlayerController")
local pawn = pc.Pawn
local op = SOAK_OP
SOAK_OP = nil
if op == "where" then
    local par = pawn:GetAttachParentActor()
    local w = "foot"
    if par and par:IsValid() then w = T.isTwin(par) and "twin" or "own" end
    local gi = P.ghostInfo()
    local seat = (gi:match("seat=(%S+)")) or "-"
    -- (in the other's car the character sits in the mod's own way: in_ghost names whose car)
    if (gi:match("in_ghost=(%S+)") or "-") ~= "-" then w = "twin" end
    local d = -1
    if own and twin then
        local a, b = own:K2_GetActorLocation(), twin:K2_GetActorLocation()
        d = math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2)
    end
    local pd = -1
    if twin then
        local a, b = pawn:K2_GetActorLocation(), twin:K2_GetActorLocation()
        pd = math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2)
    end
    local world, hp = "-", "-"
    pcall(function() world = pawn:GetWorld():GetFName():ToString() end)
    -- (the character's health: a travel home in the middle of a run - death or not?)
    -- (the character's own health component class is not known: any component with Health in its class name)
    pcall(function()
        local comps = pawn:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.ActorComponent"))
        -- (a plain Lua table here: comps:ForEach threw every probe, hp stayed "-")
        local list = {}
        if type(comps) == "table" then for _, e in ipairs(comps) do list[#list + 1] = e end
        else comps:ForEach(function(_, e) list[#list + 1] = e:get() end) end
        for _, c in ipairs(list) do
            local n = c:GetClass():GetFName():ToString()
            if hp == "-" and n:find("Health") then
                for _, f in ipairs({ "HC_GetHealth", "GetHealth", "GetCurrentHealth" }) do
                    local ok, v = pcall(function() return c[f](c) end)
                    if ok and type(v) == "number" then hp = string.format("%.0f", v) break end
                end
                if hp == "-" then hp = "?" .. n end
            end
        end
    end)
    return string.format("where=%s seat=%s cars=%.0f to_twin=%.0f world=%s hp=%s", w, seat, d, pd, world, hp)
elseif op == "regroup" then
    if not (own and twin) then return "no cars" end
    local tl, r = twin:K2_GetActorLocation(), twin:GetActorRightVector()
    local side = SOAK_SIDE or 900
    local at = { X = tl.X + r.X * side, Y = tl.Y + r.Y * side, Z = tl.Z + 60 }
    own:K2_SetActorLocationAndRotation(at, twin:K2_GetActorRotation(), false, {}, true)
    pcall(function() own.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName("None")) end)
    pcall(function() own.RootComponent:SetPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false, FName("None")) end)
    return string.format("own car beside the other's at %.0f,%.0f", at.X, at.Y)
elseif op == "face" then
    local r = { Pitch = 0, Yaw = SOAK_YAW or 0, Roll = 0 }
    pc:SetControlRotation(r)
    pcall(function() pawn:K2_SetActorRotation(r, true) end)
    return "facing " .. r.Yaw
elseif op == "horn" then
    local m = FindFirstOf("BP_CarManager_C")
    m:StartHornHonk(FName("Bot"))
    Dev.after(1500, function() local x = FindFirstOf("BP_CarManager_C") if x and x:IsValid() then x:EndHornHonk(FName("Bot")) end end)
    return "horn"
elseif op == "drivetwin" then
    local c = P.ownCarActor()
    local s, thr, steer = SOAK_S or 4, SOAK_THR or 1.0, SOAK_STEER or 0
    local t0 = os.clock()
    local h
    h = LoopInGameThreadWithDelay(1, function()
        local dt = os.clock() - t0
        if dt > s + 3 or not c:IsValid() then CancelDelayedAction(h) return end
        if dt > s then c:AccelerateBrake(0) c:HANDBRAKE(1) return end
        c:AccelerateBrake(thr) c:SteerLeftRight(steer)
    end)
    return string.format("driving the other's car %.1f s throttle %.2f steer %.2f", s, thr, steer)
elseif op == "interact" then
    pawn["Command Interact"](pawn, true)
    Dev.after(SOAK_MS or 100, function() local q = FindFirstOf("PlayerController").Pawn q["Command Interact"](q, false) end)
    return "E " .. (SOAK_MS or 100) .. " ms"
end
return "unknown op " .. tostring(op)
