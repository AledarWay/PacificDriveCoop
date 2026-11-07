local byc, total, roots = {}, 0, 0
for _, a in ipairs(FindAllOf("Actor") or {}) do
  if a:IsValid() then
    local nm = a:GetFName():ToString()
    local idx = tonumber(nm:match("_(%d+)$") or "0")
    if idx and idx > 2000000000 then
      total = total + 1
      local c = a:GetClass():GetFName():ToString()
      local e = byc[c] or {n=0, attached=0, owned=0, child=0}
      e.n = e.n + 1
      local ok, p = pcall(function() return a:GetAttachParentActor() end)
      if ok and p and p:IsValid() then e.attached = e.attached + 1 end
      local ok2, o = pcall(function() return a:GetOwner() end)
      if ok2 and o and o:IsValid() then e.owned = e.owned + 1 end
      local ok3, pc = pcall(function() return a:GetParentActor() end)
      if ok3 and pc and pc:IsValid() then e.child = e.child + 1 end
      byc[c] = e
    end
  end
end
local keys = {} for k in pairs(byc) do keys[#keys+1] = k end table.sort(keys, function(x,y) return byc[x].n > byc[y].n end)
Dev.out("runtime actors", total, "classes", #keys)
for i = 1, math.min(70, #keys) do local e = byc[keys[i]] Dev.out(keys[i], e.n, "attached", e.attached, "owned", e.owned, "childactor", e.child) end
return "ok"
