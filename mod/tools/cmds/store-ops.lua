-- Car storage test ops (carstore.lua). ST_OP:
--   count     items of ST_ARCH (archetype path) in the own trunk, the other's twin's trunk, the player's inventory
--   add       ST_N items of ST_ARCH into the own real trunk (the owner's own action)
--   take      ST_N items of ST_ARCH out of the own real trunk (the owner's own action)
--   twintake  ST_N items of ST_ARCH from the twin's trunk into the player's inventory (as the inventory screen moves it)
--   twinput   ST_N items of ST_ARCH from the player's inventory into the twin's trunk
--   equip     the own car's slot ST_SLOT := ST_ARCH (twincar ownerEquip), then its item's containers
--   slotadd   ST_N items of ST_ARCH into the first container of the own car's ST_SLOT item
--   slotcount items of ST_ARCH in the first container of the ST_SLOT item: own car / twin
local T = rawget(_G, "CoopPlayers").twinModule()
local im = FindFirstOf("BP_InventoryManager_C")
local L = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
local function arch()
    local a = StaticFindObject(ST_ARCH)
    if not (a and a:IsValid()) then pcall(function() LoadAsset((ST_ARCH:gsub("%.[^.]+$", ""))) end) a = StaticFindObject(ST_ARCH) end
    return a
end
local twin
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then twin = c end end
local function trunkOf(car)
    if not car then return nil end
    local att = {}
    car:GetAttachedActors(att, true)
    for i = 1, #att do
        local a = att[i]:get()
        local c
        pcall(function() c = a.BP_InventoryContainerComponent.Container end)
        if c and c:IsValid() then return c end
    end
end
local function count(c)
    if not (c and c:IsValid()) then return -1 end
    local list = {}
    c:FindAllItemsOfType(arch(), list)
    return #list
end
local function move(from, to, n)
    local list = {}
    from:FindAllItemsOfType(arch(), list)
    local m = 0
    for i = 1, math.min(n, #list) do
        local it = list[i]:get()
        from:RemoveItem(it)
        if to:AddItem(it, true) then m = m + 1 end
    end
    return m
end
local function slotFirst(cont)
    local sl = cont and cont:GetSlot(FName(ST_SLOT))
    local it = sl and sl:IsValid() and sl.Items:GetArrayNum() > 0 and sl.Items[1] or nil
    if not (it and it:IsValid()) then return nil end
    local best
    for _, x in ipairs(FindAllOf("ItemContainer") or {}) do
        pcall(function() if x:GetOuter():GetAddress() == it:GetAddress() and (not best or x:GetFullName() < best:GetFullName()) then best = x end end)
    end
    return best
end
local op = ST_OP
ST_OP = nil
local n = ST_N or 1
local tt = trunkOf(twin)
if op == "add" or op == "slotadd" then
    local c = op == "add" and im.Inventory_Trunk or slotFirst(im.Inventory_CarEquipped)
    if not c then return "no container" end
    local m = 0
    for _ = 1, n do if c:AddItem(L:CreateItemInstance(FindFirstOf("PlayerController"), arch(), 4), true) then m = m + 1 end end
    return "added " .. m
elseif op == "take" then
    local list = {}
    im.Inventory_Trunk:FindAllItemsOfType(arch(), list)
    for i = 1, math.min(n, #list) do local it = list[i]:get() im.Inventory_Trunk:RemoveItem(it) it:Remove(true) end
    return "taken " .. math.min(n, #list)
elseif op == "twintake" then
    return "moved " .. move(tt, im.Inventory_Player, n)
elseif op == "twinput" then
    return "moved " .. move(im.Inventory_Player, tt, n)
elseif op == "equip" then
    local r = T.ownerEquip(ST_SLOT, ST_ARCH .. "@4")
    local c = slotFirst(im.Inventory_CarEquipped)
    return r .. " container=" .. tostring(c and c:GetFullName())
elseif op == "twinmove" or op == "twinputat" then
    -- an item of ST_ARCH (from the twin's trunk / the player's inventory) onto the last free tile of the twin's trunk
    local lay = tt.Layout
    local from = op == "twinmove" and tt or im.Inventory_Player
    local list = {}
    from:FindAllItemsOfType(arch(), list)
    if #list == 0 then return "none" end
    local it = list[1]:get()
    local w, h = 0, 0
    -- (the layout's GetSize threw either way it was called - 2 / 0 of its 2 out parameters: the 12 x 12 walk below)
    from:RemoveItem(it)
    for y = ((h or 0) > 0 and h or 12) - 1, 0, -1 do
        for x = ((w or 0) > 0 and w or 12) - 1, 0, -1 do
            if lay:CanInsertItem(tt, it, { X = x, Y = y }, false, false) then
                lay:EmplaceSlot(tt, it, { X = x, Y = y }, false, false)
                return string.format("tile=%d_%d_0", x, y)
            end
        end
    end
    from:AddItem(it, true)
    return "no free tile (size " .. tostring(w) .. "x" .. tostring(h) .. ")"
elseif op == "tiles" then
    -- "tile=archetype" of every item in the own trunk | the twin's trunk, sorted
    local function tiles(c)
        local t = {}
        if not (c and c:IsValid()) then return "-" end
        for si = 1, c.Slots:GetArrayNum() do
            local s = c.Slots[si]
            if s and s:IsValid() then
                for ii = 1, s.Items:GetArrayNum() do
                    local x, y, r = 0, 0, 0
                    pcall(function() x, y, r = s.Location.X, s.Location.Y, s.bRotated and 1 or 0 end)
                    t[#t + 1] = string.format("%d_%d_%d=%s", x, y, r, s.Items[ii].Archetype:GetFName():ToString())
                end
            end
        end
        table.sort(t)
        return table.concat(t, ",")
    end
    return "own=" .. tiles(im.Inventory_Trunk) .. " twin=" .. tiles(tt)
elseif op == "slotput" then
    local c = slotFirst(T.twinContainer(twin))
    if not c then return "no container" end
    return "moved " .. move(im.Inventory_Player, c, n)
elseif op == "slotcount" then
    return string.format("own=%d twin=%d", count(slotFirst(im.Inventory_CarEquipped)), count(slotFirst(T.twinContainer(twin))))
end
local same = tt and tt:GetAddress() == im.Inventory_Trunk:GetAddress()
return string.format("own=%d twin=%d player=%d twin_is_own=%s", count(im.Inventory_Trunk), count(tt), count(im.Inventory_Player), tostring(same))
