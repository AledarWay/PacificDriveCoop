-- A car of the level with no root component (a twin whose K2_DestroyActor did not take: startflow late join, the
-- "third car at 0,0,0"): what it is, and whether destroying it again works. SHELL_KILL = true tries it.
local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local out = {}
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
    if c:IsValid() then
        local root = c.RootComponent
        local hasRoot = root ~= nil and root:IsValid()
        local l = c:K2_GetActorLocation()
        local info = string.format("%s root=%s at=%.0f,%.0f,%.0f kslValid=%s destroying=%s begun=%s hidden=%s",
            c:GetFName():ToString(), tostring(hasRoot), l.X, l.Y, l.Z, tostring(KSL:IsValid(c)),
            tostring(c:IsActorBeingDestroyed()), "?", tostring(c.bHidden))
        pcall(function() info = info .. " canBeDamaged=" .. tostring(c.bCanBeDamaged) .. " lifespan=" .. tostring(c.InitialLifeSpan) end)
        if not hasRoot and SHELL_KILL then
            local ok, r = pcall(function() return c:K2_DestroyActor() end)
            info = info .. string.format(" | destroy again: ok=%s r=%s destroying=%s kslValid=%s", tostring(ok), tostring(r), tostring(c:IsActorBeingDestroyed()), tostring(KSL:IsValid(c)))
        end
        out[#out + 1] = info
    end
end
return table.concat(out, " || ")
