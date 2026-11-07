-- Stand by a car's driver window and look at its dashboard computer (DASH_TWIN = true: the other's twin, else the own
-- car; DASH_FROM = car-local stand point {X,Y,Z}).
local T = _G.CoopPlayers.twinModule()
local car = T.ownCar()
if DASH_TWIN then
    for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then car = c end end
end
local f = DASH_FROM or { X = 40, Y = -160, Z = 100 }
DASH_TWIN, DASH_FROM = nil, nil
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local comp
for _, a in ipairs(FindAllOf("BP_PlayerCar_Computer_C") or {}) do
    local p = a:GetAttachParentActor()
    if p and p:IsValid() and p:GetAddress() == car:GetAddress() then comp = a end
end
local pc = FindFirstOf("PlayerController") local pawn = pc.Pawn
local stand = KML:TransformLocation(car:GetTransform(), f)
local look = comp and comp:K2_GetActorLocation() or KML:TransformLocation(car:GetTransform(), { X = 60, Y = 0, Z = 60 })
pawn:K2_SetActorLocation(stand, false, {}, true)
local r = KML:FindLookAtRotation(stand, look)
pc:SetControlRotation({ Pitch = r.Pitch, Yaw = r.Yaw, Roll = 0 })
return "looking at the dash, computer=" .. tostring(comp ~= nil)
