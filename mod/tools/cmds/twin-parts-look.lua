-- After twin-container-probe: the twin's spawned parts (slot -> part class, attached to the twin?), whether the own
-- car's slots still use the game's container, and what the game highlights when the character looks at a twin part.
-- LOOK_SLOT (substring of a slot name, default "Wheel") picks the part; LOOK_OWN = true looks at the own car's instead.
local T = _G.CoopPlayers.twinModule()
local SSC = StaticFindObject("/Script/PenDriverInventory.SlotSceneComponent")
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local o = {}
local twin
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then twin = c end end
local own = T.ownCar()
if not (twin and own) then return "no twin / own car" end
local function rootOf(a)
    local cur, g = a, 0
    while g < 10 do
        local p = cur:GetAttachParentActor()
        if not (p and p:IsValid()) then return cur end
        cur, g = p, g + 1
    end
    return cur
end
local function slots(car)
    local t, outerSet = {}, {}
    local comps = car:K2_GetComponentsByClass(SSC)
    for i = 1, #comps do
        local s = comps[i]:get()
        pcall(function()
            local sl = s.ItemSlot
            if sl and sl:IsValid() then outerSet[sl:GetOuter():GetFName():ToString()] = true end
            local a = s.SpawnedActor
            if a and a:IsValid() then
                t[#t + 1] = { name = s.SlotName.TagName:ToString(), actor = a, comp = s, cls = a:GetClass():GetFName():ToString(),
                    onCar = rootOf(a):GetAddress() == car:GetAddress(), items = sl and sl:IsValid() and sl.Items:GetArrayNum() or -1 }
            end
        end)
    end
    local ol = {} for k in pairs(outerSet) do ol[#ol + 1] = k end
    return t, table.concat(ol, ",")
end
local ts, touter = slots(twin)
local os_, oouter = slots(own)
local onCar = 0 for _, x in ipairs(ts) do if x.onCar then onCar = onCar + 1 end end
o[#o + 1] = string.format("twin: %d spawned (%d on the twin), slot containers: %s", #ts, onCar, touter)
o[#o + 1] = string.format("own: %d spawned, slot containers: %s", #os_, oouter)
o[#o + 1] = "ghost: " .. _G.CoopPlayers.ghostInfo():match("broken_links=%S+")
local pick = LOOK_SLOT or "Wheel"
local list = LOOK_OWN and os_ or ts
local target
for _, x in ipairs(list) do
    if not target and x.name:find(pick, 1, true) and (x.items > 0 or LOOK_EMPTY) then target = x end
end
if LIST_SLOTS then for _, x in ipairs(ts) do o[#o + 1] = "  " .. x.name .. " " .. x.cls .. " items=" .. x.items end end
if not target then return table.concat(o, "\n") .. "\nno part for " .. pick end
local car = LOOK_OWN and own or twin
local at = LOOK_AT_SLOT and target.comp:K2_GetComponentLocation() or target.actor:K2_GetActorLocation()
at.Z = at.Z + (LOOK_DZ or 0)
-- (a back door's actor stands at its hinge, the front edge; its highlight box is centred 32-40 behind it: aimed at the
-- hinge the line passed the box's edge and lit the seat slots' boxes inside - LOOK_DX moves the aim along the car)
local ldx = LOOK_DX or ((pick:find("DoorsRL", 1, true) or pick:find("DoorsRR", 1, true)) and -32 or 0)
LOOK_DX = nil
if ldx ~= 0 then
    local f = car:GetActorForwardVector()
    at.X, at.Y = at.X + f.X * ldx, at.Y + f.Y * ldx
end
-- (beside the part by the car's yaw only, at the part's height: in the car's full transform a car on its side or roof
-- put the character under the ground - it fell and died, the game took it home; soak test 2026-10-28)
if car:GetActorUpVector().Z < 0.7 and not LOOK_TILTED then return table.concat(o, "\n") .. "\nthe car is tilted: not going there" end
local yaw = math.rad(car:K2_GetActorRotation().Yaw)
local c0 = car:K2_GetActorLocation()
local rx, ry = -math.sin(yaw), math.cos(yaw) -- the car's right, flat
local side = ((at.X - c0.X) * rx + (at.Y - c0.Y) * ry) >= 0 and 1 or -1
local stand = { X = at.X + rx * side * 150, Y = at.Y + ry * side * 150, Z = at.Z + 60 }
-- (the trunk lid: from behind the car - from the side the body is in the way)
if pick:find("Trunk", 1, true) or LOOK_BEHIND then
    local fx, fy = math.cos(yaw), math.sin(yaw)
    stand = { X = at.X - fx * 170, Y = at.Y - fy * 170, Z = at.Z + 40 }
end
local pc = FindFirstOf("PlayerController")
pc.Pawn:K2_SetActorLocation(stand, false, {}, true)
local eye = pc.Pawn:K2_GetActorLocation() eye.Z = eye.Z + 60
local d = { X = at.X - eye.X, Y = at.Y - eye.Y, Z = at.Z - eye.Z }
pc:SetControlRotation({ Pitch = math.deg(math.atan(d.Z, math.sqrt(d.X * d.X + d.Y * d.Y))), Yaw = math.deg(math.atan(d.Y, d.X)), Roll = 0 })
-- (again from the real camera once the character stood on the ground: the eye above the spot it was put at was 60+ too
-- high - the look went under a back door's box; reference-save backseat test 2026-11-14)
if Dev and Dev.after then
    Dev.after(400, function()
        local q = FindFirstOf("PlayerController")
        if not (q and q:IsValid()) then return end
        local e = q.PlayerCameraManager:GetCameraLocation()
        local v = { X = at.X - e.X, Y = at.Y - e.Y, Z = at.Z - e.Z }
        q:SetControlRotation({ Pitch = math.deg(math.atan(v.Z, math.sqrt(v.X * v.X + v.Y * v.Y))), Yaw = math.deg(math.atan(v.Y, v.X)), Roll = 0 })
    end)
end
_G.PartLook = { slot = target.name, cls = target.cls }
return table.concat(o, "\n") .. string.format("\nlooking at %s (%s) of the %s", target.name, target.cls, LOOK_OWN and "own car" or "twin")
