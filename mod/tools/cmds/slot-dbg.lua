local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local IBL = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
local p
for _, x in ipairs(FindAllOf("BP_TemplatePart_TrunkContents_C") or {}) do if KSL:IsValid(x) and x:GetFullName():find(":PersistentLevel%.") then p = x break end end
local c
for _, x in ipairs(FindAllOf("ItemContainer") or {}) do if x:IsValid() and x:GetOuter():IsValid() and x:GetOuter():GetFullName() == p.ItemInstance:GetFullName() then c = x end end
Dev.out("before slots", c.Slots:GetArrayNum(), "NewSlotCapacity", c.NewSlotCapacity, "MaxForce", c.NewSlotMaxForceCapacity)
local ok, err = pcall(function() c:SetNumSlots(3) end)
Dev.out("SetNumSlots(3) ok", ok, tostring(err), "slots now", c.Slots:GetArrayNum())
if c.Slots:GetArrayNum() == 0 then
  local ok2, err2 = pcall(function() c:SetNewSlotParameters(1, 1, nil, false) c:SetNumSlots(3) end)
  Dev.out("with params ok", ok2, tostring(err2), "slots now", c.Slots:GetArrayNum(), "cap", c.NewSlotCapacity)
end
if c.Slots:GetArrayNum() > 0 then
  local arch = StaticFindObject("/Game/Gameplay/Inventory/Items/Resources/Raw/IA_Resource_Raw_Tape.IA_Resource_Raw_Tape")
  Dev.out("arch", Dev.name(arch))
  local inst = IBL:CreateItemInstance(FindFirstOf("PlayerController"), arch, 4)
  Dev.out("inst", Dev.name(inst))
  local ok3, e3 = pcall(function() c.Slots[1]:AddItem(inst) end)
  Dev.out("add ok", ok3, tostring(e3), "slot1 items", c.Slots[1].Items:GetArrayNum())
end
return "ok"
