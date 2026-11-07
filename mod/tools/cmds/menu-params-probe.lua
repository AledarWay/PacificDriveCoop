-- What the player menu is opened with (an E on a storage): a hook on UMG_PlayerMenu_Main_C "Apply Menu Parameters"
-- keeps the ST_PlayerMenuParams fields in MENU_PARAMS (object fields: class / address / outer; containers named like
-- the inventory manager's). Once per game; MENU_PARAMS read by "return MENU_PARAMS".
if MENU_PARAMS_HOOKED then MENU_PARAMS = "(waiting)" return "hooked already" end
local fn = "/Game/UI/Inventory/PlayerMenu/UMG_PlayerMenu_Main.UMG_PlayerMenu_Main_C:Apply Menu Parameters"
if not StaticFindObject(fn) then return "no function" end
MENU_PARAMS_HOOKED = true
MENU_PARAMS = "(waiting)"
local function desc(v)
    local ok, s = pcall(function()
        if type(v) ~= "userdata" then return tostring(v) end
        if v.IsValid and v:IsValid() then
            local im = FindFirstOf("BP_InventoryManager_C")
            local n
            for _, f in ipairs({ "Inventory_Trunk", "Inventory_LargeTrunk", "Inventory_Player" }) do
                if im[f]:GetAddress() == v:GetAddress() then n = f end
            end
            return (n or v:GetClass():GetFName():ToString()) .. "@" .. string.format("%X", v:GetAddress()) .. " outer=" .. v:GetOuter():GetFName():ToString()
        end
        local t = {}
        pcall(function() for i = 1, #v do t[#t + 1] = desc(v[i]:get()) end end)
        return "[" .. table.concat(t, ", ") .. "]"
    end)
    return ok and s or "?"
end
RegisterHook(fn, function(self, params)
    local o = {}
    pcall(function()
        local p = params:get()
        local S
        StaticFindObject(fn):ForEachProperty(function(f) if f:GetFName():ToString() == "Parameters" then S = f:GetStruct() end end)
        S:ForEachProperty(function(f)
            local n = f:GetFName():ToString()
            local ok, v = pcall(function() return p[n] end)
            o[#o + 1] = n .. "=" .. (ok and desc(v) or "?")
        end)
    end)
    MENU_PARAMS = table.concat(o, "\n")
end)
return "hooked"
