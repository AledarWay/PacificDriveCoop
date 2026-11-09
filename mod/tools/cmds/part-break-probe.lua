-- A car part hit the way a tool hits it (2026-11-09, owner: "the friend saws off the white bar of a part, the red one
-- never starts"): PB_N hits of PB_DMG by the tool's damage message (PB_MSG, default the scrapper's) dispatched to the
-- part actor of PB_SLOT on the own car or the twin (PB_CAR 'own' | 'twin'); after each hit the health, the break
-- health and the slot's item. PB_N = 0: only reads.
local CAR, SLOT = PB_CAR or "own", PB_SLOT or "Car.Equip.Body.DoorsFL"
local MSG = PB_MSG or "MSG_Damage_Physical_Piercing_Scrapper"
local T = _G.CoopPlayers.twinModule()
local cont
if CAR == "twin" then
    for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then cont = T.twinContainer(c) end end
else
    cont = FindFirstOf("BP_InventoryManager_C").Inventory_CarEquipped
end
if not cont then return "no container" end
local HC = StaticFindObject("/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_HealthComponent.BP_HealthComponent_C")
local function part()
    local sl = cont:GetSlot(FName(SLOT))
    if not (sl and sl:IsValid() and sl.Items:GetArrayNum() > 0) then return nil end
    local it = sl.Items[1]
    local a = it:GetActorManifestation()
    return it, a, a and a:IsValid() and a:GetComponentByClass(HC)
end
local function read()
    local it, a, hc = part()
    if not it then return "slot empty" end
    if not hc then return "no health comp (" .. it.Archetype:GetFName():ToString() .. ")" end
    local h, bh = -1, -1
    pcall(function() h = hc:HC_GetHealth() end)
    local okB, eB = pcall(function() bh = hc:HC_GetBreakHealth() end)
    return string.format("%s h=%.1f bh=%s canBreak=%s", it.Archetype:GetFName():ToString(), h, okB and string.format("%.1f", bh) or ("ERR " .. tostring(eB)), tostring(hc.CanBeBreaking))
end
local out = { "start " .. read() }
local path = "/Game/Systems/Messages/" .. MSG .. "." .. MSG .. "_C"
local c = StaticFindObject(path)
if not (c and c:IsValid()) then pcall(function() LoadAsset((path:gsub("_C$", ""))) end) c = StaticFindObject(path) end
local ms = FindFirstOf("MessageSystem")
for i = 1, PB_N or 0 do
    local it, a = part()
    if not (a and a:IsValid()) then out[#out + 1] = "hit " .. i .. ": no part" break end
    local ok, e = pcall(function()
        local msg = StaticConstructObject(c, ms)
        msg.Damage = PB_DMG or 10
        msg.HitLocation = a:K2_GetActorLocation()
        msg:Initialize()
        if PB_WAY == "comp" then
            local _, _, hc = part()
            hc["Process Damage Message"](hc, msg, FindFirstOf("PlayerController").Pawn, a, {})
        else
            ms:DispatchMessage(msg, a)
        end
    end)
    out[#out + 1] = "hit " .. i .. (ok and "" or (" ERR " .. tostring(e))) .. ": " .. read()
end
return table.concat(out, " || ")
