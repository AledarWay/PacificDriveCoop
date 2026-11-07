-- headlights: the car manager's light / ignition members, and every light component of each car (car + attached
-- part actors): owner class, name, visible, intensity. LIGHTS_SET = true/false first calls the manager's toggle.
local o = {}
local man = FindFirstOf("BP_CarManager_C")
local function members(cls, pat)
    local t = {}
    local g = 0
    while cls and cls:IsValid() and g < 4 do
        pcall(function() cls:ForEachFunction(function(f) local n = f:GetFName():ToString() if n:lower():find(pat) then t[#t + 1] = "f:" .. n end end) end)
        pcall(function() cls:ForEachProperty(function(p) local n = p:GetFName():ToString() if n:lower():find(pat) then t[#t + 1] = "p:" .. n end end) end)
        local ok, s = pcall(function() return cls:GetSuperStruct() end)
        if not ok or not s or not s:IsValid() or s:GetFName():ToString() == "Actor" then break end
        cls, g = s, g + 1
    end
    return table.concat(t, " ")
end
if man then
    o[#o + 1] = "manager light: " .. members(man:GetClass(), "light")
    o[#o + 1] = "manager ignit/engine: " .. members(man:GetClass(), "ignit") .. " " .. members(man:GetClass(), "engine")
    pcall(function() o[#o + 1] = "CarLightsOn=" .. tostring(man.CarLightsOn) .. " CarIgnitionState=" .. tostring(man.CarIgnitionState) end)
end
local LC = StaticFindObject("/Script/Engine.LightComponent")
local own = _G.CoopPlayers and _G.CoopPlayers.ownCarActor() or nil
for _, car in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
    if car:IsValid() and car:GetFullName():find(":PersistentLevel.", 1, true) then
        local tag = (own and car:GetAddress() == own:GetAddress()) and "OWN" or "OTHER"
        o[#o + 1] = "== " .. tag .. " " .. car:GetFName():ToString() .. " car light members: " .. members(car:GetClass(), "light")
        local actors = { car }
        pcall(function()
            local arr = {}
            car:GetAttachedActors(arr, true)
            for i = 1, #arr do actors[#actors + 1] = arr[i]:get() end
        end)
        for _, a in ipairs(actors) do
            local comps = a:K2_GetComponentsByClass(LC)
            for i = 1, #comps do
                local c = comps[i]:get()
                o[#o + 1] = string.format("  %s.%s vis=%s int=%.1f", a:GetClass():GetFName():ToString(), c:GetFName():ToString(), tostring(c:IsVisible()), c.Intensity)
            end
        end
    end
end
return table.concat(o, "\n")
