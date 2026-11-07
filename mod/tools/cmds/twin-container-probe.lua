-- Feasibility: the twin's parts as real game parts. A named container of our own (UInventoryBlueprintLibrary
-- CreateNamedContainer, same slot rules as the car's), filled with new instances of the own car's items' archetypes
-- (CreateItemInstance), bound to the twin's slot components (SlotSceneComponent BindNamedSlotsFromActor).
-- Reports what got bound / spawned. TWIN_CONT_READ = true: only the state of the last made container.
local IBL = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
local SSCD = StaticFindObject("/Script/PenDriverInventory.Default__SlotSceneComponent")
local SSC = StaticFindObject("/Script/PenDriverInventory.SlotSceneComponent")
local T = _G.CoopPlayers.twinModule()
local o = {}
local twin
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then twin = c end end
if not twin then return "no twin" end
local function slotsState(car)
    local comps = car:K2_GetComponentsByClass(SSC)
    local bound, items, spawned = 0, 0, 0
    for i = 1, #comps do
        local s = comps[i]:get()
        local sl = s.ItemSlot
        if sl and sl:IsValid() then
            bound = bound + 1
            if sl.Items:GetArrayNum() > 0 then items = items + 1 end
        end
        if s.SpawnedActor and s.SpawnedActor:IsValid() then spawned = spawned + 1 end
    end
    return string.format("slotcomps=%d bound=%d with_item=%d spawned=%d", #comps, bound, items, spawned)
end
if TWIN_CONT_READ then return "twin " .. slotsState(twin) .. " own " .. slotsState(T.ownCar()) end
local IM = FindFirstOf("BP_InventoryManager_C")
local eq = {}
IM:GetCarEquippedContainer(eq)
local own = eq.Inventory_CarEquipped
o[#o + 1] = "own container " .. own:GetFullName() .. " rules=" .. tostring(own.NewSlotRules and own.NewSlotRules:IsValid() and own.NewSlotRules:GetFName():ToString()) .. " cap=" .. own.NewSlotCapacity .. "/" .. own.NewSlotMaxForceCapacity
o[#o + 1] = "before: twin " .. slotsState(twin)
local cont = IBL:CreateNamedContainer(twin, FText("CoopTwin"), own.NewSlotRules, own.NewSlotCapacity, own.NewSlotMaxForceCapacity)
if not (cont and cont:IsValid()) then return table.concat(o, "\n") .. "\nno container" end
o[#o + 1] = "made " .. cont:GetFullName()
local names = {}
own:GetSlotNames(names)
local made, failed, ctxs = 0, 0, {}
for i = 1, #names do
    local n = names[i]:get()
    local sl = own:GetSlot(n)
    local tsl = cont:FindOrCreateSlot(n)
    if sl and sl:IsValid() and tsl and tsl:IsValid() then
        pcall(function() tsl:SetCapacity(sl:GetCapacity()) end)
        for k = 1, sl.Items:GetArrayNum() do
            local it = sl.Items[k]
            local ok = pcall(function()
                ctxs[tostring(it.CreateContext)] = true
                local inst = IBL:CreateItemInstance(twin, it.Archetype, it.CreateContext)
                tsl:AddItem(inst)
            end)
            if ok then made = made + 1 else failed = failed + 1 end
        end
    end
end
local cl = {} for k in pairs(ctxs) do cl[#cl + 1] = k end
o[#o + 1] = string.format("slots=%d items made=%d failed=%d contexts=%s", #names, made, failed, table.concat(cl, ","))
local okB, e = pcall(function() SSCD:BindNamedSlotsFromActor(cont, twin) end)
o[#o + 1] = "bind: " .. tostring(okB) .. " " .. tostring(e)
o[#o + 1] = "after: twin " .. slotsState(twin) .. " / own " .. slotsState(T.ownCar())
_G.TwinContPath = cont:GetFullName()
return table.concat(o, "\n")
