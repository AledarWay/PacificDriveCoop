-- Are mirror materials shared between the cars (the twin's mirror fix rewrote the own car's: item 34)? Per car the
-- interior's / doors' mirror material: its address and its outer.
local out = {}
for _, car in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
    local r = car:IsValid() and car.RootComponent
    if r and r:IsValid() then
        local l = {}
        local function add(mesh, tag)
            for mi = 0, mesh:GetNumMaterials() - 1 do
                pcall(function()
                    local mat = mesh:GetMaterial(mi)
                    for k = 1, #mat.TextureParameterValues do
                        if mat.TextureParameterValues[k].ParameterInfo.Name:ToString() == "RearviewMirrorRT" then
                            local o = mat:GetOuter()
                            l[#l + 1] = string.format("%s%d=%X(%s/%s)", tag, mi, mat:GetAddress(), mat:GetClass():GetFName():ToString(), o and o:GetFName():ToString() or "-")
                        end
                    end
                end)
            end
        end
        pcall(add, car.Interior, "I")
        for _, d in ipairs(FindAllOf("BP_CarPart_Door_Base_C") or {}) do
            local p = d:IsValid() and d:GetAttachParentActor()
            if p and p:IsValid() and p:GetAddress() == car:GetAddress() then pcall(add, d.MainMesh, "D") end
        end
        out[#out + 1] = car:GetFName():ToString() .. ": " .. table.concat(l, " ")
    end
end
return table.concat(out, " | ")
