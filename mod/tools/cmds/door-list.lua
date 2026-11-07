-- every door part attached to the local car: class, number spot, IsA Door_Base, MainMesh
local car
for _, x in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if x:IsValid() and x:GetFullName():find(":PersistentLevel.", 1, true) then car = x break end end
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local cls = StaticFindObject("/Game/Gameplay/Inventory/Items/Car/Doors/BP_CarPart_Door_Base.BP_CarPart_Door_Base_C")
local o = { "class found: " .. tostring(cls and cls:IsValid()) }
for _, d in ipairs(FindAllOf("BP_CarPart_Door_Base_C") or {}) do
    local par = d:GetAttachParentActor()
    local l = KML:InverseTransformLocation(car:GetTransform(), d:K2_GetActorLocation())
    local m = d.MainMesh
    local gp = par and par:IsValid() and par:GetAttachParentActor()
    o[#o + 1] = string.format("%s at %.0f,%.0f isa=%s mesh=%s parent=%s grandparent=%s", d:GetClass():GetFName():ToString(), l.X, l.Y, tostring(d:IsA(cls)),
        tostring(m and m:IsValid()), par and par:IsValid() and par:GetFName():ToString() or "-", gp and gp:IsValid() and gp:GetFName():ToString() or "-")
end
return table.concat(o, "\n")
