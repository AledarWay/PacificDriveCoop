-- Physics props (DIAG_CLASS, default traffic cones): location, speed, which components simulate physics,
-- and on a client the sync record (host key, host transform held). Run on both sides when a score misses.
local cls = DIAG_CLASS or "BP_Destruct_Traffic_Cone_C"
local out = {}
for _, a in ipairs(FindAllOf(cls) or {}) do
    if CoopSyncUsable(a) and a:GetFullName():find(":PersistentLevel%.") then
        local l, v = a:K2_GetActorLocation(), a:GetVelocity()
        local sim = {}
        pcall(function()
            local comps = a:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent"))
            for i = 1, #comps do
                local c = comps[i]
                if c:IsSimulatingPhysics() then sim[#sim + 1] = c:GetFName():ToString() end
            end
        end)
        local rec = ""
        if CoopSyncState and CoopSyncState.debugActor then
            local ok, s = pcall(CoopSyncState.debugActor, a)
            rec = " " .. (ok and s or "?")
        end
        out[#out + 1] = string.format("%s@%.1f,%.1f,%.1f v=%.1f sim=[%s]%s", a:GetFName():ToString(), l.X, l.Y, l.Z,
            math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z), table.concat(sim, ","), rec)
    end
end
table.sort(out)
return table.concat(out, "\n")
