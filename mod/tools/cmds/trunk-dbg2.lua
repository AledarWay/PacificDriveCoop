local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local IBL = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
local ctx = FindFirstOf("PlayerController")
local p
for _, x in ipairs(FindAllOf("BP_TemplatePart_TrunkContents_C") or {}) do if KSL:IsValid(x) and x:GetFullName():find(":PersistentLevel%.") then p = x break end end
local owned = {}
for _, c in ipairs(FindAllOf("ItemContainer") or {}) do if c:IsValid() and c:GetOuter():IsValid() and c:GetOuter():GetFullName() == p.ItemInstance:GetFullName() then owned[#owned+1] = c end end
Dev.out("part", p:GetFName():ToString(), "owned containers", #owned)
local c = owned[1]
Dev.out("slots", c.Slots:GetArrayNum(), "layout", Dev.name(c.Layout), "WorldOverride", Dev.name(c.WorldOverride), "transacting", tostring(c.bIsTransacting))
local tape = StaticFindObject("/Game/Gameplay/Inventory/Items/Resources/Basic/RawTape/IA_Resource_Raw_Tape.IA_Resource_Raw_Tape")
local inst = IBL:CreateItemInstance(ctx, tape, 4)
local fail = {}
local ok1, can = pcall(function() return c:CanAddItem(inst, fail) end)
Dev.out("CanAddItem", ok1, tostring(can))
for k, v in pairs(fail) do Dev.out("  fail", k, tostring(v)) end
local ok2, e2 = pcall(function() c:AddItem(inst, true) end)
Dev.out("AddItem", ok2, tostring(e2), "slots now", c.Slots:GetArrayNum())
return "ok"
