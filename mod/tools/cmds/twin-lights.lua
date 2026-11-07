-- Twin rework: lights / engine per car. Prints the car manager's CarLightsOn / CarIgnitionState and, for the own car
-- and the twin, EngineOn, the LightTargetValue_* fields and the light components (car + attached part actors: the
-- headlights are parts) that are visible with intensity > 0.
--   LT_CALL = "lights_on" | "lights_off" | "ign_on" | "ign_off" | "elec"   first call that on the TWIN
--   (Set Headlights On(on, true) / ManualSetIgnition_NoAnim(2|0) / ElectronicUpdate_All)
local T = _G.CoopPlayers.twinModule()
local own, twin = T.ownCar(), nil
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then twin = c end end
local man = FindFirstOf("BP_CarManager_C")
local o = {}
if LT_CALL and twin then
    local ok, e = pcall(function()
        if LT_CALL == "lights_on" then twin["Set Headlights On"](twin, true, true)
        elseif LT_CALL == "lights_off" then twin["Set Headlights On"](twin, false, true)
        elseif LT_CALL == "ign_on" then twin:ManualSetIgnition_NoAnim(2)
        elseif LT_CALL == "ign_off" then twin:ManualSetIgnition_NoAnim(0)
        elseif LT_CALL == "elec" then twin:ElectronicUpdate_All() end
    end)
    o[#o + 1] = "call " .. LT_CALL .. " on twin: " .. tostring(ok) .. (ok and "" or (" " .. tostring(e)))
end
o[#o + 1] = string.format("manager: CarLightsOn=%s CarIgnitionState=%s", tostring(man and man.CarLightsOn), tostring(man and man.CarIgnitionState))
local LC = StaticFindObject("/Script/Engine.LightComponent")
local function carInfo(tag, car)
    if not car then o[#o + 1] = tag .. ": none" return end
    local f = {}
    for _, n in ipairs({ "EngineOn", "LightTargetValue_TopLight", "LightTargetValue_UnderDashLight", "LightTargetValue_RearLights_Point", "LightTargetValue_RearLights_Spot" }) do
        local ok, v = pcall(function() return car[n] end)
        f[#f + 1] = n:gsub("LightTargetValue_", "LT_") .. "=" .. (ok and tostring(type(v) == "number" and string.format("%.2f", v) or v) or "?")
    end
    o[#o + 1] = tag .. ": " .. table.concat(f, " ")
    local actors = { car }
    pcall(function()
        local arr = {}
        car:GetAttachedActors(arr, true)
        for i = 1, #arr do actors[#actors + 1] = arr[i]:get() end
    end)
    local on, total = {}, 0
    for _, a in ipairs(actors) do
        local comps = a:K2_GetComponentsByClass(LC)
        for i = 1, #comps do
            local c = comps[i]:get()
            total = total + 1
            if _G.LT_ALL then on[#on + 1] = string.format("%s.%s=%s/%.0f", a:GetClass():GetFName():ToString():gsub("BP_CarPart_", ""), c:GetFName():ToString(), c:IsVisible() and "v" or "h", c.Intensity)
            elseif c:IsVisible() and c.Intensity > 0 then on[#on + 1] = string.format("%s.%s=%.0f", a:GetClass():GetFName():ToString():gsub("BP_CarPart_", ""), c:GetFName():ToString(), c.Intensity) end
        end
    end
    o[#o + 1] = string.format("  lights on %d/%d: %s", #on, total, table.concat(on, " "))
end
carInfo("OWN", own)
carInfo("TWIN", twin)
LT_CALL, LT_ALL = nil, nil
return table.concat(o, "\n")
