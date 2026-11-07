-- A second car that binds to its OWN named container from the start: the container is filled with new instances of
-- the own car's items (minus CLEAN_SKIP slot, default WheelRL, to see the layout is the container's), the inventory
-- manager's Inventory_CarEquipped points at it while the car spawns (its BeginPlay binds the slots), then back.
-- Checks: the own car's items still manifest as the own car's parts (no relink needed), the own parts not respawned,
-- the new car's slots on the new container, the skipped slot empty there. CLEAN_READ = true: the checks only.
local IBL = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
local SSC = StaticFindObject("/Script/PenDriverInventory.SlotSceneComponent")
local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local IM = FindFirstOf("BP_InventoryManager_C")
local cm = FindFirstOf("BP_CarManager_C")
local own = cm.NewCarActor
local o = {}
local function slotMap(car)
    local t = {}
    local comps = car:K2_GetComponentsByClass(SSC)
    for i = 1, #comps do
        local s = comps[i]:get()
        pcall(function()
            local a = s.SpawnedActor
            t[s.SlotName.TagName:ToString()] = { addr = a and a:IsValid() and a:GetAddress() or 0, cls = a and a:IsValid() and a:GetClass():GetFName():ToString() or "-",
                outer = s.ItemSlot and s.ItemSlot:IsValid() and s.ItemSlot:GetOuter():GetFName():ToString() or "-", items = s.ItemSlot and s.ItemSlot:IsValid() and s.ItemSlot.Items:GetArrayNum() or -1 }
        end)
    end
    return t
end
local function linksOk(car)
    -- every item of the game's car container manifests as a part under the given car
    local good, bad = 0, 0
    local cont = IM.Inventory_CarEquipped
    local names = {}
    cont:GetSlotNames(names)
    for i = 1, #names do
        local sl = cont:GetSlot(names[i]:get())
        for k = 1, sl.Items:GetArrayNum() do
            local ok, m = pcall(function() return sl.Items[k]:GetActorManifestation() end)
            local under = false
            if ok and m and m:IsValid() then
                local cur, g = m, 0
                while g < 10 do
                    if cur:GetAddress() == car:GetAddress() then under = true break end
                    local p = cur:GetAttachParentActor()
                    if not (p and p:IsValid()) then break end
                    cur, g = p, g + 1
                end
            end
            if under then good = good + 1 else bad = bad + 1 end
        end
    end
    return good, bad
end
if CLEAN_READ then
    local g, b = linksOk(own)
    return string.format("own links good=%d bad=%d", g, b)
end
local before = slotMap(own)
local g0, b0 = linksOk(own)
o[#o + 1] = string.format("before: own links good=%d bad=%d", g0, b0)
local real = IM.Inventory_CarEquipped
local skip = CLEAN_SKIP or "Car.Equip.Essentials.WheelRL"
local cont = IBL:CreateNamedContainer(IM, FText("CoopTwin"), real.NewSlotRules, real.NewSlotCapacity, real.NewSlotMaxForceCapacity)
local names = {}
real:GetSlotNames(names)
local made = 0
for i = 1, #names do
    local n = names[i]:get()
    local sl = real:GetSlot(n)
    local tsl = cont:FindOrCreateSlot(n)
    pcall(function() tsl:SetCapacity(sl:GetCapacity()) end)
    if n:ToString() ~= skip then
        for k = 1, sl.Items:GetArrayNum() do
            local it = sl.Items[k]
            pcall(function() tsl:AddItem(IBL:CreateItemInstance(own, it.Archetype, it.CreateContext)) made = made + 1 end)
        end
    end
end
o[#o + 1] = string.format("container %s: %d items (skipped %s)", cont:GetFName():ToString(), made, skip)
local l = own:K2_GetActorLocation()
local r = own:K2_GetActorRotation()
local xf = KML:MakeTransform({ X = l.X + 600, Y = l.Y, Z = l.Z + 80 }, r, { X = 1, Y = 1, Z = 1 })
IM.Inventory_CarEquipped = cont
local ok, car = pcall(function()
    local b = GS:BeginDeferredActorSpawnFromClass(FindFirstOf("PlayerController"), own:GetClass(), xf, 1, nil)
    return GS:FinishSpawningActor(b, xf)
end)
IM.Inventory_CarEquipped = real
local mgrTaken = cm.NewCarActor and cm.NewCarActor:IsValid() and cm.NewCarActor:GetAddress() ~= own:GetAddress()
cm.NewCarActor = own
if not (ok and car and car:IsValid()) then return table.concat(o, "\n") .. "\nspawn failed " .. tostring(car) end
_G.CleanCarPath = car:GetFullName()
o[#o + 1] = "spawned " .. car:GetFName():ToString() .. " manager taken by it: " .. tostring(mgrTaken)
local after = slotMap(own)
local moved = 0
for k, v in pairs(before) do if after[k] and after[k].addr ~= v.addr then moved = moved + 1 end end
local g1, b1 = linksOk(own)
o[#o + 1] = string.format("own: parts respawned=%d links good=%d bad=%d", moved, g1, b1)
local nm = slotMap(car)
local outers, spawned, n = {}, 0, 0
for _, v in pairs(nm) do n = n + 1 outers[v.outer] = (outers[v.outer] or 0) + 1 if v.addr ~= 0 then spawned = spawned + 1 end end
local ol = {} for k, c in pairs(outers) do ol[#ol + 1] = k .. "=" .. c end
o[#o + 1] = string.format("new car: slots=%d spawned=%d containers: %s", n, spawned, table.concat(ol, ","))
local s = nm[skip]
o[#o + 1] = "new car " .. skip .. ": " .. (s and (s.cls .. " items=" .. s.items) or "missing")
return table.concat(o, "\n")
