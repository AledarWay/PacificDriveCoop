CoopSync = CoopSync or dofile("C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua")
local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local a
for _, x in ipairs(FindAllOf("BP_Lootable_Base_C") or {}) do
  if KSL:IsValid(x) and x:GetFullName():find(":PersistentLevel%.") and x.OnOpenItemsDecisionTree:IsValid() and not x.DataBlock_WasOpened then a = x break end
end
CoopSyncOpen2 = a
CoopSync.Loot.beginPass() CoopSyncOpen2Before = CoopSync.Loot.serialize(a)
a:HighlightInteract()
return a:GetFName():ToString()
