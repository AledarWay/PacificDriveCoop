-- front doors of both cars: every primitive's materials (name, parent) and texture params
local o = {}
local own = _G.CoopPlayers and _G.CoopPlayers.ownCarActor() or nil
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local PC = StaticFindObject("/Script/Engine.PrimitiveComponent")
local function texParams(m)
    local t = {}
    pcall(function()
        for k = 1, #m.TextureParameterValues do
            local x = m.TextureParameterValues[k]
            t[#t + 1] = x.ParameterInfo.Name:ToString() .. "=" .. (x.ParameterValue:IsValid() and x.ParameterValue:GetFName():ToString() or "nil")
        end
    end)
    return table.concat(t, ",")
end
for _, car in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
    if car:IsValid() then
        local tag = (own and car:GetAddress() == own:GetAddress()) and "OWN" or "OTHER"
        o[#o + 1] = "== " .. tag .. " capRT=" .. car.ScenecaptureMirror.TextureTarget:GetFName():ToString()
        for _, d in ipairs(FindAllOf("BP_CarPart_Door_Base_C") or {}) do
            local par = d:GetAttachParentActor()
            if d:IsValid() and par and par:IsValid() and par:GetAddress() == car:GetAddress() then
                local l = KML:InverseTransformLocation(car:GetTransform(), d:K2_GetActorLocation())
                if l.X > 70 then
                    o[#o + 1] = string.format("  door %.0f,%.0f %s", l.X, l.Y, d:GetClass():GetFName():ToString())
                    local comps = d:K2_GetComponentsByClass(PC)
                    for i = 1, #comps do
                        local c = comps[i]:get()
                        for mi = 0, c:GetNumMaterials() - 1 do
                            local m = c:GetMaterial(mi)
                            local mn = m and m:IsValid() and m:GetFName():ToString() or "nil"
                            local pn = "-"
                            pcall(function() pn = m.Parent:GetFName():ToString() end)
                            local tp = m and m:IsValid() and texParams(m) or ""
                            if mn:lower():find("mirror") or pn:lower():find("mirror") or tp:lower():find("mirror") or tp:find("RenderTarget") then
                                o[#o + 1] = string.format("    %s[%d] vis=%s %s (parent %s) %s", c:GetFName():ToString(), mi, tostring(c:IsVisible()), mn, pn, tp)
                            end
                        end
                    end
                end
            end
        end
    end
end
return table.concat(o, "\n")
