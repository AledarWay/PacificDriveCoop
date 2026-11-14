-- The abandoned cars' body materials on this side (owner's two-games test 2026-11-14: on the guest a wreck's body was
-- a grey checker - the engine's default material - while its parts' paint was right). Per wreck: the body mesh's
-- materials (name, a dynamic one's parent), flagged when it is the default / world grid material or none.
--   WM_MAX = n   (default 200) wrecks listed at most; returns "wrecks=<n> default=<n> no_mid=<n>" + the flagged ones
local max = WM_MAX or 200
WM_MAX = nil
local function nm(o)
    if not (o and o:IsValid()) then return "nil" end
    return o:GetFName():ToString()
end
local function bad(name) return name == "nil" or name:find("WorldGridMaterial", 1, true) or name:find("DefaultMaterial", 1, true) end
local n, def, noMid, out = 0, 0, 0, {}
for _, c in ipairs(FindAllOf("BP_Template_BaseVehicle_C") or {}) do
    if n >= max then break end
    if c:IsValid() and c:GetFullName():find(":PersistentLevel.", 1, true) then
        local l = c:K2_GetActorLocation()
        if math.abs(l.X) + math.abs(l.Y) > 1000 then
            n = n + 1
            local mesh = c.RootComponent
            pcall(function() if not mesh:IsA(StaticFindObject("/Script/Engine.MeshComponent")) then mesh = c:GetComponentByClass(StaticFindObject("/Script/Engine.StaticMeshComponent")) end end)
            local mats, flagged = {}, false
            pcall(function()
                for i = 0, mesh:GetNumMaterials() - 1 do
                    local m = mesh:GetMaterial(i)
                    local s = nm(m)
                    pcall(function() if m.Parent then s = s .. "<" .. nm(m.Parent) end end)
                    if bad(s) or s:find("<nil", 1, true) then flagged = true end
                    mats[#mats + 1] = s
                end
            end)
            local mids = 0
            pcall(function() mids = #c.DynamicMaterialInstances end)
            if mids == 0 then noMid = noMid + 1 end
            if flagged then
                def = def + 1
                if #out < 8 then out[#out + 1] = string.format("%s at %.0f,%.0f mids=%d [%s]", c:GetFName():ToString(), l.X, l.Y, mids, table.concat(mats, ", ")) end
            end
        end
    end
end
return string.format("wrecks=%d default=%d no_mid=%d", n, def, noMid) .. (#out > 0 and ("\n" .. table.concat(out, "\n")) or "")
