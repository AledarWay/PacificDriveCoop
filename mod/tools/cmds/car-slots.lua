-- Which car slots sit where (car-local coordinates) and what is installed in them.
-- Seats for reference: driver character 46.2,-45.8,-12.3; mirrored passenger 46.2,+45.8.
local car
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
    if c:IsValid() and c:GetFullName():find(":PersistentLevel.", 1, true) then car = c end
end
if not car then return "no car" end
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local xf = car:GetTransform()
local names = { "SLOT_Internal_Computer", "SLOT_BackSeatLeft", "SLOT_BackSeatRight", "SLOT_Interior_Large_01",
    "SLOT_Internal_ReserveBattery", "SLOT_Internal_ReserveGas", "SLOT_Internal_Upgrade_Side_L", "SLOT_Internal_Upgrade_Side_R",
    "SLOT_Internal_Upgrade_Roof_R", "SLOT_Internal_Upgrade_Roof_F", "SLOT_Internal_CarFriend", "SLOT_Internal_Gobbler",
    "SLOT_Internal_GoldenGobbler", "SLOT_Internal_Soul", "SLOT_Interior_SmallGadgetLeft", "SLOT_Interior_SmallGadgetRight",
    "SLOT_Internal_Radio", "SLOT_Internal_Compass", "SLOT_TrunkStorage", "SLOT_TrunkCrafting", "TempSocket_Seat" }
local out = {}
for _, n in ipairs(names) do
    local ok, s = pcall(function()
        local c = car[n]
        if not (c and c:IsValid()) then return n .. "=missing" end
        local l = KML:InverseTransformLocation(xf, c:K2_GetComponentLocation())
        local item = "-"
        local okA, a = pcall(function() return c.SpawnedActor end)
        if okA and a and a:IsValid() then item = a:GetClass():GetFName():ToString() end
        local empty = ""
        local okE, e = pcall(function() return c.EmptyInstance end)
        if okE and e and e:IsValid() then empty = " (empty-instance)" end
        local tag = ""
        pcall(function() tag = " tag=" .. c.SlotName.TagName:ToString() end)
        return string.format("%s @%.0f,%.0f,%.0f item=%s%s%s", n, l.X, l.Y, l.Z, item, empty, tag)
    end)
    out[#out + 1] = ok and s or (n .. "=ERR " .. tostring(s))
end
-- every actor attached to the car, in car space (devices on seats show up here)
local attached = {}
local okAtt, eAtt = pcall(function() car:GetAttachedActors(attached, true) end)
if not okAtt then out[#out + 1] = "GetAttachedActors: " .. tostring(eAtt) end
for _, a in ipairs(attached) do
    pcall(function()
        a = a.get and a:get() or a
        local l = KML:InverseTransformLocation(xf, a:K2_GetActorLocation())
        if math.abs(l.Y) > 20 and l.X > -150 and l.X < 120 and l.Z > -60 and l.Z < 60 then
            out[#out + 1] = string.format("attached %s @%.0f,%.0f,%.0f", a:GetClass():GetFName():ToString(), l.X, l.Y, l.Z)
        end
    end)
end
return table.concat(out, "\n")
