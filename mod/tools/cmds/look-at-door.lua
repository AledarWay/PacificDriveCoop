-- Stand outside door N of the local player car (1 FL, 2 FR, 3 RL, 4 RR) and look at it (screenshots of prompts).
local n = LOOK_DOOR or 1
local car
for _, x in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if x:IsValid() and x:GetFullName():find(":PersistentLevel.", 1, true) then car = x break end end
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local pc = FindFirstOf("PlayerController")
local pawn = pc.Pawn
if pawn:GetAttachParentActor() then pawn["Exit Car"](pawn, false, true) end
local D = { { 131, -94 }, { 131, 94 }, { 8, -94 }, { 8, 94 } }
local d = D[n]
local side = d[2] > 0 and 1 or -1
local stand = KML:TransformLocation(car:GetTransform(), { X = d[1] - 30, Y = d[2] + side * 110, Z = 60 })
local look = KML:TransformLocation(car:GetTransform(), { X = d[1] - 30, Y = d[2], Z = 40 })
pawn:K2_SetActorLocation(stand, false, {}, true)
local r = KML:FindLookAtRotation(stand, look)
pc:SetControlRotation({ Pitch = r.Pitch - 10, Yaw = r.Yaw, Roll = 0 })
return string.format("at door %d", n)
