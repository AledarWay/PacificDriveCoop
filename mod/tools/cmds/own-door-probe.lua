-- The own car's door N: OD_STEP = "open" | "shut" | "read"; MainMesh car-relative yaw, physics, DoorOpen
local car = _G.CoopPlayers and _G.CoopPlayers.ownCarActor() or nil
if not car then for _, x in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if x:IsValid() and x:GetFullName():find(":PersistentLevel.", 1, true) then car = x break end end end
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local D = { { 131, -94 }, { 131, 94 }, { 8, -94 }, { 8, 94 }, { -194, 0 } }
local n = OD_DOOR or 2
local door
for _, d in ipairs(FindAllOf("BP_CarPart_Door_Base_C") or {}) do
    local par = d:GetAttachParentActor()
    if d:IsValid() and par and par:IsValid() and par:GetAddress() == car:GetAddress() then
        local l = KML:InverseTransformLocation(car:GetTransform(), d:K2_GetActorLocation())
        if math.abs(l.X - D[n][1]) < 25 and math.abs(l.Y - D[n][2]) < 25 then door = d end
    end
end
if not door then return "no door" end
local step = OD_STEP or "read"
if step == "open" then door:AttemptOpen() elseif step == "shut" then door:AttemptShut() end
local m = door.MainMesh
local inv = KML:InvertTransform(car:GetTransform())
local rel = KML:ComposeTransforms(m:K2_GetComponentToWorld(), inv)
local r = KML:Quat_Rotator(rel.Rotation)
local ar = KML:ComposeTransforms(door:GetTransform(), inv)
local rr = KML:Quat_Rotator(ar.Rotation)
return string.format("%s %s mesh %.0f,%.0f,%.0f p%.0f y%.0f r%.0f actor y%.0f sim=%s DoorOpen=%s cls=%s", step, door:GetFName():ToString(), rel.Translation.X, rel.Translation.Y, rel.Translation.Z,
    r.Pitch, r.Yaw, r.Roll, rr.Yaw, tostring(m:IsSimulatingPhysics(FName("None"))), tostring(door.DoorOpen), door:GetClass():GetFName():ToString())
