-- The car manager's light / top light / wiper state and what the game's calls do to it and to the cars' lights.
--   CTL_DO = "toggle_head" | "toggle_top" | "toggle_wipers" (the own car's ToggleHeadlights / ToggleInteriorLight /
--            ToggleWiperBlades) | "set_lights_on" | "set_lights_off" | "set_top_on" | "set_top_off" (the manager's
--            SetCarLightsOn / SetCarTopLightVariable) | nil (state only)
--   CTL_ON_TWIN = true: the manager points at the twin for the call (as while sitting in it), back to the own car after
local T = _G.CoopPlayers.twinModule()
local cm = FindFirstOf("BP_CarManager_C")
local own, twin = T.ownCar(), nil
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then twin = c end end
local LC = StaticFindObject("/Script/Engine.LightComponent")
local function lights(tag, car)
    if not car then return tag .. "_head=- " .. tag .. "_top=-" end
    local head, top = {}, "?"
    pcall(function() top = string.format("%.0f", car.Light_Top.Intensity) end)
    pcall(function()
        local arr = {}
        car:GetAttachedActors(arr, true)
        for i = 1, #arr do
            local a = arr[i]:get()
            if a:GetClass():GetFName():ToString():find("Headlight", 1, true) then
                local comps = a:K2_GetComponentsByClass(LC)
                for j = 1, #comps do head[#head + 1] = string.format("%.0f", comps[j]:get().Intensity) end
            end
        end
    end)
    return tag .. "_head=" .. table.concat(head, "/") .. " " .. tag .. "_top=" .. top
end
local function state()
    local l, tl, w, r = {}, {}, {}, {}
    pcall(function() cm:GetCarLightsOn(l) end)
    pcall(function() cm:GetCarTopLightVariable(tl) end)
    pcall(function() cm:GetWipersOnOffVariable(w) end)
    pcall(function() cm:GetCarRadioOnOffState(r) end)
    return string.format("lights=%s top=%s wipers=%s radio=%s %s %s", tostring(l.AreCarLightsOn), tostring(tl.CarTopLightOnOff),
        tostring(w.WipersOn), tostring(r.CarState_Radio), lights("own", own), lights("twin", twin))
end
local o = { "before: " .. state() }
if CTL_DO then
    local car = own
    if CTL_ON_TWIN and twin then cm.NewCarActor = twin car = twin end
    local ok, e = pcall(function()
        if CTL_DO == "toggle_head" then car:ToggleHeadlights()
        elseif CTL_DO == "toggle_top" then car:ToggleInteriorLight()
        elseif CTL_DO == "toggle_wipers" then car:ToggleWiperBlades()
        elseif CTL_DO == "set_lights_on" then cm:SetCarLightsOn(true)
        elseif CTL_DO == "set_lights_off" then cm:SetCarLightsOn(false)
        elseif CTL_DO == "set_top_on" then cm:SetCarTopLightVariable(true)
        elseif CTL_DO == "set_top_off" then cm:SetCarTopLightVariable(false) end
    end)
    o[#o + 1] = CTL_DO .. (CTL_ON_TWIN and " (manager on twin)" or "") .. ": " .. tostring(ok) .. (ok and "" or (" " .. tostring(e)))
    o[#o + 1] = "right after: " .. state()
    if CTL_ON_TWIN then T.managerToOwn() end
end
CTL_DO, CTL_ON_TWIN = nil, nil
return table.concat(o, "\n")
