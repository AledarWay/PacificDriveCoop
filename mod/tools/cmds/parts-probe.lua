-- car parts: class chains of the own car's attached actors, and the members (functions / properties) matching
-- PARTS_PAT (default detach|attach|repair|health|interact|highlight|slot) of the part base classes, the character
-- and the inventory manager - to find how the game takes a part off / puts one on / repairs it.
local pat = PARTS_PAT or { "detach", "attach", "repair", "health", "interact", "highlight", "slot", "remove", "install", "equip" }
local function match(n)
    local l = n:lower()
    for _, p in ipairs(pat) do if l:find(p, 1, true) then return true end end
    return false
end
local seen, o = {}, {}
local function members(cls, depth)
    local g = 0
    while cls and cls:IsValid() and g < (depth or 5) do
        local cn = cls:GetFName():ToString()
        if seen[cn] then break end
        seen[cn] = true
        local t = {}
        pcall(function() cls:ForEachFunction(function(f) local n = f:GetFName():ToString() if match(n) then t[#t + 1] = "f:" .. n end end) end)
        pcall(function() cls:ForEachProperty(function(p) local n = p:GetFName():ToString() if match(n) then t[#t + 1] = "p:" .. n end end) end)
        o[#o + 1] = "== " .. cn .. ": " .. table.concat(t, " ")
        local ok, s = pcall(function() return cls:GetSuperStruct() end)
        if not ok or not s or not s:IsValid() or s:GetFName():ToString() == "Actor" then break end
        cls, g = s, g + 1
    end
end
local car = _G.CoopPlayers and _G.CoopPlayers.ownCarActor() or FindFirstOf("BP_PlayerCarNew_C")
local chains = {}
pcall(function()
    local arr = {}
    car:GetAttachedActors(arr, true)
    for i = 1, #arr do
        local a = arr[i]:get()
        local c, ch, g = a:GetClass(), {}, 0
        while c and c:IsValid() and g < 6 do
            ch[#ch + 1] = c:GetFName():ToString()
            local ok, s = pcall(function() return c:GetSuperStruct() end)
            if not ok or not s or not s:IsValid() or s:GetFName():ToString() == "Actor" then break end
            c, g = s, g + 1
        end
        local k = table.concat(ch, " < ")
        chains[k] = (chains[k] or 0) + 1
    end
end)
for k, n in pairs(chains) do o[#o + 1] = n .. "x " .. k end
-- members of the part base chain of a wheel / a door / a panel
for _, cn in ipairs({ "BP_CarPart_Door_Base_C", "BP_CarPart_Wheel_Base_C", "BP_CarPart_Base_C" }) do
    local a = FindFirstOf(cn)
    if a then members(a:GetClass(), 6) end
end
local ch = FindFirstOf("PDP_MainCharacter_C") if ch then members(ch:GetClass(), 4) end
local im = FindFirstOf("BP_InventoryManager_C") if im then members(im:GetClass(), 3) end
local cm = FindFirstOf("BP_CarManager_C") if cm then members(cm:GetClass(), 3) end
return table.concat(o, "\n")
