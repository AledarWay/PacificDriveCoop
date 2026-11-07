local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local function arch(i) if not (i and i:IsValid()) then return "-" end local a = i.Archetype return (a and a:IsValid()) and a:GetFName():ToString() or "?" end
local shown, total, parts = 0, 0, 0
for _, a in ipairs(FindAllOf("LootableTemplate") or {}) do
  if KSL:IsValid(a) and a:GetFullName():find(":PersistentLevel%.") then
    total = total + 1
    local t = {}
    for _, p in ipairs(FindAllOf("LootableTemplatePart") or {}) do
      if KSL:IsValid(p) and p:GetAttachParentActor() and p:GetAttachParentActor():IsValid() and p:GetAttachParentActor():GetFullName() == a:GetFullName() then
        t[#t+1] = p.MySocket:ToString() .. "=" .. p:GetClass():GetFName():ToString():gsub("^BP_TemplatePart_", "") .. "/" .. arch(p.ItemInstance)
      end
    end
    parts = parts + #t
    if shown < 3 then shown = shown + 1 Dev.out(a:GetClass():GetFName():ToString(), a:GetFName():ToString(), "parts", #t) for _, s in ipairs(t) do Dev.out("   ", s) end
      local extra = {} for i = 1, a.ExtraItems:GetArrayNum() do extra[#extra+1] = arch(a.ExtraItems[i]) end Dev.out("   extra", table.concat(extra, ","))
    end
  end
end
Dev.out("templates", total, "parts", parts)
return "ok"
