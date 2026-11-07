-- The car screen parts (own and twin): widget components' Space / visibility / RT, and every mesh material's texture
-- params (component#slot.param=texture class:name).
local T = _G.CoopPlayers.twinModule()
local own = T.ownCar()
local SMC = StaticFindObject("/Script/Engine.PrimitiveComponent")
local WC = StaticFindObject("/Script/UMG.WidgetComponent")
local o = {}
for _, cls in ipairs({ "BP_CarPart_Internal_LimBox_C", "BP_CarPart_Internal_StatusBox_C", "BP_PlayerCar_Computer_C" }) do
    for _, a in ipairs(FindAllOf(cls) or {}) do
        local p = a:GetAttachParentActor()
        local tag = (p and p:IsValid()) and ((own and p:GetAddress() == own:GetAddress()) and "OWN" or (T.isTwin(p) and "TWIN" or "x")) or "x"
        o[#o + 1] = tag .. " " .. cls
        local ws = a:K2_GetComponentsByClass(WC)
        for i = 1, #ws do
            local w = ws[i]:get()
            local ok, s = pcall(function() return string.format("space=%s vis=%s draw=%s tick=%s", tostring(w.Space), tostring(w:IsVisible()), tostring(w.bDrawAtDesiredSize), tostring(w:IsComponentTickEnabled())) end)
            o[#o + 1] = "   W " .. w:GetFName():ToString() .. " " .. tostring(s)
        end
        local cs = a:K2_GetComponentsByClass(SMC)
        for i = 1, #cs do
            local c = cs[i]:get()
            for mi = 0, c:GetNumMaterials() - 1 do
                local m = c:GetMaterial(mi)
                pcall(function()
                    for k = 1, #m.TextureParameterValues do
                        local x = m.TextureParameterValues[k]
                        local tex = x.ParameterValue
                        o[#o + 1] = "   " .. c:GetFName():ToString() .. "#" .. mi .. "(" .. m:GetClass():GetFName():ToString() .. ")." .. x.ParameterInfo.Name:ToString() .. "="
                            .. ((tex and tex:IsValid()) and (tex:GetClass():GetFName():ToString() .. ":" .. tex:GetFName():ToString()) or "-")
                    end
                end)
            end
        end
    end
end
return table.concat(o, "\n")
