-- One slot (STATE_SLOT, full tag name) on the twin and the own car: items in it (archetype), and what the character
-- holds (hand slot) / world wheel-like items within 5 m of the character.
local T = _G.CoopPlayers.twinModule()
local SSC = StaticFindObject("/Script/PenDriverInventory.SlotSceneComponent")
local name = STATE_SLOT or "Car.Equip.Essentials.WheelRL"
local o = {}
local function slotOf(car)
    local comps = car:K2_GetComponentsByClass(SSC)
    for i = 1, #comps do
        local s = comps[i]:get()
        local ok, n = pcall(function() return s.SlotName.TagName:ToString() end)
        if ok and n == name then return s end
    end
end
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
    if c:IsValid() and c:GetFullName():find(":PersistentLevel.", 1, true) then
        local s = slotOf(c)
        local tag = T.isTwin(c) and "twin" or "own"
        if s then
            local t = {}
            pcall(function()
                local sl = s.ItemSlot
                for k = 1, sl.Items:GetArrayNum() do t[#t + 1] = sl.Items[k].Archetype:GetFName():ToString() end
            end)
            local sp = s.SpawnedActor
            o[#o + 1] = string.format("%s %s: items=[%s] spawned=%s", tag, name, table.concat(t, ","), sp and sp:IsValid() and sp:GetClass():GetFName():ToString() or "none")
        end
    end
end
local pawn = FindFirstOf("PlayerController").Pawn
local me = pawn:K2_GetActorLocation()
pcall(function()
    local IM = FindFirstOf("BP_InventoryManager_C")
    local t = {}
    for _, f in ipairs({ "Inventory_PlayerHand", "Inventory_Player" }) do
        local c = IM[f]
        local n = 0
        for i = 1, c.Slots:GetArrayNum() do
            local sl = c.Slots[i]
            for k = 1, sl.Items:GetArrayNum() do
                n = n + 1
                if f == "Inventory_PlayerHand" or sl.Items[k].Archetype:GetFName():ToString():find("Wheel") then t[#t + 1] = f:sub(11) .. ":" .. sl.Items[k].Archetype:GetFName():ToString() end
            end
        end
        t[#t + 1] = f:sub(11) .. " count=" .. n
    end
    o[#o + 1] = "player: " .. table.concat(t, " ")
end)
local near = {}
for _, a in ipairs(FindAllOf("ItemWorldManifestation") or {}) do
    if a:IsValid() then
        local l = a:K2_GetActorLocation()
        local d = math.sqrt((l.X - me.X) ^ 2 + (l.Y - me.Y) ^ 2 + (l.Z - me.Z) ^ 2)
        if d < 500 then near[#near + 1] = string.format("%s@%.0f", a:GetClass():GetFName():ToString(), d) end
    end
end
o[#o + 1] = "world items near: " .. (#near > 0 and table.concat(near, ",") or "none")
local hands = {}
for _, a in ipairs(FindAllOf("ItemHandManifestation") or {}) do
    if a:IsValid() then hands[#hands + 1] = a:GetClass():GetFName():ToString() .. (a.bHidden and "(hidden)" or "") end
end
o[#o + 1] = "hand manifestations: " .. (#hands > 0 and table.concat(hands, ",") or "none")
return table.concat(o, "\n")
