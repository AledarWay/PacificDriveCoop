-- The cars' storages: every attached part that is a storage (BP_Storage_Trunk_Base / BP_Storage_Attach_Base, by class
-- name walk), its item instance, its container components and the container each points at (compared with the
-- inventory manager's Inventory_Trunk / Inventory_LargeTrunk), the items in it.
local im = FindFirstOf("BP_InventoryManager_C")
local named = {}
for _, f in ipairs({ "Inventory_Trunk", "Inventory_LargeTrunk", "Inventory_Player", "Inventory_CarEquipped", "Inventory_OverflowContainer" }) do
    pcall(function() local c = im[f] if c and c:IsValid() then named[c:GetAddress()] = f end end)
end
local function isStorage(a)
    local ok, r = pcall(function()
        local c = a:GetClass()
        while c and c:IsValid() do
            local n = c:GetFName():ToString()
            if n == "BP_Storage_Trunk_Base_C" or n == "BP_Storage_Attach_Base_C" then return n end
            c = c:GetSuperStruct()
        end
    end)
    return ok and r or nil
end
local function items(cont)
    local n, names = 0, {}
    pcall(function()
        local sn = {}
        cont:GetSlotNames(sn)
        for i = 1, #sn do
            local sl = cont:GetSlot(sn[i]:get())
            for k = 1, sl.Items:GetArrayNum() do
                n = n + 1
                if #names < 6 then names[#names + 1] = sl.Items[k].Archetype:GetFName():ToString() end
            end
        end
    end)
    return n .. " [" .. table.concat(names, ",") .. "]"
end
local function cdesc(c)
    if not (c and c:IsValid()) then return "nil" end
    return string.format("%X", c:GetAddress()) .. "(" .. (named[c:GetAddress()] or c:GetClass():GetFName():ToString()) .. ") items=" .. items(c)
end
local o = {}
local CP = rawget(_G, "CoopPlayers")
local twinMod = CP and CP.twinModule()
for _, car in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
    if car:IsValid() then
        local tw = twinMod and twinMod.isTwin(car)
        o[#o + 1] = "car " .. car:GetFName():ToString() .. (tw and " TWIN" or " own")
        local att = {}
        pcall(function() car:GetAttachedActors(att, true) end)
        for i = 1, #att do
            local a = att[i]:get()
            local k = a and a:IsValid() and isStorage(a)
            if k then
                local d = { "  " .. k .. " " .. a:GetClass():GetFName():ToString() }
                pcall(function() d[#d + 1] = "inst=" .. a.Instance.Archetype:GetFName():ToString() end)
                pcall(function()
                    local comps = a:K2_GetComponentsByClass(StaticFindObject("/Script/PenDriverInventory.ItemPropertyComponent"))
                    for j = 1, #comps do
                        local cp = comps[j]:get()
                        local s = cp:GetClass():GetFName():ToString()
                        pcall(function() s = s .. " -> " .. cdesc(cp.Container) end)
                        pcall(function() local all = {} cp:GetContainers(all) for q = 1, #all do s = s .. " | " .. cdesc(all[q]:get()) end end)
                        d[#d + 1] = "\n    " .. s
                    end
                end)
                o[#o + 1] = table.concat(d, " ")
            end
        end
    end
end
for addr, f in pairs(named) do o[#o + 1] = f .. "=" .. string.format("%X", addr) end
return table.concat(o, "\n")
