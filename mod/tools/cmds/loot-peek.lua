local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local function arch(i) if not (i and i:IsValid()) then return "-" end local a = i.Archetype return (a and a:IsValid()) and a:GetFName():ToString() or "?" end
local shown = 0
for _, a in ipairs(FindAllOf("Actor") or {}) do
  if shown < 4 and KSL:IsValid(a) and a:GetFullName():find(":PersistentLevel%.") and a:GetClass():GetFName():ToString():find("^BP_Lootable_") then
    shown = shown + 1
    Dev.out("LOOTABLE", a:GetFName():ToString(), a:GetClass():GetFName():ToString())
    local comps = a:K2_GetComponentsByClass(StaticFindObject("/Script/PenDriverInventory.ItemContainerComponent"))
    local list = {}
    if type(comps) == "table" then list = comps else for ci = 1, comps:GetArrayNum() do list[#list+1] = comps[ci] end end
    Dev.out("  comps", #list)
    for _, c in ipairs(list) do
      if type(c) == "userdata" and c.get then c = c:get() end
      local cont = c.Container
      Dev.out("  comp", c:GetFName():ToString(), "NumSlots", c.NumSlots, "container", Dev.name(cont))
      if cont and cont:IsValid() then
        for si = 1, cont.Slots:GetArrayNum() do
          local s = cont.Slots[si]
          local t = {}
          for ii = 1, s.Items:GetArrayNum() do t[#t+1] = arch(s.Items[ii]) end
          if #t > 0 then Dev.out("    slot", si, s.SlotName:ToString(), table.concat(t, ",")) end
        end
      end
    end
  end
end
return "ok"

