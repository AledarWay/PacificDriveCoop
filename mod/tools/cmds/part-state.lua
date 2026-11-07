-- Twin rework stage B probe: a car's parts' health / fuel / battery through the parts' own components
-- (BP_HealthComponent_C HC_GetHealth / SetHealth, BP_FuelableComponent_C GetFuelStatus / Set Fuel,
-- BP_BatteryComponent_C GetBatteryStatus / Set Battery).
--   STATE_CAR = 'own' | 'twin'          which car (default own)
--   STATE_SLOTS = { ... }                which slots (default: all non-empty)
--   STATE_SET = { slot = '..', health = n, fuel = n, battery = n }   write one part first
local T = _G.CoopPlayers and _G.CoopPlayers.twinModule()
local cont
if STATE_CAR == 'twin' then
    for _, c in ipairs(FindAllOf('BP_PlayerCarNew_C') or {}) do
        if c:IsValid() and T and T.isTwin(c) then cont = T.twinContainer(c) end
    end
else
    cont = FindFirstOf('BP_InventoryManager_C').Inventory_CarEquipped
end
if not cont then return 'no container' end
local function cls(p) return StaticFindObject(p) end
local HC = cls('/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_HealthComponent.BP_HealthComponent_C')
local FC = cls('/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_FuelableComponent.BP_FuelableComponent_C')
local BC = cls('/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_BatteryComponent.BP_BatteryComponent_C')
local function comps(it)
    local a = it:GetActorManifestation()
    if not (a and a:IsValid()) then return nil end
    local function get(c, base)
        if c and c:IsValid() then local x = a:GetComponentByClass(c) if x and x:IsValid() then return x end end
        if base then local x = a:GetComponentByClass(cls(base)) if x and x:IsValid() then return x end end
    end
    return a, get(HC, '/Script/PenDriverInventory.HealthComponentBase'), get(FC), get(BC)
end
local function outs(obj, fn, ...)
    local ts = { ... }
    obj[fn](obj, table.unpack(ts))
    local r = {}
    for _, t in ipairs(ts) do for k, v in pairs(t) do r[k] = v end end
    return r
end
local function state(it)
    local a, hc, fc, bc = comps(it)
    if not a then return 'no actor' end
    local s = a:GetClass():GetFName():ToString()
    if hc then s = s .. string.format(' h=%.1f/%.1f', hc:HC_GetHealth(), hc:HC_GetMaxHealth()) end
    if fc then
        local ok, r = pcall(outs, fc, 'GetFuelStatus', {}, {}, {}, {}, {}, {}, {})
        s = s .. (ok and string.format(' f=%s/%s', tostring(r.Fuel), tostring(r['Fuel Capacity'])) or (' f=ERR ' .. tostring(r)))
    end
    if bc then
        local ok, r = pcall(outs, bc, 'GetBatteryStatus', {}, {}, {}, {}, {})
        s = s .. (ok and string.format(' b=%s/%s', tostring(r.BATTERY), tostring(r['Battery Capacity'])) or (' b=ERR ' .. tostring(r)))
    end
    return s
end
local o = {}
if STATE_SET then
    local sl = cont:GetSlot(FName(STATE_SET.slot))
    local it = sl and sl.Items:GetArrayNum() > 0 and sl.Items[1]
    if not it then return 'set: empty slot ' .. STATE_SET.slot end
    local a, hc, fc, bc = comps(it)
    o[#o + 1] = 'before ' .. state(it)
    if STATE_SET.health and hc then o[#o + 1] = 'SetHealth ' .. tostring(pcall(function() hc:SetHealth(STATE_SET.health) end)) end
    if STATE_SET.fuel and fc then o[#o + 1] = 'Set Fuel ' .. tostring(pcall(function() fc['Set Fuel'](fc, STATE_SET.fuel) end)) end
    if STATE_SET.battery and bc then o[#o + 1] = 'Set Battery ' .. tostring(pcall(function() bc['Set Battery'](bc, STATE_SET.battery) end)) end
    o[#o + 1] = 'after  ' .. state(it)
end
local names = {}
cont:GetSlotNames(names)
for i = 1, #names do
    local n = names[i]:get():ToString()
    local pick = not STATE_SLOTS
    if STATE_SLOTS then for _, w in ipairs(STATE_SLOTS) do if n:find(w, 1, true) then pick = true end end end
    local sl = cont:GetSlot(FName(n))
    if pick and sl and sl:IsValid() and sl.Items:GetArrayNum() > 0 then
        local it = sl.Items[1]
        local ok, s = pcall(state, it)
        o[#o + 1] = n .. ' ' .. it.Archetype:GetFName():ToString() .. ' ' .. (ok and s or ('ERR ' .. tostring(s)))
    end
end
STATE_CAR, STATE_SLOTS, STATE_SET = nil, nil, nil
return table.concat(o, '\n')
