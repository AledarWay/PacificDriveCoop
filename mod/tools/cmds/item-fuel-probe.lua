-- An item instance's fuel (IP_Fuelable) from Lua, with no actor of its own (a canister in a container):
--   read  BFL_ItemPropertyUtilityFns GetFuelableInfo (out params: one table each) and GetDataBlockDump
--   write a BP_FuelableComponent_C constructed here, SetItemInstance(item) and its "Set Fuel"
-- IF_ARCH: the archetype (default the fuel can), IF_FUEL: the value to write.
local arch = StaticFindObject(IF_ARCH or "/Game/Gameplay/Inventory/Items/Tools/FuelCan/IA_Tool_Target_FuelCan.IA_Tool_Target_FuelCan")
if not (arch and arch:IsValid()) then return "no archetype" end
local IBL = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
local pc = FindFirstOf("PlayerController")
local inst = IBL:CreateItemInstance(pc, arch, 4)
if not (inst and inst:IsValid()) then return "no instance" end
local o = {}
local BFL = StaticFindObject("/Game/Systems/ScriptingLibraries/BFL_ItemPropertyUtilityFns.Default__BFL_ItemPropertyUtilityFns_C")
local function info(tag)
    local t = { {}, {}, {}, {}, {}, {}, {} }
    local ok, e = pcall(function() BFL:GetFuelableInfo(inst, pc, t[1], t[2], t[3], t[4], t[5], t[6]) end)
    local kv = {}
    for i = 1, 6 do for k, v in pairs(t[i]) do kv[#kv + 1] = tostring(k) .. "=" .. tostring(v) end end
    o[#o + 1] = tag .. ": " .. (ok and table.concat(kv, " ") or ("ERR " .. tostring(e)))
    local okD, d = pcall(function() return inst:GetDataBlockDump() end)
    local ds = okD and (type(d) == "string" and d or (d and d.ToString and d:ToString()) or tostring(d)) or ("ERR " .. tostring(d))
    o[#o + 1] = "  dump: " .. tostring(ds):gsub("%s+", " "):sub(1, 600)
end
local t0 = os.clock()
info("new")
o[#o + 1] = string.format("  read ms %.2f", (os.clock() - t0) * 1000)
local cls = StaticFindObject("/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_FuelableComponent.BP_FuelableComponent_C")
local okC, fc = pcall(function() return StaticConstructObject(cls, pc, FName("None"), 0, 0, false, false, nil) end)
o[#o + 1] = "carrier: " .. tostring(okC) .. " " .. tostring(okC and fc and fc:IsValid())
if okC and fc and fc:IsValid() then
    local ok1, e1 = pcall(function() fc:SetItemInstance(inst, false) end)
    o[#o + 1] = "  SetItemInstance " .. tostring(ok1) .. " " .. tostring(e1)
    local ok2, e2 = pcall(function() fc["Set Fuel"](fc, IF_FUEL or 2.25) end)
    o[#o + 1] = "  Set Fuel " .. tostring(ok2) .. " " .. tostring(e2)
    local st = { {}, {}, {}, {}, {}, {}, {} }
    pcall(function() fc:GetFuelStatus(st[1], st[2], st[3], st[4], st[5], st[6], st[7]) end)
    o[#o + 1] = "  carrier status fuel=" .. tostring(st[1].Fuel) .. " cap=" .. tostring(st[2]["Fuel Capacity"])
    pcall(function() fc:SetItemInstance(nil, false) end)
end
info("after")
return table.concat(o, "\n")
