-- Test stand-in for the game's attach (a person puts a part on from the hand): the first inventory item whose
-- archetype contains PUT_ITEM (default "Wheel") moves into the twin's slot PUT_SLOT (default WheelRL) - the same
-- container change the game makes; the mod's watch then sends it to the owner.
local T = _G.CoopPlayers.twinModule()
local twin
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then twin = c end end
local cont = twin and T.twinContainer(twin)
if not cont then return "no twin container" end
local dst = cont:GetSlot(FName(PUT_SLOT or "Car.Equip.Essentials.WheelRL"))
local inv = FindFirstOf("BP_InventoryManager_C").Inventory_Player
for i = 1, inv.Slots:GetArrayNum() do
    local sl = inv.Slots[i]
    if sl.Items:GetArrayNum() > 0 and sl.Items[1].Archetype:GetFName():ToString():find(PUT_ITEM or "Wheel", 1, true) then
        local ok, e = pcall(function() sl:TransferSingleIntoSlot(dst) end)
        return "put on: " .. tostring(ok) .. (ok and "" or (" " .. tostring(e))) .. " slot now " .. T.twinSlot(twin, PUT_SLOT or "Car.Equip.Essentials.WheelRL")
    end
end
return "nothing to put on"
