-- The local character's own leg bones in car space (the game's real seated pose: where the feet rest on the floor)
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local pawn = FindFirstOf("PlayerController").Pawn
local car = pawn:GetAttachParentActor()
if not (car and car:IsValid()) then return "not in a car" end
local xf = car:GetTransform()
local m = pawn.Mesh
local o = { "anim=" .. tostring(m.AnimScriptInstance and m.AnimScriptInstance:IsValid() and m.AnimScriptInstance:GetClass():GetFName():ToString()), "visible=" .. tostring(m:IsVisible()) }
for _, b in ipairs({ "pelvis", "thigh_l", "calf_l", "foot_l", "ball_l", "foot_r", "ball_r" }) do
    local ok, v = pcall(function() return KML:InverseTransformLocation(xf, m:GetSocketLocation(FName(b))) end)
    o[#o + 1] = ok and string.format("%s=%.0f,%.0f,%.0f", b, v.X, v.Y, v.Z) or (b .. "=?")
end
return table.concat(o, " ")
