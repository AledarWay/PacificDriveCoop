-- The flattest clear way for this side's player to be knocked along (contact-test's kick): of 8 directions, the ones
-- with nothing at knee and chest height within KD_LEN, the ground KD_LEN out the least above the player's feet. Returns
-- "<yaw> rise=<cm> clear=<n of 8>" (yaw in degrees; the knocked one goes that way).
local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local pawn = FindFirstOf("PlayerController").Pawn
local p = pawn:K2_GetActorLocation()
local len = KD_LEN or 350
local function hit(a, b)
    local h = {}
    local ok, r = pcall(function() return KSL:LineTraceSingle(pawn, a, b, 0, false, {}, 0, h, true, { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0) end)
    return ok and r, h
end
local feet = p.Z - 90
local best, bestRise, clear = nil, nil, 0
for i = 0, 7 do
    local yaw = i * 45
    local dx, dy = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
    local blocked = false
    for _, z in ipairs({ -40, 30 }) do
        if hit({ X = p.X, Y = p.Y, Z = p.Z + z }, { X = p.X + dx * len, Y = p.Y + dy * len, Z = p.Z + z }) then blocked = true end
    end
    if not blocked then
        clear = clear + 1
        local o = { X = p.X + dx * len, Y = p.Y + dy * len }
        local ok, h = hit({ X = o.X, Y = o.Y, Z = p.Z + 200 }, { X = o.X, Y = o.Y, Z = p.Z - 600 })
        local rise = ok and h.ImpactPoint and (h.ImpactPoint.Z - feet) or -600
        if not bestRise or rise < bestRise then best, bestRise = yaw, rise end
    end
end
if not best then return "none clear=0" end
return string.format("%d rise=%.0f clear=%d", best, bestRise, clear)
