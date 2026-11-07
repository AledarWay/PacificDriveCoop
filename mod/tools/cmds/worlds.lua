local main = FindFirstOf("DrivingGameInstance"):GetWorld():GetFullName()
local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local by = {}
for _, a in ipairs(FindAllOf("Actor") or {}) do
  if a:IsValid() and KSL:IsValid(a) and a:GetFullName():find(":PersistentLevel%.") then
    local ok, w = pcall(function() return a:GetWorld():GetFullName() end)
    local key = (ok and w == main) and "MAIN" or ("OTHER " .. (ok and w or "?"))
    by[key] = (by[key] or 0) + 1
  end
end
for k, v in pairs(by) do Dev.out(v, k) end
return "main=" .. main
