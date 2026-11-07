-- The seated puppet seen from outside: the local character put LOOK_SIDE cm beside the car (on the puppet's side),
-- LOOK_UP cm above the ground under it, looking at the puppet's feet. Returns the feet / pelvis / knees in car space.
local p, pose = _G.CoopPlayers.puppetParts()
if not (p and pose) then return "no puppet" end
local car = p:GetAttachParentActor()
if not (car and car:IsValid()) then return "puppet not attached" end
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local xf = car:GetTransform()
local function cl(b) return KML:InverseTransformLocation(xf, pose:GetBoneLocationByName(FName(b), 0)) end
local o = {}
for _, b in ipairs({ "pelvis", "calf_l", "foot_l", "ball_l", "foot_r" }) do
    local v = cl(b) o[#o + 1] = string.format("%s=%.0f,%.0f,%.0f", b, v.X, v.Y, v.Z)
end
local foot = pose:GetBoneLocationByName(FName("foot_l"), 0)
local fl = cl("foot_l")
local side = fl.Y >= 0 and 1 or -1
local eye = KML:TransformLocation(xf, { X = fl.X, Y = side * (LOOK_SIDE or 300), Z = LOOK_Z or -40 })
local pc = FindFirstOf("PlayerController")
local pawn = pc.Pawn
pawn:K2_SetActorLocation(eye, false, {}, true)
local d = { X = foot.X - eye.X, Y = foot.Y - eye.Y, Z = foot.Z - eye.Z }
local yaw = math.deg(math.atan(d.Y, d.X))
local pitch = math.deg(math.atan(d.Z, math.sqrt(d.X * d.X + d.Y * d.Y)))
pc:SetControlRotation({ Pitch = pitch, Yaw = yaw, Roll = 0 })
return table.concat(o, " ") .. string.format(" | look yaw %.0f pitch %.0f", yaw, pitch)
