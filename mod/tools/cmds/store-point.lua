-- Where the twin's trunk storage (the box in the other's trunk) points: its container component's container against the
-- local inventory manager's Inventory_Trunk. "own_trunk": the local player's own trunk (the alpha 16 bug), "own_box": a
-- container of the twin's own (carstore), with the item counts of each.
local T = _G.CoopPlayers.twinModule()
local tw
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then tw = c end end
if not tw then return "no twin" end
local im = FindFirstOf("BP_InventoryManager_C")
local function count(c)
    local n = 0
    pcall(function()
        local sn = {}
        c:GetSlotNames(sn)
        for i = 1, #sn do n = n + c:GetSlot(sn[i]:get()).Items:GetArrayNum() end
    end)
    return n
end
local att = {}
tw:GetAttachedActors(att, true)
local o = {}
for i = 1, #att do
    local a = att[i]:get()
    if a:IsValid() and a:GetClass():GetFName():ToString():find("Storage_Trunk", 1, true) then
        local c
        pcall(function() c = a.BP_InventoryContainerComponent.Container end)
        local what = not (c and c:IsValid()) and "none"
            or c:GetAddress() == im.Inventory_Trunk:GetAddress() and "own_trunk"
            or c:GetAddress() == im.Inventory_LargeTrunk:GetAddress() and "own_large"
            or "own_box"
        o[#o + 1] = string.format("%s=%s items=%d", a:GetClass():GetFName():ToString(), what, c and c:IsValid() and count(c) or -1)
    end
end
return table.concat(o, " ") .. " own_trunk_items=" .. count(im.Inventory_Trunk)
