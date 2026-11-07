local Loot = CoopSync.Loot
local inv = Loot.inventorySystem()
Dev.out("InventorySystem", Dev.name(inv))
local t, part
for _, a in ipairs(CoopSync.collect()) do
  if not part and a:IsA(StaticFindObject("/Script/PenDriverPro.LootableTemplate")) then
    for _, p in ipairs(Loot.templateParts(a)) do if not part and p.MySocket:ToString():find("^Wheel") then t, part = a, p end end
  end
end
local arch = part.ItemInstance.Archetype
local l = part:K2_GetActorLocation()
Dev.out("part", part:GetFName():ToString(), "arch", Dev.name(arch), Dev.vec(l))
local xf = { Translation = { X = l.X, Y = l.Y, Z = l.Z + 30 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
local ok, r = pcall(function() return inv:SpawnItemActor(FindFirstOf("PlayerController"), xf, arch, 0, 4) end)
Dev.out("SpawnItemActor ok", ok, "ret", type(r), ok and r and r.IsValid and (r:IsValid() and r:GetFullName() or "invalid") or tostring(r))
if ok and r and r.IsValid and r:IsValid() then Dev.out("bPooled", tostring(r.bPooled), "loc", Dev.vec(r:K2_GetActorLocation()), "inst", Dev.name(r.Instance)) end
return "ok"
