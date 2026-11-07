local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local IBL = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
local ctx = FindFirstOf("PlayerController")
local a
for _, x in ipairs(FindAllOf("BP_Lootable_Base_C") or {}) do if KSL:IsValid(x) and x:GetFullName():find(":PersistentLevel%.") and x.InventoryContainer.Slots:GetArrayNum() > 0 then a = x break end end
local c = a.InventoryContainer
local function dump(tag) local t = {} for si = 1, c.Slots:GetArrayNum() do local s = c.Slots[si] t[#t+1] = (s and s:IsValid()) and string.format("%s[%d,%d]%s n=%d", s.Items[1] and s.Items[1].Archetype:GetFName():ToString():gsub("IA_Resource_Raw_","") or "-", s.Location.X, s.Location.Y, s.bRotated and "R" or "", s.Items:GetArrayNum()) or "nil" end Dev.out(tag, c.Slots:GetArrayNum(), table.concat(t, " | ")) end
dump("start")
c:RemoveAllItems()
local tape = StaticFindObject("/Game/Gameplay/Inventory/Items/Resources/Basic/RawTape/IA_Resource_Raw_Tape.IA_Resource_Raw_Tape")
c:AddItem(IBL:CreateItemInstance(ctx, tape, 4), true) dump("1 tape")
c:AddItem(IBL:CreateItemInstance(ctx, tape, 4), true) dump("2 tapes")
local s1 = c.Slots[1]
local ok, e = pcall(function() s1:SnapLocation({X = 2, Y = 1}) end) Dev.out("snap", ok, tostring(e)) dump("after snap")
s1.bRotated = true dump("after rotate flag")
return "ok"

