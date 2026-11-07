-- Spawn a second BP_PlayerCarNew_C 10 m beside the player car and report what it did to the game's managers.
local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local function liveCars()
  local t = {}
  for _, x in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if x:IsValid() and x:GetFullName():find(":PersistentLevel.", 1, true) then t[#t + 1] = x end end
  return t
end
local function attachedCount(car)
  local n, parts = 0, 0
  for _, a in ipairs(FindAllOf("Actor") or {}) do
    if a:IsValid() then local p = a:GetAttachParentActor() if p and p:IsValid() and p:GetAddress() == car:GetAddress() then n = n + 1 if a:GetClass():GetFName():ToString():find("CarPart") then parts = parts + 1 end end end
  end
  return n, parts
end
local cm = FindFirstOf("BP_CarManager_C")
local A = liveCars()[1]
local before = cm.NewCarActor
local nA0, pA0 = attachedCount(A)
local xf = KML:MakeTransform(KML:TransformLocation(A:GetTransform(), { X = 0, Y = 1000, Z = 150 }), A:K2_GetActorRotation(), { X = 1, Y = 1, Z = 1 })
local B = GS:BeginDeferredActorSpawnFromClass(FindFirstOf("PlayerController"), A:GetClass(), xf, 1, nil)
B = GS:FinishSpawningActor(B, xf)
SecondCar = B
local after = cm.NewCarActor
return string.format("A=%s B=%s | manager car before=%s after=%s | A attached %d (parts %d) | cars now %d",
  A:GetFName():ToString(), B:IsValid() and B:GetFName():ToString() or "fail",
  before:IsValid() and before:GetFName():ToString() or "-", after:IsValid() and after:GetFName():ToString() or "-", nA0, pA0, #liveCars())
