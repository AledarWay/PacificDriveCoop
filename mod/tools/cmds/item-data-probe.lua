-- What an item's data looks like from Lua: GetDataBlockDump() of a few car items (wheel, engine, fuel tank, battery),
-- and the health component of their parts (HC_GetHealth / HC_GetMaxHealth).
local IM = FindFirstOf("BP_InventoryManager_C")
local cont = IM.Inventory_CarEquipped
local o = {}
local want = DATA_SLOTS or { "Car.Equip.Essentials.WheelFL", "Car.Equip.Essentials.Engine", "Car.Equip.Attachments.BackSeatLeft", "Car.Equip.Attachments.BackSeatRight", "Car.Equip.Body.DoorsFL" }
for _, n in ipairs(want) do
    local sl = cont:GetSlot(FName(n))
    if sl and sl:IsValid() and sl.Items:GetArrayNum() > 0 then
        local it = sl.Items[1]
        local ok, d = pcall(function() return it:GetDataBlockDump() end)
        local ds = ok and (type(d) == "string" and d or (d and d.ToString and d:ToString()) or tostring(d)) or ("ERR " .. tostring(d))
        o[#o + 1] = "== " .. n .. " " .. it.Archetype:GetFName():ToString() .. "\n" .. tostring(ds):sub(1, 1500)
        pcall(function()
            local m = it:GetActorManifestation()
            local hc = m:GetComponentByClass(StaticFindObject("/Script/PenDriverInventory.HealthComponentBase"))
            o[#o + 1] = string.format("  health comp %s: %s / %s", hc and hc:IsValid() and hc:GetClass():GetFName():ToString() or "none",
                tostring(hc and hc:HC_GetHealth()), tostring(hc and hc:HC_GetMaxHealth()))
        end)
    else
        o[#o + 1] = "== " .. n .. ": empty"
    end
end
return table.concat(o, "\n")
