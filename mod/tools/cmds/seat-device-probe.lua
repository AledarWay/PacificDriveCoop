-- Take the device off the back-right seat frame into the car trunk and show both sides.
local car
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
    if c:IsValid() and c:GetFullName():find(":PersistentLevel.", 1, true) then car = c end
end
if not car then return "no car" end
local IM = FindFirstOf("BP_InventoryManager_C")
local function items(sl)
    local r = {}
    for i = 1, sl.Items:GetArrayNum() do
        local it = sl.Items[i]
        r[#r + 1] = (it and it:IsValid() and it.Archetype:IsValid()) and (it.Archetype:GetFName():ToString() .. "#" .. it:GetFName():ToString()) or "?"
    end
    return "[" .. table.concat(r, ",") .. "]"
end
local function cont(c)
    local r = {}
    for i = 1, c.Slots:GetArrayNum() do
        local s = c.Slots[i]
        for j = 1, s.Items:GetArrayNum() do
            local it = s.Items[j]
            r[#r + 1] = (it and it:IsValid() and it.Archetype:IsValid()) and (it.Archetype:GetFName():ToString() .. "#" .. it:GetFName():ToString()) or "?"
        end
    end
    return "[" .. table.concat(r, ",") .. "]"
end
local out = {}
local slot = car.SLOT_BackSeatRight.ItemSlot
local trunk = IM.Inventory_Trunk
out[#out + 1] = "before: frame=" .. items(slot) .. " trunk=" .. cont(trunk)
local eqOut = {}
IM:GetCarEquippedContainer(eqOut)
local eq = eqOut.Inventory_CarEquipped
out[#out + 1] = "car equipped container: " .. tostring(eq and eq:IsValid() and eq:GetClass():GetFName():ToString())
local inst = slot.Items[1]
local slotName = slot.SlotName
out[#out + 1] = "slot name: " .. slotName:ToString()
local fail = {}
pcall(function() trunk:CanAddItem(inst, fail) end)
pcall(function() out[#out + 1] = "trunk CanAddItem fail type: " .. tostring(fail.FailReason and fail.FailReason.Failure) end)
local okR, eR = pcall(function() eq:RemoveItemFromSlot(slotName, inst) end)
out[#out + 1] = "RemoveItemFromSlot: " .. tostring(okR) .. " " .. tostring(eR or "")
local okA, eA = pcall(function() trunk:AddItem(inst, true) end)
out[#out + 1] = "trunk AddItem: " .. tostring(okA) .. " " .. tostring(eA or "")
out[#out + 1] = "after remove: frame=" .. items(slot) .. " trunk=" .. cont(trunk)
local a1 = car.SLOT_BackSeatRight.SpawnedActor
out[#out + 1] = "frame actor now: " .. ((a1 and a1:IsValid()) and a1:GetClass():GetFName():ToString() or "none")
-- and back on the frame
local okT, eT = pcall(function() trunk:RemoveItem(inst) end)
local okB, eB = pcall(function() eq:AddItem(slotName, inst, false) end)
out[#out + 1] = string.format("put back: trunk RemoveItem %s %s, eq AddItem %s %s", tostring(okT), tostring(eT or ""), tostring(okB), tostring(eB or ""))
out[#out + 1] = "after put back: frame=" .. items(slot) .. " trunk=" .. cont(trunk)
local a2 = car.SLOT_BackSeatRight.SpawnedActor
out[#out + 1] = "frame actor now: " .. ((a2 and a2:IsValid()) and a2:GetClass():GetFName():ToString() or "none")return table.concat(out, "\n")
