-- item archetypes whose name matches ARCH_FIND (the class of a seat device's archetype)
local car
for _, x in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if x:IsValid() and x:GetFullName():find(":PersistentLevel.", 1, true) then car = x break end end
local it = car.SLOT_BackSeatLeft.ItemSlot.Items[1]
local cls = it.Archetype:GetClass()
local o = { "archetype class " .. cls:GetFullName() .. " item class " .. it:GetClass():GetFName():ToString() }
for _, a in ipairs(FindAllOf(cls:GetFName():ToString()) or {}) do
    local n = a:GetFName():ToString()
    if n:lower():find((ARCH_FIND or "mirror"):lower(), 1, true) then o[#o + 1] = a:GetFullName() end
end
return table.concat(o, "\n")
