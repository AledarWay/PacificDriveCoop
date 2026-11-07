local car
for _, x in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if x:IsValid() and x:GetFullName():find(":PersistentLevel.", 1, true) then car = x break end end
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local p = FindFirstOf("PlayerController").Pawn
local l = KML:InverseTransformLocation(car:GetTransform(), p:K2_GetActorLocation())
local par = p:GetAttachParentActor()
local cam = FindFirstOf("PlayerController").PlayerCameraManager
local cl = KML:InverseTransformLocation(car:GetTransform(), cam:GetCameraLocation())
return string.format("pawn %.0f,%.0f,%.0f cam %.0f,%.0f,%.0f parent=%s", l.X, l.Y, l.Z, cl.X, cl.Y, cl.Z, par and par:IsValid() and par:GetFName():ToString() or "-")
