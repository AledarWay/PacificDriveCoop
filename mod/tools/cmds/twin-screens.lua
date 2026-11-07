-- The screen parts of the own car and of the twin: per part class with widget components, each widget component's
-- render target (name or "-"), its widget class, and the screen meshes' texture params (name=texture).
local T = _G.CoopPlayers.twinModule()
local WC = StaticFindObject("/Script/UMG.WidgetComponent")
local SMC = StaticFindObject("/Script/Engine.StaticMeshComponent")
local own = T.ownCar()
local twin
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then twin = c end end
local function parts(car)
    local out = {}
    for _, a in ipairs(FindAllOf("BP_CarPart_Base_C") or {}) do
        local ok, p = pcall(function() return a:GetAttachParentActor() end)
        local r, g = p, 0
        while r and r:IsValid() and g < 5 do
            if r:GetAddress() == car:GetAddress() then break end
            r, g = r:GetAttachParentActor(), g + 1
        end
        if ok and r and r:IsValid() and r:GetAddress() == car:GetAddress() then
            local ws = a:K2_GetComponentsByClass(WC)
            if #ws > 0 then
                local d = {}
                for i = 1, #ws do
                    local w = ws[i]:get()
                    local rt = w:GetRenderTarget()
                    local wi = w:GetUserWidgetObject()
                    d[#d + 1] = w:GetFName():ToString() .. ":" .. ((rt and rt:IsValid()) and rt:GetFName():ToString() or "-")
                        .. ":" .. ((wi and wi:IsValid()) and wi:GetClass():GetFName():ToString() or "nowidget")
                end
                local sm = a:K2_GetComponentsByClass(SMC)
                for i = 1, #sm do
                    local c = sm[i]:get()
                    for mi = 0, c:GetNumMaterials() - 1 do
                        local m = c:GetMaterial(mi)
                        pcall(function()
                            for k = 1, #m.TextureParameterValues do
                                local x = m.TextureParameterValues[k]
                                local tex = x.ParameterValue
                                local tn = (tex and tex:IsValid()) and tex:GetFName():ToString() or "-"
                                if tn:find("Widget") or tn:find("RT") or tn == "Black" then
                                    d[#d + 1] = c:GetFName():ToString() .. "#" .. mi .. "." .. x.ParameterInfo.Name:ToString() .. "=" .. tn
                                end
                            end
                        end)
                    end
                end
                out[#out + 1] = a:GetClass():GetFName():ToString() .. " direct=" .. tostring(g == 0) .. " [" .. table.concat(d, " ") .. "]"
            end
        end
    end
    table.sort(out)
    return out
end
local o = { "OWN:" }
for _, l in ipairs(own and parts(own) or {}) do o[#o + 1] = "  " .. l end
o[#o + 1] = "TWIN:"
for _, l in ipairs(twin and parts(twin) or {}) do o[#o + 1] = "  " .. l end
return table.concat(o, "\n")
