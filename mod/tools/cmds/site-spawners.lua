-- Site spawners of the zone (ABaseSiteSpawnerActor and subclasses) and the building frames: for every frame the
-- nearest spawner (distance), so we see which spawner placed which building / train car.
local Base = StaticFindObject("/Script/PenDriverPro.BaseSiteSpawnerActor")
local spawners, frames = {}, {}
for _, a in ipairs(FindAllOf("Actor") or {}) do
    if CoopSyncUsable(a) and a:GetFullName():find(":PersistentLevel.", 1, true) then
        local c = a:GetClass():GetFName():ToString()
        if Base and a:IsA(Base) then
            local l = a:K2_GetActorLocation()
            local okP, pa = pcall(function() return a.PrefabAsset end)
            local okO, ov = pcall(function() return a.SpecificVariantOverride end)
            spawners[#spawners + 1] = { a = a, c = c, n = a:GetFName():ToString(), l = l,
                prefab = (okP and pa and pa:IsValid()) and pa:GetFName():ToString() or "-",
                ov = (okO and ov and ov.IsValid and ov:IsValid()) and ov:GetFName():ToString() or "-" }
        elseif c:find("^BP_BuildingFrame_") then
            frames[#frames + 1] = { c = c, n = a:GetFName():ToString(), l = a:K2_GetActorLocation() }
        end
    end
end
local out = { string.format("spawners=%d frames=%d", #spawners, #frames) }
local byClass = {}
for _, s in ipairs(spawners) do byClass[s.c] = (byClass[s.c] or 0) + 1 end
for c, k in pairs(byClass) do out[#out + 1] = string.format("  spawner class %s x%d", c, k) end
for _, f in ipairs(frames) do
    local best, bd
    for _, s in ipairs(spawners) do
        local d = math.sqrt((f.l.X - s.l.X) ^ 2 + (f.l.Y - s.l.Y) ^ 2)
        if not bd or d < bd then best, bd = s, d end
    end
    out[#out + 1] = string.format("frame %s %s at %.0f,%.0f <- %s %s d=%.0f prefab=%s ov=%s", f.c, f.n, f.l.X, f.l.Y,
        best and best.c or "-", best and best.n or "-", bd or -1, best and best.prefab or "-", best and best.ov or "-")
end
return table.concat(out, "\n")
