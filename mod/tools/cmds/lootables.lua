local n = 0
for _, a in ipairs(FindAllOf("LootableTemplate") or {}) do
  n = n + 1
  if n <= 12 then
    local p = a:GetAttachParentActor()
    Dev.out(a:GetFullName(), "parent", (p and p:IsValid()) and p:GetFName():ToString() or "-", Dev.vec(a:K2_GetActorLocation()))
  end
end
local pools = 0
for _, a in ipairs(FindAllOf("PooledActor") or {}) do pools = pools + 1 end
Dev.out("LootableTemplate", n, "PooledActor", pools)
return "ok"
