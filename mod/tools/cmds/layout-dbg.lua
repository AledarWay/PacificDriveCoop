local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
for _, x in ipairs(FindAllOf("BP_TemplatePart_TrunkContents_C") or {}) do if KSL:IsValid(x) and x:GetFullName():find(":PersistentLevel%.") then
  for _, c in ipairs(FindAllOf("ItemContainer") or {}) do if c:IsValid() and c:GetOuter():IsValid() and c:GetOuter():GetFullName() == x.ItemInstance:GetFullName() then
    Dev.out("trunk container", c:GetClass():GetFName():ToString(), "slots", c.Slots:GetArrayNum(), "layout", Dev.name(c.Layout), "data", Dev.name(c.ContainerData), "rules", tostring(c.NewSlotRules))
  end end
  break
end end
local a = FindAllOf("BP_Lootable_Crate_Junk_C")[1]
local c = a.InventoryContainer
Dev.out("crate container", c:GetClass():GetFName():ToString(), "slots", c.Slots:GetArrayNum(), "layout", Dev.name(c.Layout), "NumberOfSlots", a.NumberOfSlots)
return "ok"
