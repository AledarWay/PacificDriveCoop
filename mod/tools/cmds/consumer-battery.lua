-- The battery consumers (BP_BatteryConsumerComponent_C) of the own car's and the twin's parts: found a battery?
-- power? which battery (its owner: own / twin / other)? CB_FIND = true calls FindBattery on the twin's first;
-- CB_SET = true gives every twin consumer the twin's own battery (SetBattery with the twin's BP_BatteryComponent_C).
local T = _G.CoopPlayers.twinModule()
local own, twin = T.ownCar(), nil
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then twin = c end end
local CC = StaticFindObject("/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_BatteryConsumerComponent.BP_BatteryConsumerComponent_C")
local function whose(o)
    if not (o and o:IsValid()) then return "nil" end
    local a = o.GetOwner and o:GetOwner() or o
    local cur, g = a, 0
    while cur and cur:IsValid() and g < 8 do
        if own and cur:GetAddress() == own:GetAddress() then return "OWN" end
        if twin and cur:GetAddress() == twin:GetAddress() then return "TWIN" end
        cur, g = cur:GetAttachParentActor(), g + 1
    end
    return a:GetClass():GetFName():ToString()
end
local BC = StaticFindObject("/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_BatteryComponent.BP_BatteryComponent_C")
local setInfo
if CB_SET and twin and BC then
    local arr, bat = {}, nil
    twin:GetAttachedActors(arr, true)
    for i = 1, #arr do
        local cs = arr[i]:get():K2_GetComponentsByClass(BC)
        if #cs > 0 then bat = cs[1]:get() break end
    end
    local n, errs = 0, {}
    for i = 1, #arr do
        local cs = CC and arr[i]:get():K2_GetComponentsByClass(CC) or {}
        for j = 1, #cs do
            local ok, e = pcall(function() cs[j]:get():SetBattery(bat) end)
            if ok then n = n + 1 else errs[#errs + 1] = tostring(e):sub(1, 100) end
        end
    end
    setInfo = "set battery " .. (bat and bat:GetOwner():GetClass():GetFName():ToString() or "none") .. " on " .. n .. " " .. table.concat(errs, ";")
end
local function scan(tag, car)
    if not car then return tag .. ": none" end
    local arr, parts = {}, {}
    car:GetAttachedActors(arr, true)
    local found, power, n, bat = 0, 0, 0, {}
    for i = 1, #arr do
        local a = arr[i]:get()
        local comps = CC and a:K2_GetComponentsByClass(CC) or {}
        for j = 1, #comps do
            local c = comps[j]:get()
            n = n + 1
            if CB_FIND and tag == "TWIN" and n == 1 then pcall(function() c:FindBattery() end) end
            local f, p = {}, {}
            pcall(function() c:HasFoundBattery(f) end)
            pcall(function() c:HasPower(p) end)
            local fv, pv
            for _, v in pairs(f) do fv = v end
            for _, v in pairs(p) do pv = v end
            if fv then found = found + 1 end
            if pv then power = power + 1 end
            -- the battery it holds (an object field)
            c:GetClass():ForEachProperty(function(pr)
                if pr:GetClass():GetFName():ToString() == "ObjectProperty" then
                    local ok, v = pcall(function() return c[pr:GetFName():ToString()] end)
                    if ok and v and v:IsValid() then local k = pr:GetFName():ToString() .. "->" .. whose(v) bat[k] = (bat[k] or 0) + 1 end
                end
            end)
            if #parts < 4 then parts[#parts + 1] = a:GetClass():GetFName():ToString():gsub("BP_CarPart_", "") .. "(" .. tostring(fv) .. "/" .. tostring(pv) .. ")" end
        end
    end
    local b = {}
    for k, v in pairs(bat) do b[#b + 1] = k .. " x" .. v end
    return string.format("%s: consumers=%d found=%d power=%d batteries: %s | %s", tag, n, found, power, table.concat(b, ", "), table.concat(parts, " "))
end
local o = { setInfo or "", scan("OWN", own), scan("TWIN", twin) }
CB_FIND, CB_SET = nil, nil
return table.concat(o, "\n")
