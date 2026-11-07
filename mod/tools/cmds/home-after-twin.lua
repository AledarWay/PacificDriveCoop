-- Does a second car of the rework kind stop the travel home? HAT_MODE:
--   "none"    nothing (baseline)
--   "cont"    only a filled named container (transient outer)
--   "spawn"   container + a car spawned bound to it (kept)
--   "destroy" container + car, then the car and its attached actors destroyed and the container emptied
-- then TravelToGarage as the mod's Run.goHome does.
local mode = HAT_MODE or "none"
local o = { "mode " .. mode }
if mode ~= "none" then
    local IBL = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
    local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local IM = FindFirstOf("BP_InventoryManager_C")
    local cm = FindFirstOf("BP_CarManager_C")
    local own = cm.NewCarActor
    local pc = FindFirstOf("PlayerController")
    local real = IM.Inventory_CarEquipped
    local cont = IBL:CreateNamedContainer(StaticFindObject("/Engine/Transient"), FText("CoopSyncTwin"), real.NewSlotRules, real.NewSlotCapacity, real.NewSlotMaxForceCapacity)
    local names = {}
    real:GetSlotNames(names)
    local made = 0
    for i = 1, #names do
        local n = names[i]:get()
        local sl, tsl = real:GetSlot(n), cont:FindOrCreateSlot(n)
        pcall(function() tsl:SetCapacity(sl:GetCapacity()) end)
        for k = 1, sl.Items:GetArrayNum() do
            pcall(function() tsl:AddItem(IBL:CreateItemInstance(pc, sl.Items[k].Archetype, sl.Items[k].CreateContext)) made = made + 1 end)
        end
    end
    o[#o + 1] = "container items " .. made .. " outer " .. cont:GetOuter():GetFullName()
    if mode == "spawn" or mode == "destroy" then
        local l = own:K2_GetActorLocation()
        local xf = KML:MakeTransform({ X = l.X + 600, Y = l.Y, Z = l.Z + 80 }, own:K2_GetActorRotation(), { X = 1, Y = 1, Z = 1 })
        IM.Inventory_CarEquipped = cont
        local ok, car = pcall(function() return GS:FinishSpawningActor(GS:BeginDeferredActorSpawnFromClass(pc, own:GetClass(), xf, 1, nil), xf) end)
        IM.Inventory_CarEquipped = real
        cm.NewCarActor = own
        o[#o + 1] = "spawned " .. tostring(ok and car and car:IsValid())
        if mode == "destroy" and ok and car then
            -- the container emptied first (placeholders spawn), then every attached actor and the car
            local n2 = {}
            cont:GetSlotNames(n2)
            for i = 1, #n2 do
                local sl = cont:GetSlot(n2[i]:get())
                for k = sl.Items:GetArrayNum(), 1, -1 do
                    local it = sl.Items[k]
                    pcall(function() cont:RemoveItemFromSlot(n2[i]:get(), it) end)
                    pcall(function() it:Remove(true) end)
                end
            end
            local arr = {}
            car:GetAttachedActors(arr, true)
            local d = 0
            for i = 1, #arr do pcall(function() arr[i]:get():K2_DestroyActor() d = d + 1 end) end
            car:K2_DestroyActor()
            o[#o + 1] = "destroyed car + " .. d .. " attached"
        end
    end
end
local pm = FindFirstOf("BP_ProgressionManager_C")
local out = {}
Dev.after(HAT_DELAY or 3000, function() FindFirstOf("BP_ProgressionManager_C"):TravelToGarage(0, false, false, false, 1, {}) end)
o[#o + 1] = "travel home in 3 s"
return table.concat(o, " | ")
