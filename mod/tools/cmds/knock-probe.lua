-- knock-test helper. KN_OP:
--   aim    the own car (its player at the wheel: a car nobody drives has its parking brake on; releasing it from Lua
--          - SetParkingBrakeActive / Wake - crashed the game, on either side) put KN_BACK units from the nearest unbroken interactive shrub /
--          tree (BP_Crash_Complex_Foliage_Base_C, class matching KN_LIKE: Shrub by default - a medium oak stops a car
--          unbroken) that is at least KN_MIN away, facing it, moving at it at KN_SPEED;
--          returns that object's "<class> <x>,<y>"
--   state  the breakable of class KN_CLS at KN_X, KN_Y on this side: broken / gone / standing
--   kick   this side's breakable at KN_X, KN_Y kicked (ObjectKicked, as the player's kick ends)
local op = KN_OP
local function ownCar()
    local T = rawget(_G, "CoopPlayers").twinModule()
    for _, x in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
        if x:IsValid() and x:GetFullName():find(":PersistentLevel.", 1, true) and not T.isTwin(x) then return x end
    end
end
local function at(cls, x, y)
    for _, a in ipairs(FindAllOf(cls) or {}) do
        if a:IsValid() then
            local l = a:K2_GetActorLocation()
            if math.abs(l.X - x) < 30 and math.abs(l.Y - y) < 30 then return a end
        end
    end
end
if op == "aim" then
    local car = ownCar()
    local cl = car:K2_GetActorLocation()
    local best, bd
    -- (a shrub; where none is swapped in by the car - the reference saves' Forest_15 spot - a young pine or a small oak,
    -- which a car also breaks; a medium oak stops it)
    for _, like in ipairs(KN_LIKE and { KN_LIKE } or { "Shrub", "Young", "Small" }) do
        if best then break end
        for _, a in ipairs(FindAllOf("BP_Crash_Complex_Foliage_Base_C") or {}) do
            if a:IsValid() and not a.IsBroken and a:GetClass():GetFName():ToString():find(like) then
                local l = a:K2_GetActorLocation()
                local d = math.sqrt((l.X - cl.X) ^ 2 + (l.Y - cl.Y) ^ 2)
                -- (KN_NEAR = { X, Y }: the nearest to that point instead - the other player's, for a kick its side has swapped in)
                local rank = KN_NEAR and math.sqrt((l.X - KN_NEAR.X) ^ 2 + (l.Y - KN_NEAR.Y) ^ 2) or d
                if d >= (KN_MIN or 0) and math.abs(l.Z - cl.Z) < 400 and (not bd or rank < bd) then best, bd = a, rank end
            end
        end
    end
    if not best then
        -- (why: how many swapped-in ones this side has, the nearest of the class at any height)
        local all, near, nz = 0, nil, nil
        for _, a in ipairs(FindAllOf("BP_Crash_Complex_Foliage_Base_C") or {}) do
            if a:IsValid() then
                all = all + 1
                local l = a:K2_GetActorLocation()
                local d = math.sqrt((l.X - cl.X) ^ 2 + (l.Y - cl.Y) ^ 2)
                if (not near or d < near) then near, nz = d, l.Z - cl.Z end
            end
        end
        return string.format("none (foliage=%d nearest=%s dz=%s car=%.0f,%.0f)", all, tostring(near and math.floor(near)), tostring(nz and math.floor(nz)), cl.X, cl.Y)
    end
    local l = best:K2_GetActorLocation()
    local dx, dy = l.X - cl.X, l.Y - cl.Y
    local n = math.sqrt(dx * dx + dy * dy)
    dx, dy = dx / n, dy / n
    local back, speed = KN_BACK or 1200, KN_SPEED or 1500
    car:K2_SetActorLocationAndRotation({ X = l.X - dx * back, Y = l.Y - dy * back, Z = math.max(cl.Z, l.Z) + 60 },
        { Pitch = 0, Yaw = math.deg(math.atan(dy, dx)), Roll = 0 }, false, {}, true)
    car.RootComponent:SetPhysicsLinearVelocity({ X = dx * speed, Y = dy * speed, Z = 0 }, false, FName("None"))
    return string.format("%s %.0f,%.0f", best:GetClass():GetFName():ToString(), l.X, l.Y)
elseif op == "state" then
    local a = at(KN_CLS, KN_X, KN_Y)
    if not a then return "gone" end
    return a.IsBroken and "broken" or "standing"
elseif op == "kick" then
    local a = at(KN_CLS, KN_X, KN_Y)
    if not a then return "none" end
    local l = a:K2_GetActorLocation()
    a:ObjectKicked(a.BaseMesh, { X = l.X, Y = l.Y, Z = l.Z + 50 }, { X = 400, Y = 0, Z = 100 })
    return "kicked"
end
return "op?"
