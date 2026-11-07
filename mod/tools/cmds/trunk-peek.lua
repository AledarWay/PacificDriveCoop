local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local tc
for _, p in ipairs(FindAllOf("BP_TemplatePart_TrunkContents_C") or {}) do if KSL:IsValid(p) and p:GetFullName():find(":PersistentLevel%.") then tc = p break end end
local inst = tc.ItemInstance
Dev.out("trunk part", tc:GetFName():ToString(), "inst", Dev.name(inst), "ctx", inst.CreateContext, "ContainerEmpty", tc.ContainerEmpty)
local comp = inst:GetInstanceComponent()
Dev.out("instance component", Dev.name(comp))
-- look for any UItemContainer whose outer chain includes this instance
local n = 0
for _, c in ipairs(FindAllOf("ItemContainer") or {}) do
  local o = c:GetOuter()
  local guard = 0
  while o and o:IsValid() and guard < 6 do
    if o:GetFullName() == inst:GetFullName() or o:GetFullName() == tc:GetFullName() then
      n = n + 1
      local t = {}
      for si = 1, c.Slots:GetArrayNum() do local s = c.Slots[si] for ii = 1, s.Items:GetArrayNum() do local a = s.Items[ii].Archetype t[#t+1] = si .. ":" .. a:GetFName():ToString() end end
      Dev.out("container", c:GetFullName(), table.concat(t, " "))
      break
    end
    o = o:GetOuter() guard = guard + 1
  end
end
Dev.out("containers found", n)
-- create context of an item inside a crate
for _, a in ipairs(FindAllOf("BP_Lootable_Crate_Junk_C") or {}) do
  local c = a.InventoryContainer
  if c and c:IsValid() and c.Slots:GetArrayNum() > 0 and c.Slots[1].Items:GetArrayNum() > 0 then Dev.out("crate item ctx", c.Slots[1].Items[1].CreateContext, "outer", c.Slots[1].Items[1]:GetOuter():GetFullName()) break end
end
return "ok"
