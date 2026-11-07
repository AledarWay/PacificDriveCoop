CoopSync = CoopSync or dofile("C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua")
local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local a
for _, x in ipairs(FindAllOf("BP_Lootable_Base_C") or {}) do
  if KSL:IsValid(x) and x:GetFullName():find(":PersistentLevel%.") and x.OnOpenItemsDecisionTree:IsValid() then a = x break end
end
local function flags() return string.format("RolledOnOpen=%s WasOpened=%s Empty=%s Populated=%s", tostring(a.RolledOnOpenItems), tostring(a.DataBlock_WasOpened), tostring(a.Empty), tostring(a["Container Populated"])) end
CoopSync.Loot.beginPass()
Dev.out("target", a:GetFName():ToString(), flags())
Dev.out("before", CoopSync.Loot.serialize(a))
local ok, e = pcall(function() a:OnInteractedWith() end)
Dev.out("OnInteractedWith", ok, tostring(e), flags())
CoopSync.Loot.beginPass()
Dev.out("after", CoopSync.Loot.serialize(a))
CoopSyncOpenTarget = a
return "ok"
