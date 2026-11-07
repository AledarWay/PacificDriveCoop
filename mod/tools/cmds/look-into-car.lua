-- Stand outside the local player car and look in at a seat (LOOK_SEAT 1..4; LOOK_FROM = car-local stand point)
local car
for _, x in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if x:IsValid() and x:GetFullName():find(":PersistentLevel.", 1, true) then car = x break end end
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local S = { { 50, -45 }, { 50, 45 }, { -60, -45 }, { -60, 45 } }
local s = S[LOOK_SEAT or 1]
local side = s[2] > 0 and 1 or -1
local pc = FindFirstOf("PlayerController") local pawn = pc.Pawn
local stand = KML:TransformLocation(car:GetTransform(), { X = s[1] + 10, Y = side * (LOOK_DIST or 230), Z = LOOK_Z or 70 })
local look = KML:TransformLocation(car:GetTransform(), { X = s[1], Y = s[2], Z = 40 })
pawn:K2_SetActorLocation(stand, false, {}, true)
local r = KML:FindLookAtRotation(stand, look)
pc:SetControlRotation({ Pitch = r.Pitch, Yaw = r.Yaw, Roll = 0 })
return "looking at seat " .. (LOOK_SEAT or 1)
