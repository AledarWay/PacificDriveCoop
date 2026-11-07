local pc = FindFirstOf("PlayerController")
Dev.out("PC", Dev.name(pc))
local pawn = pc.Pawn
Dev.out("Pawn", Dev.name(pawn))
if pawn and pawn:IsValid() then
    Dev.out("pawn class", pawn:GetClass():GetFullName())
    Dev.out("pawn loc", Dev.vec(pawn:K2_GetActorLocation()), "scale", Dev.vec(pawn:GetActorScale3D()))
    local par = CoopSyncParentOf and CoopSyncParentOf(pawn)
    Dev.out("pawn attach parent", par and par:GetFullName() or "-")
    local ok, mesh = pcall(function() return pawn.Mesh end)
    if ok and mesh and mesh:IsValid() then
        Dev.out("mesh comp", mesh:GetFullName())
        pcall(function() Dev.out("skeletal mesh", mesh.SkeletalMesh:GetFullName()) end)
        pcall(function() Dev.out("mesh rel scale", Dev.vec(mesh.RelativeScale3D)) end)
        pcall(function() Dev.out("anim class", tostring(mesh.AnimClass and mesh.AnimClass:GetFullName())) end)
        pcall(function() Dev.out("mesh visible", tostring(mesh:IsVisible())) end)
    end
end
local car = FindFirstOf("BP_PlayerCarNew_C")
Dev.out("Car", Dev.name(car))
if car and car:IsValid() then
    Dev.out("car loc", Dev.vec(car:K2_GetActorLocation()), "rot", tostring(car:K2_GetActorRotation().Yaw))
    local rc = car.RootComponent
    Dev.out("car root", rc:GetFullName(), "sim", tostring(pcall(function() return rc:IsSimulatingPhysics() end) and rc:IsSimulatingPhysics()))
    pcall(function() Dev.out("car vel", Dev.vec(car:GetVelocity())) end)
end
-- other pawns / characters in the world
local n = 0
for _, c in ipairs(FindAllOf("Character") or {}) do
    if CoopSyncUsable == nil or CoopSyncUsable(c) then n = n + 1 Dev.out("character", c:GetFullName()) end
end
return n
