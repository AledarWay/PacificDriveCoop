local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local function arch(i) if not (i and i:IsValid()) then return "-" end local a = i.Archetype return (a and a:IsValid()) and a:GetFName():ToString() or "?" end
local stats = {n=0, populated=0, withItems=0, items=0, rolledOnOpen=0, hasOnOpenTree=0}
local shown = 0
for _, a in ipairs(FindAllOf("Actor") or {}) do
  if KSL:IsValid(a) and a:GetFullName():find(":PersistentLevel%.") and a:GetClass():GetFName():ToString():find("^BP_Lootable_") then
    stats.n = stats.n + 1
    local ok, cont = pcall(function() return a.InventoryContainer end)
    local pop = false pcall(function() pop = a["Container Populated"] end)
    if pop then stats.populated = stats.populated + 1 end
    if a.RolledOnOpenItems then stats.rolledOnOpen = stats.rolledOnOpen + 1 end
    local tree = a.OnOpenItemsDecisionTree
    if tree and tree:IsValid() then stats.hasOnOpenTree = stats.hasOnOpenTree + 1 end
    local t = {}
    if ok and cont and cont:IsValid() then
      for si = 1, cont.Slots:GetArrayNum() do
        local s = cont.Slots[si]
        for ii = 1, s.Items:GetArrayNum() do t[#t+1] = si .. ":" .. arch(s.Items[ii]) end
      end
    end
    if #t > 0 then stats.withItems = stats.withItems + 1 stats.items = stats.items + #t end
    if shown < 8 then shown = shown + 1 Dev.out(a:GetClass():GetFName():ToString(), "populated", tostring(pop), "slots", (ok and cont and cont:IsValid()) and cont.Slots:GetArrayNum() or -1, table.concat(t, " ")) end
  end
end
for k, v in pairs(stats) do Dev.out(k, v) end
return "ok"
