-- Stand outside door TWIN_DOOR (1 FL..4 RR) of TWIN_CAR, look at it, press E; report where the character ended up.
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local pc = FindFirstOf("PlayerController") local pawn = pc.Pawn
local a = pawn:GetAttachParentActor()
if a and a:IsValid() then return "still in " .. a:GetFName():ToString() end
local D = { { 131, -94 }, { 131, 94 }, { 8, -94 }, { 8, 94 } }
local d = D[TWIN_DOOR or 1]
local side = d[2] > 0 and 1 or -1
local stand = KML:TransformLocation(TWIN_CAR:GetTransform(), { X = d[1] - 30, Y = d[2] + side * 110, Z = 60 })
local look = KML:TransformLocation(TWIN_CAR:GetTransform(), { X = d[1] - 30, Y = d[2], Z = 40 })
pawn:K2_SetActorLocation(stand, false, {}, true)
local r = KML:FindLookAtRotation(stand, look)
pc:SetControlRotation({ Pitch = r.Pitch - 10, Yaw = r.Yaw, Roll = 0 })
local n = 0
local h h = LoopInGameThreadWithDelay(500, function()
  n = n + 1
  if n == 1 then pawn["Command Interact"](pawn, true) elseif n == 2 then pawn["Command Interact"](pawn, false) CancelDelayedAction(h) end
end)
return "E at twin door " .. (TWIN_DOOR or 1)
