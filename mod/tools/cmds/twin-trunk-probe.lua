-- The twin's trunk: its ExternalInventory component pointed at a container of its own (TT_OP 'make': a new object of
-- the trunk container's class, the trunk's layout, one item of TT_ITEM added; 'show' (default): where the twin's and
-- the own trunk component point now, the items there).
local T = rawget(_G, "CoopPlayers").twinModule()
local im = FindFirstOf("BP_InventoryManager_C")
local twin, own
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
    if c:IsValid() then if T.isTwin(c) then twin = c else own = c end end
end
local function trunkComp(car)
    local att = {}
    car:GetAttachedActors(att, true)
    for i = 1, #att do
        local a = att[i]:get()
        if a and a:IsValid() and a:GetClass():GetFName():ToString():find("Storage_Trunk") then return a.BP_InventoryContainerComponent, a end
    end
end
local function count(c)
    local n = 0
    pcall(function() for i = 1, c.Slots:GetArrayNum() do n = n + c.Slots[i].Items:GetArrayNum() end end)
    return n
end
local o = {}
local tc, ta = trunkComp(twin)
if TT_OP == "make" then
    local real = im.Inventory_Trunk
    local c = StaticConstructObject(real:GetClass(), ta)
    pcall(function() c:SetLayout(real.Layout) end)
    pcall(function() c:SetNewSlotParameters(real.NewSlotCapacity, real.NewSlotMaxForceCapacity, real.NewSlotRules, real.NewSlotIgnoreOuter) end)
    tc.Container = c
    CoopDevTwinTrunk = c:GetFullName()
    if TT_ITEM then
        local a = StaticFindObject(TT_ITEM)
        if not (a and a:IsValid()) then pcall(function() LoadAsset((TT_ITEM:gsub("%.[^.]+$", ""))) end) a = StaticFindObject(TT_ITEM) end
        local inst = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary"):CreateItemInstance(FindFirstOf("PlayerController"), a, 4)
        o[#o + 1] = "add=" .. tostring(c:AddItem(inst, true))
    end
    TT_OP = nil
end
o[#o + 1] = "twin trunk -> " .. (tc.Container:IsValid() and tc.Container:GetFullName() or "nil") .. " items=" .. count(tc.Container)
local oc = trunkComp(own)
o[#o + 1] = "own trunk -> " .. (oc.Container:IsValid() and oc.Container:GetFullName() or "nil") .. " items=" .. count(oc.Container)
o[#o + 1] = "inv trunk " .. im.Inventory_Trunk:GetFullName() .. " items=" .. count(im.Inventory_Trunk) .. " layout=" .. tostring(im.Inventory_Trunk.Layout:IsValid() and im.Inventory_Trunk.Layout:GetFullName())
return table.concat(o, "\n")
