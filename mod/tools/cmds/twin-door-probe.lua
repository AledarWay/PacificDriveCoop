-- On the side that has a twin of the other's car: TD_STEP = "list" | "open" | "shut" | "enter" | "where", TD_DOOR = n
local own = _G.CoopPlayers.ownCarActor()
local twin
for _, x in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
    if x:IsValid() and own and x:GetAddress() ~= own:GetAddress() then twin = x end
end
if not twin then return "no twin" end
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local D = { { 131, -94 }, { 131, 94 }, { 8, -94 }, { 8, 94 } }
local doors = {}
for _, d in ipairs(FindAllOf("BP_CarPart_Door_Base_C") or {}) do
    local par = d:GetAttachParentActor()
    if d:IsValid() and par and par:IsValid() and par:GetAddress() == twin:GetAddress() then
        local l = KML:InverseTransformLocation(twin:GetTransform(), d:K2_GetActorLocation())
        for n, p in ipairs(D) do if math.abs(l.X - p[1]) < 25 and math.abs(l.Y - p[2]) < 25 then doors[n] = d end end
    end
end
local function rot(d)
    local m = d.MainMesh
    local r = m and m:IsValid() and m:K2_GetComponentRotation() or d:K2_GetActorRotation()
    local tr = twin:K2_GetActorRotation()
    return string.format("yaw%+.0f sim=%s", r.Yaw - tr.Yaw, tostring(m and m:IsValid() and m:IsSimulatingPhysics(FName("None"))))
end
local step, n = TD_STEP or "list", TD_DOOR or 2
local door = doors[n]
if step == "list" then
    local o = {}
    for i = 1, 4 do o[#o + 1] = i .. ":" .. (doors[i] and rot(doors[i]) or "-") end
    return table.concat(o, " ")
end
if not door then return "no door " .. n end
local pawn = FindFirstOf("PlayerController").Pawn
if step == "open" then door:AttemptOpen() return "open " .. rot(door) end
if step == "shut" then door:AttemptShut() return "shut " .. rot(door) end
if step == "enter" then
    local cm = FindFirstOf("BP_CarManager_C")
    cm.NewCarActor = twin
    local path = door:GetFullName():gsub("^%S+%s+", "")
    door:AttemptOpen()
    door:StartEntry(true)
    Dev.after(200, function()
        local d = StaticFindObject(path)
        local p = FindFirstOf("PlayerController").Pawn
        p:CommandEnterCar(false, d, false)
    end)
    return "entering by " .. door:GetFName():ToString()
end
if step == "where" then
    local l = KML:InverseTransformLocation(twin:GetTransform(), pawn:K2_GetActorLocation())
    local par = pawn:GetAttachParentActor()
    return string.format("pawn %.0f,%.0f,%.0f parent=%s door %s", l.X, l.Y, l.Z, par and par:IsValid() and (par:GetAddress() == twin:GetAddress() and "twin" or par:GetFName():ToString()) or "-", rot(door))
end
return "?"
