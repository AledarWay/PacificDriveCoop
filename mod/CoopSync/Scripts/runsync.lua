-- Joining a run with an own save. The host describes its current zone (the leg's MapLocation asset, route
-- profile, modifiers); a guest in its own garage points its next leg at that MapLocation and travels the
-- normal way (TravelToNextLeg), so it arrives on the host's map with its own profile, garage and
-- inventory. Spawn/loot/state/player sync then runs on top as before. Going home is the game's own
-- TravelToGarage, which saves the guest's profile (what it carries included) in its garage.
--   descriptor line: RUN <maplocation path> <route profile path or -> <modifier paths, comma separated or ->
--                    <the leg's junction: its RouteShapeLeg name, or ->
-- The guest travels to the host's own junction (owner's alpha 20 test): its route map is the host's (mapsync), so
-- the same leg keeps both routes the same and the next exit leads both to the same zone. Before, every next leg of
-- the guest was pointed at the host's map and TravelToNextLeg travelled once per route state (five travels in one
-- frame, "concurrent save/load"), and the guest's later junctions all led back to the host's first zone.
local M = {}
local After = CoopSyncAfter or dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "hooks.lua").after -- (never ExecuteWithDelay: hooks.lua)
-- path lookups: the native one answers a miss at once (UE4SS walks every object then: ~50 ms)
local SFO = StaticFindObject
if CoopNative_HasPath then SFO = function(p) if CoopNative_HasPath(p) then return StaticFindObject(p) end return nil end end

-- UE4SS loop that really stops: LoopInGameThreadWithDelay ignores the callback's return value in this build
-- (checked: "return true" after 10 calls -> 210 calls in 3 s), so a loop that "ended" kept running - a test's
-- drive loop kept writing a car's fields after the car was gone with its map, and the game crashed on travel.
-- loop() cancels the delayed action when the callback returns true.
local function loop(ms, fn)
    local h
    h = LoopInGameThreadWithDelay(ms, function()
        -- (an error escaping here made UE4SS drop the loop for good: the co-op menu item never came back, alpha 9)
        local t0 = os.clock()
        local ok, r = pcall(fn)
        if CoopSyncHitch then CoopSyncHitch.spent(os.clock() - t0, "run") end
        if not ok then
            if CoopSyncHitch then CoopSyncHitch.note("loop error: " .. tostring(r):sub(1, 200)) end
            return
        end
        if r == true and h then CancelDelayedAction(h) end
    end)
    return h
end
local function pathOf(o)
    if not (o and o.IsValid and o:IsValid()) then return nil end
    local ok, s = pcall(function() return o:GetFullName() end)
    return ok and (s:gsub("^%S+%s+", "")) or nil
end
local function notDefault(o) return o:IsValid() and not o:GetFullName():find("Default__", 1, true) end

local function routeStates()
    local r = {}
    for _, rs in ipairs(FindAllOf("BaseRouteState") or {}) do
        if notDefault(rs) then r[#r + 1] = rs end
    end
    return r
end

-- The leg the host is in now: the route state whose current leg has a map (in a zone the run's own
-- BP_RouteState_C; the world state's current leg is the garage node and has none).
-- After a leg travel the previous zone's route state can linger with a mapped current leg too: prefer
-- the one whose map is this world (MLoc_<world>).
local function zoneRoute()
    local gi = FindFirstOf("DrivingGameInstance")
    local okW, world = pcall(function() return gi:GetWorld():GetFName():ToString() end)
    local first
    for _, rs in ipairs(routeStates()) do
        local ok, leg, ml = pcall(function() return rs.CurrentLeg, rs.CurrentLeg.MapLocation end)
        if ok and leg and leg:IsValid() and ml and ml:IsValid() then
            if okW and ml:GetFName():ToString() == "MLoc_" .. world then return rs, leg, ml end
            first = first or { rs, leg, ml }
        end
    end
    if first then return first[1], first[2], first[3] end
end
M.zoneRoute = zoneRoute
local function currentZoneLeg()
    local _, leg, ml = zoneRoute()
    return leg, ml
end

-- "seed=<master seed> state=<EGameplayState> world=<map>" (same as cmds/st.lua)
function M.where()
    local gi = FindFirstOf("DrivingGameInstance")
    return string.format("seed=%d state=%d world=%s", gi.MasterSeed, gi.CurrentGameplayState, gi:GetWorld():GetFName():ToString())
end

function M.describe()
    local leg, ml = currentZoneLeg()
    if not leg then return nil, "not in a zone (no current leg with a map)" end
    local mods = {}
    pcall(function()
        for i = 1, #leg.AppliedModifiers do
            local p = pathOf(leg.AppliedModifiers[i])
            if p then mods[#mods + 1] = p end
        end
    end)
    local key = "-"
    pcall(function() key = leg.ShapeLeg:GetFName():ToString() end)
    return string.format("RUN\t%s\t%s\t%s\t%s", pathOf(ml), pathOf(leg.DestinationRoute) or "-", #mods > 0 and table.concat(mods, ",") or "-", key)
end

-- the host's documents: "doc:<name>" = in memory (the in-game network, link.lua), else a file
local function readText(p)
    if CoopSyncRead then return CoopSyncRead(p) end
    local f = p and io.open(p, "rb")
    if not f then return nil end
    local s = f:read("*a") f:close()
    return s
end
local function writeText(p, s)
    if CoopSyncWrite then return CoopSyncWrite(p, s) end
    local f = io.open(p .. ".tmp", "wb")
    if not f then return false end
    f:write(s) f:close()
    os.remove(p)
    return os.rename(p .. ".tmp", p)
end

-- Host: write the descriptor (a document, or a file: tmp + rename so a reader never sees half a file).
function M.publish(path)
    local d, e = M.describe()
    if not d then return "ERR " .. e end
    if not writeText(path, d .. "\n") then return "ERR cannot write " .. path end
    return d
end

local function parse(line)
    local t = {}
    for v in (line .. "\t"):gmatch("([^\t]*)\t") do t[#t + 1] = v end
    if t[1] ~= "RUN" or not t[2] then return nil end
    return { map = t[2], route = t[3] ~= "-" and t[3] or nil, mods = t[4] ~= "-" and t[4] or nil, leg = t[5] ~= "-" and t[5] or nil }
end
M.parse = parse

local function loadObj(p)
    local o = SFO(p)
    if not (o and o:IsValid()) then pcall(function() o = LoadAsset(p) end) end
    return o and o:IsValid() and o or nil
end

-- The zone's gates and where the host arrived (owner's real test: "different exits marked on the map, we appeared
-- at different places"): which level transition is the entrance and which are exits depends on the junction one
-- came from, and the guest's own route differs. The host writes them with its zone, the guest takes them over and
-- its car is put next to the host's.
--   T <transition name> <entrance 0|1> <exit 0|1>
--   C <x> <y> <z> <yaw>   the host's car
local function transitions()
    local r = {}
    for _, e in ipairs(FindAllOf("BP_LevelTransition_Base_C") or {}) do
        local ok, keep = pcall(function()
            return e:IsValid() and not e:GetFullName():find("Default__", 1, true) and not e.IsGarageExit
        end)
        if ok and keep then r[#r + 1] = e end
    end
    return r
end
function M.gates()
    local out = {}
    for _, e in ipairs(transitions()) do
        local en, ex = false, false
        pcall(function() en, ex = e.EntranceActive, e.ExitActive end)
        out[#out + 1] = string.format("T\t%s\t%d\t%d", e:GetFName():ToString(), en and 1 or 0, ex and 1 or 0)
    end
    local car = FindFirstOf("BP_CarManager_C").NewCarActor
    if car and car:IsValid() then
        local l, r = car:K2_GetActorLocation(), car:K2_GetActorRotation()
        out[#out + 1] = string.format("C\t%.1f\t%.1f\t%.1f\t%.1f", l.X, l.Y, l.Z, r.Yaw)
    end
    return out
end
-- (what the host's gates look like now, to send them again when they change - and where its car is, to 10 m: a
-- late guest was put by the car's place at the arrival, the car had moved, the guest's car landed in it - alpha 18
-- item 8, startflow's car watch)
function M.gateSig()
    local t = {}
    for _, l in ipairs(M.gates()) do
        if l:sub(1, 2) == "T\t" then t[#t + 1] = l
        elseif l:sub(1, 2) == "C\t" then
            local x, y = l:match("^C\t(%S+)\t(%S+)")
            t[#t + 1] = string.format("C%d,%d", math.floor((tonumber(x) or 0) / 1000), math.floor((tonumber(y) or 0) / 1000))
        end
    end
    return table.concat(t, "|")
end
function M.publishGates(path)
    if not writeText(path, table.concat(M.gates(), "\n") .. "\n") then return "ERR cannot write " .. path end
    return "gates published"
end
M.stats = M.stats or {}
-- Guest: the host's gates on this side's transitions (same level, same names), then its own car next to the host's
-- (5 m to the side) when it is further than NEAR_CM - or closer than CLASH_CM: in the host's car (the twins of the two
-- overlapping threw the host's car 65 m up, startflow late join). ownCar: the guest's car (not a twin).
local NEAR_CM, CLASH_CM = 4000, 450
function M.applyGates(path, ownCar, keepCar)
    local data = readText(path)
    if not data then return "no gates file" end
    local byName = {}
    for _, e in ipairs(transitions()) do byName[e:GetFName():ToString()] = e end
    local set, host = 0, nil
    for line in data:gmatch("[^\r\n]+") do
        local t = {}
        for v in (line .. "\t"):gmatch("([^\t]*)\t") do t[#t + 1] = v end
        if t[1] == "T" then
            local e = byName[t[2]]
            if e then
                local en, ex = t[3] == "1", t[4] == "1"
                local hen, hex = false, false
                pcall(function() hen, hex = e.EntranceActive, e.ExitActive end)
                if hen ~= en or hex ~= ex then
                    pcall(function()
                        if ex then e:SetExit(false) elseif en then e:SetEntrance() else e:SetClosed() end
                    end)
                    set = set + 1
                end
            end
        elseif t[1] == "C" then
            host = { X = tonumber(t[2]), Y = tonumber(t[3]), Z = tonumber(t[4]), Yaw = tonumber(t[5]) }
        end
    end
    local moved = "car stays"
    if host and ownCar and ownCar:IsValid() and not keepCar then
        local l = ownCar:K2_GetActorLocation()
        local d = math.sqrt((l.X - host.X) ^ 2 + (l.Y - host.Y) ^ 2)
        if d > NEAR_CM or d < CLASH_CM then
            local a = math.rad(host.Yaw + 90)
            local to = { X = host.X + math.cos(a) * 500, Y = host.Y + math.sin(a) * 500, Z = host.Z + 60 }
            local root = ownCar.RootComponent
            pcall(function() root:SetSimulatePhysics(false) end)
            ownCar:K2_SetActorLocationAndRotation(to, { Pitch = 0, Yaw = host.Yaw, Roll = 0 }, false, {}, true)
            local path = (ownCar:GetFullName():gsub("^%S+ ", ""))
            After(300, function()
                local c = SFO(path)
                if c and c:IsValid() then pcall(function()
                    local r = c.RootComponent
                    r:SetSimulatePhysics(true)
                    r:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName("None"))
                    r:SetPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false, FName("None"))
                end) end
            end)
            moved = string.format("car moved %.0f m to the host's", d / 100)
            M.stats.carMoved = (M.stats.carMoved or 0) + 1
        end
    end
    M.stats.gatesSet = (M.stats.gatesSet or 0) + set
    return string.format("gates: %d set, %s", set, moved)
end

-- The host's map location from a descriptor file (nil when there is none yet).
function M.hostMapLocation(descPath)
    local s = readText(descPath)
    if not s then return nil end
    local d = parse(s:match("^[^\r\n]*") or "")
    return d and loadObj(d.map) or nil
end

-- Guest: the leg to travel to for the host's zone, on the route state the travel goes through.
--   1. the host's own junction (descriptor's leg: its RouteShapeLeg) in the main route (the garage map: the progression
--      manager's WorldState), then in the run's route and the others: the same junction keeps both routes the same;
--   2. none (an old host, a new game's route without it): the first leg it could drive to next.
-- The one leg gets the host's MapLocation when its own differs (a junction's level is the host's anyway: mapsync).
local function legKey(l)
    local ok, k = pcall(function() return l.ShapeLeg:GetFName():ToString() end)
    return ok and k or nil
end
local function candidates()
    local r, seen = {}, {}
    local function add(rs) if rs and rs:IsValid() and not seen[rs:GetFullName()] then seen[rs:GetFullName()] = true r[#r + 1] = rs end end
    pcall(function() add(FindFirstOf("BP_ProgressionManager_C").WorldState) end)
    add((zoneRoute()))
    for _, rs in ipairs(routeStates()) do add(rs) end
    return r
end
function M.pickLeg(d)
    local routes = candidates()
    if d.leg then
        for _, rs in ipairs(routes) do
            local found
            pcall(function()
                rs.LegStates:ForEach(function(k, v)
                    if not found and k:get():GetFName():ToString() == d.leg then found = v:get() end
                end)
            end)
            if found and found:IsValid() then return rs, found, "host's junction " .. d.leg end
        end
    end
    for _, rs in ipairs(routes) do
        local cur = rs.CurrentLeg
        for _, l in ipairs(FindAllOf("BaseLegState") or {}) do
            local ok, isCand = pcall(function()
                return l:GetOuter():GetFullName() == rs:GetFullName() and l.Active and not l.Visited
                    and not (cur and cur:IsValid() and l:GetFullName() == cur:GetFullName())
            end)
            if ok and isCand then return rs, l, "next leg " .. tostring(legKey(l)) .. " (host's junction " .. tostring(d.leg) .. " not here)" end
        end
    end
end
-- one travel (BaseRouteState:TravelTo, what a pick on the map does) to the host's zone
function M.travelTo(desc)
    local d = parse(desc or "")
    if not d then return nil, "bad descriptor" end
    local ml = loadObj(d.map)
    if not ml then return nil, "map location not found: " .. d.map end
    local rs, leg, how = M.pickLeg(d)
    if not rs then return nil, "no leg to travel to" end
    local same = false
    pcall(function() same = leg.MapLocation and leg.MapLocation:IsValid() and leg.MapLocation:GetFullName() == ml:GetFullName() end)
    if not same then leg:OverrideMapLocation(ml) end
    M.stats.travels = (M.stats.travels or 0) + 1
    M.stats.lastTravel = how
    -- (the guest's garage map hooks return values - ShouldBeVisibleOnMap, session.lua; one of them run inside this call
    -- broke its return: "StrProperty can only be set to a string", the join failed, retried and travelled twice -
    -- quick suite 2026-11-08, startflow / nextzone. They keep out while this travel runs)
    CoopSyncTravelling = true
    local okT, eT = pcall(function() rs:TravelTo(leg, 0) end)
    CoopSyncTravelling = false
    if not okT then error(eT, 0) end
    return string.format("%s%s -> %s", how, same and "" or " (map set)", d.map:match("[^/]+$") or d.map)
end

-- Guest, in its garage: drive out to the host's zone.
function M.join(descPath)
    local s = readText(descPath)
    if not s then return "ERR no descriptor at " .. descPath end
    local line = s:match("^[^\r\n]*") or ""
    -- guest mode: the own car must come home as it left (see insureCar; the CoopSync mod restores it)
    local ins = M.insureCar(M.insuranceFile())
    local r, e = M.travelTo(line)
    if not r then return "ERR " .. e end
    return "joining: " .. r .. "; " .. ins
end

-- Guest, in a zone: follow the host to the zone of a new descriptor (the host's junction; a new game's first zone
-- has no next leg of its own, but any unvisited leg given the host's MapLocation loads it - probed: first zone ->
-- Rooster_11, 20 s).
function M.follow(desc)
    local r, e = M.travelTo(desc)
    if not r then return "ERR " .. e end
    return "following the host: " .. r
end

-- Guest: back to its own garage. directLoad = true skips the game's "rinse" (save + reload); observed:
-- then nothing is saved and a reload resumes from the departure save.
function M.goHome(directLoad, returnState)
    local pm = FindFirstOf("BP_ProgressionManager_C")
    local out = {}
    pm:TravelToGarage(returnState or 0, directLoad == true, false, false, 1, out)
    return string.format("travelling home (direct=%s state=%d), success=%s", tostring(directLoad == true), returnState or 0, tostring(out.Success))
end

-- every USlotSceneComponent property of BP_PlayerCarNew_C (from the class dump)
local CAR_SLOTS = {
    "SLOT_Internal_GoldenGobbler",
    "SLOT_Windshield",
    "SLOT_Interior_EngineBayUpgrade",
    "SLOT_Internal_ReserveBattery",
    "SLOT_Internal_ReserveGas",
    "SLOT_GasCanAttachPoint",
    "SLOT_Essential_ChargePort",
    "SLOT_Cosmetic_Antenna",
    "SLOT_Cosmetic_HoodOrnament",
    "SLOT_Cosmetic_StickerR",
    "SLOT_Cosmetic_StickerL",
    "SLOT_Cosmetic_LicensePlate",
    "SLOT_Cosmetic_GearboxShifter",
    "SLOT_Internal_Upgrade_Side_L",
    "SLOT_Internal_Upgrade_Side_R",
    "SLOT_Internal_Upgrade_Roof_R",
    "SLOT_Internal_Upgrade_Roof_F",
    "SLOT_Internal_CarFriend",
    "SLOT_Mirror",
    "SLOT_Cosmetic_SteeringWheel",
    "SLOT_Internal_Gobbler",
    "SLOT_Internal_GobblerScreen",
    "SLOT_Interior_SmallGadgetRight",
    "SLOT_Internal_Speedometer",
    "SLOT_Internal_RadBox",
    "SLOT_Internal_Compass",
    "SLOT_Internal_LimBox",
    "SLOT_Internal_HealthBox",
    "SLOT_Internal_StatusBox",
    "SLOT_Interior_SmallGadgetLeft",
    "SLOT_Internal_Radio",
    "SLOT_Internal_Computer",
    "SLOT_Attach_Side_RR",
    "SLOT_Attach_Side_FR",
    "SLOT_Attach_Side_FL",
    "SLOT_Bumper_R",
    "SLOT_Internal_Soul",
    "SLOT_TrunkStorage",
    "SLOT_TrunkCrafting",
    "SLOT_Essential_Gascap",
    "SLOT_Panel_RR",
    "SLOT_Panel_RL",
    "SLOT_Panel_FR",
    "SLOT_Panel_FL",
    "SLOT_Interior_RR_Wheel",
    "SLOT_Interior_FL_Wheel",
    "SLOT_Interior_FR_Wheel",
    "SLOT_Interior_RL_Wheel",
    "SLOT_Cosmetic_BobbleHead",
    "SLOT_BrakePads",
    "SLOT_Suspension",
    "SLOT_BackSeatRight",
    "SLOT_Interior_Engine",
    "SLOT_LeftHeadlight",
    "SLOT_RightHeadlight",
    "SLOT_BackSeatLeft",
    "SLOT_RearRightDoor",
    "SLOT_RoofTopRear",
    "SLOT_RoofTopFront",
    "SLOT_RearLeftDoor",
    "SLOT_Attach_Side_RL",
    "SLOT_Bumper_F",
    "SLOT_Interior_Large_01",
    "SLOT_FrontRightDoor",
    "SLOT_FrontLeftDoor",
    "SLOT_Hood",
    "SLOT_Trunk"
}

-- The local car's state, one line per item: every item slot of the car (equipment, seat frames, parts)
-- and the trunk, "<where>\t<archetype>\t<data block dump>", sorted; written to path (for before/after diffs).
function M.carState(path)
    local car
    for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
        if c:IsValid() and c:GetFullName():find(":PersistentLevel.", 1, true) then car = c end
    end
    if not car then return "ERR no car" end
    local lines = {}
    local function item(where, it)
        if not (it and it:IsValid()) then return end
        local arch = it.Archetype:IsValid() and it.Archetype:GetFName():ToString() or "?"
        local ok, dump = pcall(function() return it:GetDataBlockDump():ToString() end)
        if not ok then ok, dump = pcall(function() return tostring(it:GetDataBlockDump()) end) end
        dump = ok and tostring(dump):gsub("[\r\n\t]+", " ") or "?"
        lines[#lines + 1] = where .. "\t" .. arch .. "\t" .. dump
    end
    -- (K2_GetComponentsByClass came back empty here; the slots are named properties of the car BP)
    for _, name in ipairs(CAR_SLOTS) do
        pcall(function()
            local sl = car[name].ItemSlot -- (never read FilterItemType: garbage on empty slots, crashes)
            for j = 1, sl.Items:GetArrayNum() do item(name, sl.Items[j]) end
        end)
    end
    local im = FindFirstOf("BP_InventoryManager_C")
    for _, field in ipairs({ "Inventory_Trunk", "Inventory_LargeTrunk" }) do
        pcall(function()
            local cont = im[field]
            for i = 1, cont.Slots:GetArrayNum() do
                local s = cont.Slots[i]
                for j = 1, s.Items:GetArrayNum() do item(field, s.Items[j]) end
            end
        end)
    end
    table.sort(lines)
    local f = io.open(path, "wb")
    if f then f:write(table.concat(lines, "\n") .. "\n") f:close() end
    return #lines .. " car items"
end

-- Guest-mode car insurance. In guest mode the guest's own car stays home in spirit: what is installed in it
-- and what lies in its trunk must come back unchanged. Observed: dying in the host's zone makes the game take
-- car parts too (the base battery off a seat frame, a wheel). So the guest records its car before leaving
-- (slot property, slot name, archetype path; trunk archetype counts) and, back in its garage, puts back
-- whatever is missing (new instances of the same archetypes: full durability, see NOTES) and saves.
local function liveCar()
    for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
        if c:IsValid() and c:GetFullName():find(":PersistentLevel.", 1, true) then return c end
    end
end
local function objPath(o) return (o:GetFullName():gsub("^%S+%s+", "")) end
local TRUNKS = { "Inventory_Trunk", "Inventory_LargeTrunk" }
-- survives reloads of this module (every test command dofile()s it): insurance path, watcher, last result
CoopSyncRun = CoopSyncRun or {}
local R = CoopSyncRun

function M.insureCar(path)
    local car = liveCar()
    if not car then return "ERR no car" end
    local lines, n = {}, 0
    for _, prop in ipairs(CAR_SLOTS) do
        pcall(function()
            local sl = car[prop].ItemSlot
            if sl.Items:GetArrayNum() > 0 then
                lines[#lines + 1] = string.format("S\t%s\t%s\t%s", prop, sl.SlotName:ToString(), objPath(sl.Items[1].Archetype))
                n = n + 1
            end
        end)
    end
    local im = FindFirstOf("BP_InventoryManager_C")
    for _, field in ipairs(TRUNKS) do
        local counts = {}
        pcall(function()
            local c = im[field]
            for i = 1, c.Slots:GetArrayNum() do
                local s = c.Slots[i]
                for j = 1, s.Items:GetArrayNum() do local p = objPath(s.Items[j].Archetype) counts[p] = (counts[p] or 0) + 1 end
            end
        end)
        for p, k in pairs(counts) do lines[#lines + 1] = string.format("T\t%s\t%s\t%d", field, p, k) end
    end
    local f = io.open(path, "wb")
    if not f then return "ERR cannot write " .. path end
    f:write("#written\t" .. os.time() .. "\n" .. table.concat(lines, "\n") .. "\n") f:close()
    R.insurancePath = path
    return string.format("insured %d car items + trunk", n)
end

local function newItem(archPath)
    local arch = SFO(archPath)
    if not (arch and arch:IsValid()) then pcall(function() arch = LoadAsset(archPath) end) end
    if not (arch and arch:IsValid()) then return nil end
    local ibl = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
    -- create context 1 = what the car's own parts carry; observed: instances made with 0 (Unknown) were not
    -- written to the save (installed fine, gone after the next load), with 1 they persist
    local inst = ibl:CreateItemInstance(FindFirstOf("PlayerController"), arch, 1)
    return inst and inst:IsValid() and inst or nil
end

function M.restoreCar(path)
    path = path or R.insurancePath
    local f = path and io.open(path, "rb")
    if not f then return "ERR no insurance record" end
    local car = liveCar()
    if not car then f:close() return "ERR no car" end
    local im = FindFirstOf("BP_InventoryManager_C")
    local eqOut = {}
    im:GetCarEquippedContainer(eqOut)
    local eq = eqOut.Inventory_CarEquipped
    local put, failed, want = {}, {}, {}
    for line in f:lines() do
        local t = {}
        for v in (line .. "\t"):gmatch("([^\t]*)\t") do t[#t + 1] = v end
        if t[1] == "S" then
            local have = 0
            pcall(function() have = car[t[2]].ItemSlot.Items:GetArrayNum() end)
            if have == 0 then
                local inst = newItem(t[4])
                local ok = inst and pcall(function() eq:AddItem(FName(t[3]), inst, false) end)
                if ok then put[#put + 1] = t[2] else failed[#failed + 1] = t[2] end
            end
        elseif t[1] == "T" then
            want[t[2]] = want[t[2]] or {}
            want[t[2]][t[3]] = tonumber(t[4]) or 0
        end
    end
    f:close()
    for field, archs in pairs(want) do
        local have = {}
        pcall(function()
            local c = im[field]
            for i = 1, c.Slots:GetArrayNum() do
                local s = c.Slots[i]
                for j = 1, s.Items:GetArrayNum() do local p = objPath(s.Items[j].Archetype) have[p] = (have[p] or 0) + 1 end
            end
        end)
        for p, n in pairs(archs) do
            for _ = 1, n - (have[p] or 0) do
                local inst = newItem(p)
                local ok = inst and pcall(function() im[field]:AddItem(inst, true) end)
                if ok then put[#put + 1] = field .. ":" .. (p:match("[^.]+$") or p) else failed[#failed + 1] = field .. ":" .. p end
            end
        end
    end
    -- Always save again (AUTOSAVE): observed after a death that the car at home was complete but the save the
    -- game wrote on arrival already missed two random parts (a reload showed them gone), so the intact car
    -- has to be written over that save.
    local sgm = FindFirstOf("BP_SaveGameManager_C")
    local okS = pcall(function() sgm:SaveGame(sgm.CurrentSaveSlot, "", 2) end)
    R.resaved = okS
    return string.format("put back %d (%s) failed %d (%s) resaved=%s", #put, table.concat(put, ","), #failed, table.concat(failed, ","), tostring(okS))
end

-- Where the insurance record and its log live: the profile's Saved directory (respects -userdir), so the
-- CoopSync mod (its own Lua state, runs every session) and the commands that start a run share it.
function M.insuranceFile()
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local ok, dir = pcall(function() return ksl:GetProjectSavedDirectory():ToString() end)
    if not ok then return nil end
    return dir .. "CoopSyncGuestCar.tsv"
end
local function logRestore(s)
    R.lastRestore = s
    local p = M.insuranceFile()
    local f = p and io.open(p .. ".log", "ab")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S ") .. s .. "\n") f:close() end
end

-- The CoopSync mod runs this every session. On each garage entry with an insurance record present, the
-- car is completed from it and saved. Observed after a guest death: the game takes 2 random parts, and
-- takes the same slots again on every later load of that save (even after they were put back and saved;
-- new parts made the same way survive loads when there was no death) — the save keeps the lost run's
-- result. So the record stays armed for every garage entry and is settled only when the player drives out
-- again: a new co-op join writes a fresh record just before that; a solo departure removes it.
local function recordAge(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local first = f:read("*l") or ""
    f:close()
    local ts = tonumber(first:match("^#written\t(%d+)"))
    return ts and (os.time() - ts) or 1e9
end
function M.watch()
    if R.watchOn then return "already watching" end
    R.watchOn = true
    local prev, lastStable, pending
    loop(1000, function()
        local ok, s = pcall(function() return FindFirstOf("DrivingGameInstance").CurrentGameplayState end)
        if not ok or not s then return end
        if s ~= prev then
            local p = M.insuranceFile()
            local age = p and recordAge(p)
            if s == 4 and prev ~= nil and prev ~= 4 and age then
                -- give the garage a few seconds to finish building the car
                pending = { at = os.clock() + 6, fromRun = (lastStable == 5 or lastStable == 6), path = p }
            elseif s == 5 and lastStable == 4 and age and age > 120 then
                os.remove(p) -- driving out solo: the guest-mode cover ends (a join would have just rewritten it)
                logRestore("left the garage without a co-op join: record settled")
            end
            if s ~= 2 then lastStable = s end -- 2 = LOADING sits between every two states
            prev = s
        end
        if pending and os.clock() >= pending.at then
            local q = pending
            pending = nil
            local okR, r = pcall(M.restoreCar, q.path)
            logRestore((q.fromRun and "after the run: " or "after a load: ") .. (okR and r or ("ERR " .. tostring(r))))
        end
    end)
    return "watching garage entries for the guest car insurance"
end
function M.lastRestore()
    local p = M.insuranceFile()
    local f = p and io.open(p .. ".log", "rb")
    if not f then return "no log" end
    local last
    for line in f:lines() do last = line end
    f:close()
    return tostring(last)
end
function M.insured()
    local p = M.insuranceFile()
    local f = p and io.open(p, "rb")
    if f then f:close() return "armed" end
    return "none"
end

-- What the local player carries (backpack + hand), as "archetype xN" sorted; for the tests.
function M.inventory()
    local im = FindFirstOf("BP_InventoryManager_C")
    if not (im and im:IsValid()) then return "no inventory manager" end
    local counts = {}
    for _, field in ipairs({ "Inventory_Player", "Inventory_PlayerHand" }) do
        pcall(function()
            local c = im[field]
            for i = 1, c.Slots:GetArrayNum() do
                local slot = c.Slots[i]
                for j = 1, slot.Items:GetArrayNum() do
                    local a = slot.Items[j].Archetype
                    local n = a and a:IsValid() and a:GetFName():ToString() or "?"
                    counts[n] = (counts[n] or 0) + 1
                end
            end
        end)
    end
    local r = {}
    for k, v in pairs(counts) do r[#r + 1] = k .. "x" .. v end
    table.sort(r)
    return #r > 0 and table.concat(r, ",") or "empty"
end

return M
