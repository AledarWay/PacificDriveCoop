local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local f = io.open(os.getenv("COOPDEV_DIR") .. "/mines-" .. os.time() .. ".txt", "wb")
local pawn = FindFirstOf("PlayerController").Pawn
local pl = pawn and pawn:IsValid() and pawn:K2_GetActorLocation() or {X=0,Y=0,Z=0}
f:write(string.format("# player %.0f %.0f %.0f\n", pl.X, pl.Y, pl.Z))
local n = 0
for _, a in ipairs(FindAllOf("BP_Hazard_Landmine_C") or {}) do
  if KSL:IsValid(a) and a:GetFullName():find(":PersistentLevel%.") then
    local l = a:K2_GetActorLocation()
    f:write(string.format("%s\t%.0f\t%.0f\t%.0f\n", a:GetFName():ToString(), l.X, l.Y, l.Z)) n = n + 1
  end
end
f:close()
return n .. " player " .. Dev.vec(pl)
