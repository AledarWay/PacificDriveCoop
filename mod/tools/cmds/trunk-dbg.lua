local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local n = 0
for _, p in ipairs(FindAllOf("BP_TemplatePart_TrunkContents_C") or {}) do
  if KSL:IsValid(p) and p:GetFullName():find(":PersistentLevel%.") then
    n = n + 1
    if n <= 3 then
      local inst = p.ItemInstance
      local cs = {}
      for _, c in ipairs(FindAllOf("ItemContainer") or {}) do
        if c:IsValid() and c:GetOuter():IsValid() and c:GetOuter():GetFullName() == inst:GetFullName() then
          local items = 0 local nulls = 0
          for si = 1, c.Slots:GetArrayNum() do local s = c.Slots[si] if s and s:IsValid() then items = items + s.Items:GetArrayNum() else nulls = nulls + 1 end end
          cs[#cs+1] = string.format("%s valid=%s slots=%d nullslots=%d items=%d", c:GetFName():ToString(), tostring(KSL:IsValid(c)), c.Slots:GetArrayNum(), nulls, items)
        end
      end
      Dev.out(p:GetFName():ToString(), "inst", inst:GetFName():ToString(), "empty", tostring(p.ContainerEmpty), table.concat(cs, " | "))
    end
  end
end
return n
