-- Getting out of the own car, watched (owner's two-games test 2026-11-11: "out of the back seat by the back door the
-- driver's door opened, I went through the back door and ended up as if out of the driver's door"): every 30 ms for
-- EW_S s (default 6) which of the own car's doors 1-4 are seen open (simulating, visible), and where the player stands against the car.
-- Start it, then the exit; read with `return EW_READ()`:
--   "opened=... end=... door1=... door3=... door4=... attached=... hidden1=... angle1=..."
-- hidden1 / angle1 catch a logically shut driver door whose mesh was hidden or moved by the exit workaround.
-- (car-relative cm; a door's spot is its actor's - the hinge side).
local T = _G.CoopPlayers.twinModule()
local car = T.ownCar()
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local pc = FindFirstOf("PlayerController")
local ew = { opened = {}, last = nil, att = nil, hidden1 = false, angle1 = 0 }
_G.EW = ew
local d1 = T.door(car, 1)
local base = d1 and d1.MainMesh.RelativeRotation or { Pitch = 0, Yaw = 0, Roll = 0 }
local function rel(p) local r = KML:InverseTransformLocation(car:GetTransform(), p) return string.format("%.0f,%.0f", r.X, r.Y) end
local t0 = os.clock()
local h
h = LoopInGameThreadWithDelay(30, function()
    if os.clock() - t0 > (EW_S or 6) then CancelDelayedAction(h) return end
    pcall(function()
        for n = 1, 4 do if T.doorOpen(car, n) and T.door(car, n).MainMesh:IsVisible() then ew.opened[n] = true end end
        local d = T.door(car, 1)
        if d then
            if not d.MainMesh:IsVisible() then ew.hidden1 = true end
            local r = d.MainMesh.RelativeRotation
            ew.angle1 = math.max(ew.angle1, math.abs(r.Pitch - base.Pitch), math.abs(r.Yaw - base.Yaw), math.abs(r.Roll - base.Roll))
        end
        local p = pc.Pawn
        ew.last = rel(p:K2_GetActorLocation())
        local a = p:GetAttachParentActor()
        ew.att = a ~= nil and a:IsValid()
    end)
end)
_G.EW_READ = function()
    local o = {}
    for n = 1, 4 do if ew.opened[n] then o[#o + 1] = tostring(n) end end
    local d = {}
    for _, n in ipairs({ 1, 3, 4 }) do
        local door = T.door(car, n)
        d[#d + 1] = "door" .. n .. "=" .. (door and rel(door:K2_GetActorLocation()) or "-")
    end
    return string.format("opened=%s end=%s %s attached=%s hidden1=%s angle1=%.1f", #o > 0 and table.concat(o, ",") or "none", tostring(ew.last), table.concat(d, " "), tostring(ew.att), tostring(ew.hidden1), ew.angle1)
end
return "watching"
