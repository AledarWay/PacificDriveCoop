-- Put the local player 5 m from a car (LOOK_WHICH = "own" | "copy" - the other player's ghost) and turn the
-- view to it: for screenshots comparing a car and its ghost. Uses CoopPlayers.carsInfo positions.
local info = _G.CoopPlayers.carsInfo()
local which = LOOK_WHICH or "copy"
local x, y, z = info:match(which .. "=([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)")
if not x then return "no " .. which .. " car: " .. info end
x, y, z = tonumber(x), tonumber(y), tonumber(z)
local pc = FindFirstOf("PlayerController")
local pawn = pc.Pawn
-- step out of a car first (a seated player cannot be moved)
pcall(function() local a = pawn:GetAttachParentActor() if a and a:IsValid() then pawn["Command Interact"](pawn, true) end end)
local ang = math.rad(LOOK_ANGLE or 200)
local px, py, pz = x + 500 * math.cos(ang), y + 500 * math.sin(ang), z + 120
pawn:K2_SetActorLocation({ X = px, Y = py, Z = pz }, false, {}, true)
local yaw = math.deg(math.atan(y - py, x - px))
local pitch = math.deg(math.atan(z - pz, 500))
pc:SetControlRotation({ Pitch = pitch, Yaw = yaw, Roll = 0 })
return string.format("looking at %s from %.0f,%.0f yaw %.0f", which, px, py, yaw)
