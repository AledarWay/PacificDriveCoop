-- the local car's doors (DoorOpen, car-local spot), the pawn's parent, the manager's door states
local car
for _, x in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if x:IsValid() and x:GetFullName():find(":PersistentLevel.", 1, true) then car = x break end end
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local o = {}
for _, d in ipairs(FindAllOf("BP_CarPart_Door_Base_C") or {}) do
    local par = d:GetAttachParentActor()
    if d:IsValid() and par and par:IsValid() and par:GetAddress() == car:GetAddress() then
        local l = KML:InverseTransformLocation(car:GetTransform(), d:K2_GetActorLocation())
        o[#o + 1] = string.format("%.0f,%.0f open=%s entering=%s loc=%s", l.X, l.Y, tostring(d.DoorOpen), tostring(d.PlayerStartedEnteringCar), tostring(d.DoorLocation))
    end
end
local pawn = FindFirstOf("PlayerController").Pawn
local p = pawn:GetAttachParentActor()
o[#o + 1] = "pawn parent=" .. (p and p:IsValid() and p:GetFName():ToString() or "-")
return table.concat(o, " | ")
