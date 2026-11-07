-- Enter the local car through door N (1 FL, 2 FR, 3 RL, 4 RR) the way the driver door does: AttemptOpen,
-- StartEntry(true), CommandEnterCar(false, door, false) 0.2 s later.
local n = ENTER_DOOR or 2
local car
for _, x in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if x:IsValid() and x:GetFullName():find(":PersistentLevel.", 1, true) then car = x break end end
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local D = { { 131, -94 }, { 131, 94 }, { 8, -94 }, { 8, 94 } }
local door
for _, d in ipairs(FindAllOf("BP_CarPart_Door_Base_C") or {}) do
    local par = d:GetAttachParentActor()
    if d:IsValid() and par and par:IsValid() and par:GetAddress() == car:GetAddress() then
        local l = KML:InverseTransformLocation(car:GetTransform(), d:K2_GetActorLocation())
        if math.abs(l.X - D[n][1]) < 20 and math.abs(l.Y - D[n][2]) < 20 then door = d end
    end
end
if not door then return "no door " .. n end
local path = door:GetFullName():gsub("^%S+%s+", "")
door:AttemptOpen()
door:StartEntry(true)
Dev.after(200, function()
    local d = StaticFindObject(path)
    local p = FindFirstOf("PlayerController").Pawn
    p:CommandEnterCar(false, d, false)
end)
return "entering by " .. door:GetFName():ToString()
