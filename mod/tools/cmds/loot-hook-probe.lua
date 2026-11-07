-- Do the item containers' slot handlers (HandleSlotItemAdded / Removed) run through UE4SS hooks when items move?
-- First run: hooks registered (once per Lua state), counts by the container's outer class. LOOT_MOVE = true: one item
-- out of the nearest lootable container into the player's inventory and back.
CoopDevLootHookProbe = CoopDevLootHookProbe or { n = {}, done = false }
local P = CoopDevLootHookProbe
if not P.done then
    P.done = true
    for _, fn in ipairs({ "HandleSlotItemAdded", "HandleSlotItemRemoved" }) do
        local path = "/Script/PenDriverInventory.ItemContainer:" .. fn
        if StaticFindObject(path) then
            RegisterHook(path, function(self)
                local c = self:get()
                local o = c:GetOuter()
                local k = fn .. " " .. (o and o:IsValid() and o:GetClass():GetFName():ToString() or "?")
                P.n[k] = (P.n[k] or 0) + 1
                P.last = o and o:IsValid() and o:GetFullName() or "?"
            end)
        else
            P.n["missing " .. fn] = 1
        end
    end
end
if LOOT_MOVE then
    LOOT_MOVE = nil
    local pawn = FindFirstOf("PlayerController").Pawn
    local pl = pawn:K2_GetActorLocation()
    local best, bd
    for _, a in ipairs(FindAllOf("BP_Lootable_Base_C") or {}) do
        local ok, c = pcall(function() return a.InventoryContainer end)
        if ok and c and c:IsValid() and c:GetNumItems() > 0 then
            local l = a:K2_GetActorLocation()
            local d = (l.X - pl.X) ^ 2 + (l.Y - pl.Y) ^ 2
            if not bd or d < bd then best, bd = a, d end
        end
    end
    if not best then return "no container with items" end
    local c = best.InventoryContainer
    local items = {}
    c:GetAllItems(items)
    local inst = items[1]:get()
    local inv = FindFirstOf("BP_InventoryManager_C").Inventory_Player
    c:RemoveItem(inst)
    inv:AddItem(inst, true)
    inv:RemoveItem(inst)
    c:AddItem(inst, true)
    P.moved = best:GetFullName()
end
local t = {}
for k, v in pairs(P.n) do t[#t + 1] = k .. "=" .. v end
table.sort(t)
return table.concat(t, " ") .. " | last=" .. tostring(P.last) .. " moved=" .. tostring(P.moved)
