-- The visible meshes of the player car (its own components + those of every actor attached under it): mesh
-- asset, component class, transform relative to the car. MESHES_OUT = file to write "kind|mesh|x|y|z|p|y|r|sx|sy|sz".
CoopSync = CoopSync or dofile("C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua")
local car
for _, x in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
    if CoopSyncUsable(x) and x:GetFullName():find(":PersistentLevel.", 1, true) then car = x break end
end
if not car then return "no car" end
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local carXf = car:GetTransform()
local SMC = StaticFindObject("/Script/Engine.StaticMeshComponent")
local SKC = StaticFindObject("/Script/Engine.SkeletalMeshComponent")
local actors = { car }
for _, a in ipairs(FindAllOf("Actor") or {}) do
    if CoopSyncUsable(a) then
        local cur, g = CoopSync.parentOf(a), 0
        while cur and g < 8 do
            if cur:GetFullName() == car:GetFullName() then actors[#actors + 1] = a break end
            cur = CoopSync.parentOf(cur)
            g = g + 1
        end
    end
end
local out, counts = {}, { static = 0, skeletal = 0, hidden = 0, nomesh = 0 }
for _, a in ipairs(actors) do
    for kind, cls in pairs({ static = SMC, skeletal = SKC }) do
        local ok, comps = pcall(function() return a:K2_GetComponentsByClass(cls) end)
        if ok and comps then
            for i = 1, #comps do
                local c = comps[i]:get() -- TArray elements are wrapped
                local okM, mesh = pcall(function() return kind == "static" and c.StaticMesh or c.SkeletalMesh end)
                local okV, vis = pcall(function() return c:IsVisible() end)
                if not (okM and mesh and mesh:IsValid()) then counts.nomesh = counts.nomesh + 1
                elseif okV and not vis then counts.hidden = counts.hidden + 1
                else
                    counts[kind] = counts[kind] + 1
                    local w = c:K2_GetComponentToWorld()
                    local rel = KML:ComposeTransforms(w, KML:InvertTransform(carXf))
                    local l, r, s = rel.Translation, KML:Quat_Rotator(rel.Rotation), rel.Scale3D
                    out[#out + 1] = string.format("%s|%s|%.2f|%.2f|%.2f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f", kind,
                        mesh:GetFullName():gsub("^%S+ ", ""), l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll, s.X, s.Y, s.Z)
                end
            end
        end
    end
end
if MESHES_OUT then local f = io.open(MESHES_OUT, "wb") f:write(table.concat(out, "\n")) f:close() end
return string.format("actors=%d static=%d skeletal=%d hidden=%d nomesh=%d", #actors, counts.static, counts.skeletal, counts.hidden, counts.nomesh)
