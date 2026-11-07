-- Spawn a twin (second BP_PlayerCarNew_C) 10 m beside the own car, give the manager back, re-link the own car's items.
local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local cm = FindFirstOf("BP_CarManager_C")
local own = cm.NewCarActor
OWN_CAR = own
local xf = KML:MakeTransform(KML:TransformLocation(own:GetTransform(), { X = 0, Y = 1000, Z = 150 }), own:K2_GetActorRotation(), { X = 1, Y = 1, Z = 1 })
local B = GS:BeginDeferredActorSpawnFromClass(FindFirstOf("PlayerController"), own:GetClass(), xf, 1, nil)
B = GS:FinishSpawningActor(B, xf)
TWIN_CAR = B
cm.NewCarActor = own
local SSC = StaticFindObject("/Script/PenDriverInventory.SlotSceneComponent")
local comps = own:K2_GetComponentsByClass(SSC)
local rebound = 0
for i = 1, #comps do
  local c = comps[i]:get()
  local sl = c.ItemSlot
  if sl and sl:IsValid() and sl.Items:GetArrayNum() > 0 then
    local m = sl.Items[1]:GetActorManifestation()
    local p = m and m:IsValid() and m:GetAttachParentActor()
    if not (p and p:IsValid() and p:GetAddress() == own:GetAddress()) then c:SetItemSlot(nil) c:SetItemSlot(sl) rebound = rebound + 1 end
  end
end
return "twin " .. B:GetFName():ToString() .. ", own slots rebound " .. rebound
