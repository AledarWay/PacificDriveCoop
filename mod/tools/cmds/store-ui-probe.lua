-- What the inventory screen shows after E on a storage: the inventory manager's object properties (containers named
-- like the manager's own fields), the live inventory widgets and their object properties pointing at containers.
local im = FindFirstOf("BP_InventoryManager_C")
local named = {}
for _, f in ipairs({ "Inventory_Trunk", "Inventory_LargeTrunk", "Inventory_Player", "Inventory_CarEquipped" }) do
    pcall(function() local c = im[f] if c and c:IsValid() then named[c:GetAddress()] = f end end)
end
local function desc(v)
    local ok, s = pcall(function()
        if not (v and v.IsValid and v:IsValid()) then return nil end
        local n = named[v:GetAddress()]
        return (n or v:GetClass():GetFName():ToString()) .. "@" .. string.format("%X", v:GetAddress()) .. " outer=" .. v:GetOuter():GetFName():ToString()
    end)
    return ok and s or nil
end
local o = {}
local function props(obj, label, filter)
    pcall(function()
        local cls = obj:GetClass()
        while cls and cls:IsValid() do
            cls:ForEachProperty(function(p)
                local name = p:GetFName():ToString()
                local pc = p:GetClass():GetFName():ToString()
                if pc ~= "ObjectProperty" then return end
                local ok, v = pcall(function() return obj[name] end)
                if ok and type(v) == "userdata" then
                    local d = desc(v)
                    if d and (not filter or d:find(filter)) then o[#o + 1] = label .. "." .. name .. " = " .. d end
                end
            end)
            cls = cls:GetSuperStruct()
        end
    end)
end
props(im, "IM", "Container")
for _, w in ipairs(FindAllOf("UserWidget") or {}) do
    local ok, vis = pcall(function() return w:IsValid() and w:IsInViewport() end)
    local n = w:GetClass():GetFName():ToString()
    if ok and vis and (n:find("Invent") or n:find("Storage") or n:find("Container")) then
        o[#o + 1] = "widget " .. n
        props(w, "  W", "Container")
    end
end
return table.concat(o, "\n")
