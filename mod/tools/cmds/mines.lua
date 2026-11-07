local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local by = {}
for _, a in ipairs(FindAllOf("BP_Hazard_Landmine_C") or {}) do
  if KSL:IsValid(a) and a:GetFullName():find(":PersistentLevel%.") then
    local o = a:GetOwner(); local i = a:GetInstigator(); local p = a:GetAttachParentActor()
    local k = string.format("owner=%s instigator=%s parent=%s runtime=%s",
      (o and o:IsValid()) and o:GetClass():GetFName():ToString() or "-",
      (i and i:IsValid()) and i:GetClass():GetFName():ToString() or "-",
      (p and p:IsValid()) and p:GetClass():GetFName():ToString() or "-",
      tostring((tonumber(a:GetFName():ToString():match("_(%d+)$") or "0") or 0) > 2000000000))
    by[k] = (by[k] or 0) + 1
  end
end
for k, v in pairs(by) do Dev.out(v, k) end
return "ok"
