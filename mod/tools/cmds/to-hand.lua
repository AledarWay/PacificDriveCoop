-- Put the first item of the player's inventory whose archetype name contains HAND_ITEM (default "Wheel") into the
-- hand slot (the hand's current item goes back to the inventory): as picking it on the hotbar
local IM = FindFirstOf("BP_InventoryManager_C")
local inv, hand = IM.Inventory_Player, IM.Inventory_PlayerHand
local want = HAND_ITEM or "Wheel"
local hs = hand.Slots[1]
for i = 1, inv.Slots:GetArrayNum() do
    local sl = inv.Slots[i]
    if sl.Items:GetArrayNum() > 0 and sl.Items[1].Archetype:GetFName():ToString():find(want, 1, true) then
        local out = {}
        local ok, e = pcall(function() sl:TransferSwapIntoSlot(hs, {}, {}) end)
        local h = hs.Items:GetArrayNum() > 0 and hs.Items[1].Archetype:GetFName():ToString() or "empty"
        return "to hand: " .. tostring(ok) .. (ok and "" or (" " .. tostring(e))) .. " hand=" .. h
    end
end
return "no " .. want .. " in the inventory"
