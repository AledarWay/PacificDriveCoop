-- For actors of PROBE_CLASS (default traffic cones): attach chain (class names up to the top) and whether
-- spawnsync counts them as replicated roots. Shows which prop sits on which parent.
local cls = PROBE_CLASS or "BP_Destruct_Traffic_Cone_C"
local roots = {}
for _, a in ipairs(CoopSync.collect()) do roots[a:GetFullName()] = true end
local out, n, nonRoot = {}, 0, 0
for _, a in ipairs(FindAllOf(cls) or {}) do
    if CoopSyncUsable(a) and a:GetFullName():find(":PersistentLevel.", 1, true) then
        n = n + 1
        local chain, p, guard = {}, CoopSyncParentOf(a), 0
        while p and guard < 8 do
            chain[#chain + 1] = p:GetClass():GetFName():ToString()
            p = CoopSyncParentOf(p)
            guard = guard + 1
        end
        local root = roots[a:GetFullName()] == true
        if not root then nonRoot = nonRoot + 1 end
        local l = a:K2_GetActorLocation()
        if #out < 40 then
            out[#out + 1] = string.format("%s %.0f,%.0f root=%s <- %s", a:GetFName():ToString(), l.X, l.Y, tostring(root), table.concat(chain, " <- "))
        end
    end
end
return string.format("%s n=%d nonRoot=%d\n", cls, n, nonRoot) .. table.concat(out, "\n")
