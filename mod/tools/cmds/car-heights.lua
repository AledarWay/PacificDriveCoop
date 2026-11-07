-- car-local heights: wheel centres, the main meshes' local bounds (min Z / max Z), the ground (character standing
-- next to the car: capsule centre - half height)
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local car = _G.CoopPlayers and _G.CoopPlayers.ownCarActor() or FindFirstOf("BP_PlayerCarNew_C")
local xf = car:GetTransform()
local o = {}
for _, n in ipairs({ "FrontLeftWheel_Mesh", "RearLeftWheel_Mesh", "Interior", "Chassis", "Mesh", "Body", "ChassisMesh" }) do
    pcall(function()
        local c = car[n]
        if not (c and c:IsValid()) then return end
        local l = KML:InverseTransformLocation(xf, c:K2_GetComponentLocation())
        local s = string.format("%s at Z %.0f", n, l.Z)
        pcall(function()
            local mn, mx = {}, {}
            c:GetLocalBounds(mn, mx)
            s = s .. string.format(" bounds Z %.0f..%.0f X %.0f..%.0f", mn.Z, mx.Z, mn.X, mx.X)
        end)
        o[#o + 1] = s
    end)
end
local pawn = FindFirstOf("PlayerController").Pawn
local l = KML:InverseTransformLocation(xf, pawn:K2_GetActorLocation())
local hh = 0 pcall(function() hh = pawn.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
o[#o + 1] = string.format("pawn at car-local %.0f,%.0f,%.0f half height %.0f -> feet %.0f", l.X, l.Y, l.Z, hh, l.Z - hh)
return table.concat(o, "\n")
