-- the host car's doors: class, car-local position, highlight component state
local car
for _, x in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if x:IsValid() and x:GetFullName():find(":PersistentLevel.", 1, true) then car = x break end end
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local o = {}
for _, d in ipairs(FindAllOf("BP_CarPart_Door_Base_C") or {}) do
    if d:IsValid() and d:GetFullName():find(":PersistentLevel.", 1, true) then
        local l = KML:InverseTransformLocation(car:GetTransform(), d:K2_GetActorLocation())
        local h = d.Highlight
        local par = d:GetAttachParentActor()
        o[#o + 1] = string.format("%s at %.0f,%.0f,%.0f open=%s hl_active=%s widget=%s hold=%.2f parent=%s",
            d:GetClass():GetFName():ToString(), l.X, l.Y, l.Z, tostring(d.DoorOpen), tostring(h:IsActive()), tostring(h.bShowInteractWidget), h.HoldTime,
            par and par:IsValid() and par:GetClass():GetFName():ToString() or "-")
    end
end
return #o .. " doors\n" .. table.concat(o, "\n")
