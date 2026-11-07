local IBL = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
local ctx = FindFirstOf("PlayerController")
local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") local a for _, x in ipairs(FindAllOf("BP_Lootable_Crate_Junk_C") or {}) do if KSL:IsValid(x) and x:GetFullName():find(":PersistentLevel%.") then a = x break end end
local c = a.InventoryContainer
local function dump(tag) local t = {} for si = 1, c.Slots:GetArrayNum() do local s = c.Slots[si] t[#t+1] = (s and s:IsValid()) and (s.Items:GetArrayNum() .. "/" .. s.Capacity) or "nil" end Dev.out(tag, c.Slots:GetArrayNum(), table.concat(t, " ")) end
dump("start")
c:RemoveAllItems() dump("after RemoveAllItems")

pcall(function() c:Compact() end) dump("after Compact")
local tape = StaticFindObject("/Game/Gameplay/Inventory/Items/Resources/Basic/RawTape/IA_Resource_Raw_Tape.IA_Resource_Raw_Tape")
c:AddSlot() dump("after AddSlot")
local n = c.Slots:GetArrayNum()
for i = 1, 3 do c.Slots[n]:AddItem(IBL:CreateItemInstance(ctx, tape, 4)) end
dump("after 3 tapes into last slot")
c:AddSlot() local n2 = c.Slots:GetArrayNum() c.Slots[n2]:AddItem(IBL:CreateItemInstance(ctx, tape, 4)) dump("after 2nd slot")
return "ok"

