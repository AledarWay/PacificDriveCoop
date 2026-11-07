local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local by = {}
for _, a in ipairs(FindAllOf("Actor") or {}) do
  if KSL:IsValid(a) and a:GetFullName():find(":PersistentLevel%.") then
    local c = a:GetClass():GetFName():ToString()
    if c:find("PreHazardHelper") or c:find("Generator") or c:find("Spawner") or c:find("Minefield") then by[c] = (by[c] or 0) + 1 end
  end
end
for k, v in pairs(by) do Dev.out(k, v) end
return "ok"
