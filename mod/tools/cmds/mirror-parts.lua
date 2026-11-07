-- the mirror parts of both cars (actors under a car whose class name has "Mirror"): their mesh materials and the
-- texture params; the car's MirrorMaterialInstance and capture target
local o = {}
local own = _G.CoopPlayers and _G.CoopPlayers.ownCarActor() or nil
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
local function rootOf(a)
    local cur, g = a, 0
    while g < 10 do
        local p = cur:GetAttachParentActor()
        if not (p and p:IsValid()) then return cur end
        cur, g = p, g + 1
    end
    return cur
end
local PC = StaticFindObject("/Script/Engine.PrimitiveComponent")
for _, car in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
    if car:IsValid() then
        local tag = (own and car:GetAddress() == own:GetAddress()) and "OWN" or "OTHER"
        local mmi = car.MirrorMaterialInstance
        o[#o + 1] = string.format("== %s %s capRT=%s MirrorMaterialInstance=%s [%s]", tag, car:GetFName():ToString(),
            car.ScenecaptureMirror.TextureTarget:IsValid() and car.ScenecaptureMirror.TextureTarget:GetFName():ToString() or "-",
            mmi and mmi:IsValid() and mmi:GetFName():ToString() or "nil", mmi and mmi:IsValid() and texParams(mmi) or "")
        for _, a in ipairs(FindAllOf("Actor") or {}) do
            local pc = a:IsValid() and a.RootComponent and a.RootComponent:IsValid() and a.RootComponent:GetAttachParent() local pn = pc and pc:IsValid() and pc:GetFName():ToString() or "" if a:IsValid() and (pn:find("Mirror") or a:GetClass():GetFName():ToString():find("Mirror") or a:GetClass():GetFName():ToString():find("Rearview")) and rootOf(a):GetAddress() == car:GetAddress() then
                o[#o + 1] = "  part " .. a:GetClass():GetFName():ToString() .. " under " .. pn .. " hidden=" .. tostring(a.bHidden)
                local comps = a:K2_GetComponentsByClass(PC)
                for i = 1, #comps do
                    local c = comps[i]:get()
                    for mi = 0, c:GetNumMaterials() - 1 do
                        local m = c:GetMaterial(mi)
                        o[#o + 1] = string.format("    %s[%d] vis=%s %s %s", c:GetFName():ToString(), mi, tostring(c:IsVisible()),
                            m and m:IsValid() and m:GetFName():ToString() or "nil", m and m:IsValid() and texParams(m) or "")
                    end
                end
            end
        end
    end
end
return table.concat(o, "\n")
