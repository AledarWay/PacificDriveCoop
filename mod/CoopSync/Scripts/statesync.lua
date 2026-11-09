-- State sync after load: the host is the authority for every interaction with replicated actors.
--
-- Host, every tick: snapshot all replicated roots (key -> loot string), diff with the previous
-- snapshot and send events to the client:
--   U <key> <loot>          loot / opened state changed
--   D <key>                 actor is gone (picked up, broken, ...)
--   S <spawnlist row>       new actor (e.g. a dropped item or a detached part lying on the ground)
--   M <key> x y z p y r     an actor moved on the host (physics, AI); the client teleports its copy
-- Client, every tick: apply host events; detect its own local changes on mapped actors and turn
-- them into requests the host decides on:
--   OPEN <key>                      container was opened (host opens it and rolls the on-open loot)
--   TAKE <key> <archetype> <count>  items were taken out of a container
--   PUT <key> <item spec> <count>   items were put into a container
--   PICK <key>                      a world item was picked up
--   DETACH <key> <socket>           a part was taken off a car wreck
--   RG <key> 1|0 [<phase> <dir>]   a range-started hazard (saw, geyser) started / stopped (RANGE: host -> guest)
--   TP / TS ...                     a tourist's pose (host -> guest) / sway (both ways) (TOUR)
--   FUEL <key> <fuel>               a fuel barrel's fuel (both ways)
--   KB / KK ...                     a breakable was broken / kicked (KNOCK: both ways, by class and place)
--   EXIT <key>                      the zone's exit portal was picked on the ARC (the closing storm follows)
--   GRAB <key>                      a resource (an anchor) was grabbed (lootsync R|)
-- A request the host does not confirm within REVERT_SEC is reverted on the client (host state re-applied).
-- Live (2026-10-27, owner: loot must update at once when the other player takes or puts something): the containers'
-- slot handlers (ItemContainer HandleSlotItemAdded / Removed, hooked) mark the container's actor dirty - the host
-- sends its U the next frame, the client looks at it the next frame (TAKE / PUT); a change of the player's own
-- inventory (a pick-up, a drop) starts a pass at once. The host handles requests every frame. (cmds/loot-hook-probe)
-- Transport: append-only text files in a shared directory (to be replaced by the network layer).
local M = {}
-- the game's functions hooked only once they exist (hooks.lua)
local Hook = CoopSyncHook or dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "hooks.lua").hook
-- path lookups: the native one answers a miss at once (UE4SS walks every object then: ~50 ms)
local SFO = StaticFindObject
if CoopNative_HasPath then SFO = function(p) if CoopNative_HasPath(p) then return StaticFindObject(p) end return nil end end
-- a hook only on a real UFunction of that path: a failed RegisterHook raises a C++ error through Lua inside UE4SS, and
-- those, again and again, left the Lua state broken (esc-test crashed 1 in 2-8; the hash lookup found an object at
-- "<class>:StartExplode" that was not that class's function)
local function isFunction(p)
    local f = SFO(p)
    if not (f and f:IsValid()) then return false end
    local ok, c = pcall(function() return f:GetClass():GetFName():ToString() end)
    return ok and c == "Function"
end
-- one instance per Lua state (tests dofile the modules from another mod: require would not find it)
local Link = CoopSyncLink or dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "link.lua")

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
        if CoopSyncHitch then CoopSyncHitch.spent(os.clock() - t0, "state") end
        if not ok then
            if CoopSyncHitch then CoopSyncHitch.note("loop error: " .. tostring(r):sub(1, 200)) end
            return
        end
        if r == true and h then CancelDelayedAction(h) end
    end)
    return h
end
local TICK_MS = 1000       -- a full state pass starts at most this often
local FRAME_BUDGET_MS = 3   -- per-frame time budget for pass work (one actor may overrun it slightly)
local CLIENT_BUDGET_MS = 2  -- the client also applies events and runs the player sync every frame
local REVERT_SEC = 6
local ADOPT_DIST = 300

local Sync -- spawnsync module
local Loot
local role, chan
local state = { seq = 0, readOff = 0, applied = {}, pending = {}, stats = {}, errors = {} }

-- debug breadcrumbs (set CoopSyncDebug = "<file path>" to enable); each line is flushed immediately
local function crumb(msg)
    if not CoopSyncDebug then return end
    local f = io.open(CoopSyncDebug, "ab") if f then f:write(os.date("%H:%M:%S ") .. msg .. "\n") f:close() end
end

-- phase profiler: average ms per tick for each named phase (CoopSyncState.profile())
local prof = {}
local function pstart() return os.clock() end
local function pend(name, t0)
    local p = prof[name] or { ms = 0, n = 0, mx = 0 }
    local d = (os.clock() - t0) * 1000
    p.ms = p.ms + d
    p.n = p.n + 1
    if d > p.mx then p.mx = d end
    prof[name] = p
    if CoopSyncHitch then CoopSyncHitch.op("state " .. name, d) end
end

local function count(k, n) state.stats[k] = (state.stats[k] or 0) + (n or 1) end
local function err(msg) if #state.errors < 20 then state.errors[#state.errors + 1] = msg end end
-- moving hazards: which side runs which (the functions below: "Moving hazards")
local HZ = { guest = {}, mine = {}, asked = {}, claimAt = {}, target = {}, hot = {}, isHz = {}, physOff = {}, sent = {} }
local DOORS -- world doors (below)

---------------------------------------------------------------------------------------------------
-- channel

-- the stream's lines go through the in-game network (link.lua) or the channel file of that name
local function send(file, line)
    state.seq = state.seq + 1
    if Link.send(file, state.seq .. "\t" .. line) then return end
    local f = io.open(chan .. "/" .. file, "ab")
    if not f then err("cannot write " .. file) return end
    f:write(state.seq .. "\t" .. line .. "\n")
    f:close()
end

local function receive(file)
    local got = Link.recv(file)
    if got then
        for i, line in ipairs(got) do got[i] = line:match("^%d+\t(.*)$") or line end
        return got
    end
    local f = io.open(chan .. "/" .. file, "rb")
    if not f then return {} end
    f:seek("set", state.readOff)
    local data = f:read("*a") or ""
    f:close()
    local lines, consumed = {}, 0
    for line, nl in data:gmatch("([^\n]*)(\n)") do
        consumed = consumed + #line + 1
        lines[#lines + 1] = line:match("^%d+\t(.*)$") or line
    end
    state.readOff = state.readOff + consumed
    return lines
end

local function split(line)
    local t = {}
    for v in (line .. "\t"):gmatch("([^\t]*)\t") do t[#t + 1] = v end
    return t
end

local function now() return os.clock() end

---------------------------------------------------------------------------------------------------
-- snapshot helpers

local function row(a, loot)
    local l, r, s = a:K2_GetActorLocation(), a:K2_GetActorRotation(), a:GetActorScale3D()
    local kind = Sync.isRuntime(a) and "R" or "L"
    local clsPath = a:GetClass():GetFullName():gsub("^%S+ ", "")
    return string.format("%s\t%s\t%.2f\t%.2f\t%.2f\t%.3f\t%.3f\t%.3f\t%.4f\t%.4f\t%.4f\t%s\t%s",
        kind, clsPath, l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll, s.X, s.Y, s.Z, Sync.key(a), loot or "")
end

local function parseRow(t, off)
    off = off or 0
    return {
        kind = t[off + 1], cls = t[off + 2], key = t[off + 12], loot = t[off + 13] or "",
        loc = { X = tonumber(t[off + 3]), Y = tonumber(t[off + 4]), Z = tonumber(t[off + 5]) },
        rot = { Pitch = tonumber(t[off + 6]), Yaw = tonumber(t[off + 7]), Roll = tonumber(t[off + 8]) },
        scale = { X = tonumber(t[off + 9]), Y = tonumber(t[off + 10]), Z = tonumber(t[off + 11]) },
    }
end

-- key -> {actor, loot} for every replicated, non-derived root
local function snapshot(keyOf)
    local snap = {}
    crumb("  collect")
    local t0 = pstart()
    local list = Sync.collect()
    pend("collect", t0)
    crumb("  beginPass (" .. #list .. " actors)")
    t0 = pstart()
    Loot.beginPass()
    pend("loot_prepass", t0)
    crumb("  serialize")
    t0 = pstart()
    for _, a in ipairs(list) do
        if not Sync.isDerived(Sync.clsName(a)) then
            if CoopSyncDebugDeep then crumb("  ser " .. a:GetFName():ToString()) end
            local k = keyOf(a)
            if k then snap[k] = { actor = a, loot = Loot.serialize(a) or "" } end
        end
    end
    Loot.endPass()
    pend("serialize", t0)
    return snap
end

-- multiset of archetypes in a container loot string (positions / stacks ignored); whole: of whole item specs
-- (archetype + sub-containers: what a PUT recreates)
local function itemBag(loot, whole)
    local bag = {}
    local body = (loot:match("^C|[^!]*!(.*)$") or ""):gsub("#O$", "")
    for _, sspec in ipairs(Loot.splitTop(body, ";")) do
        local items = sspec:match("^[^=]*=(.*)$") or ""
        for _, it in ipairs(Loot.splitTop(items, ",")) do
            local arch = whole and it or it:match("^([^{]*)")
            if arch ~= "" then bag[arch] = (bag[arch] or 0) + 1 end
        end
    end
    return bag
end
-- What was put into a container from old to cur: { {spec, n}, ... }. Counted by archetype like the takes (a rebuilt
-- item's sub-containers need not serialize the same: by whole specs that read as a put - a duplicate on the host);
-- the whole spec only says what to recreate (one of cur's specs of that archetype, a new one first).
-- The tile ("x_y_r") of a slot in cur holding spec that old does not have as it is: where the player put it (owner,
-- alpha 18: the guest's item landed in the first slot - the host added it anywhere and its layout came back)
local function tileOf(cur, old, spec)
    local had = {}
    for _, sspec in ipairs(Loot.splitTop((old:match("^C|[^!]*!(.*)$") or ""):gsub("#O$", ""), ";")) do had[sspec] = true end
    for _, sspec in ipairs(Loot.splitTop((cur:match("^C|[^!]*!(.*)$") or ""):gsub("#O$", ""), ";")) do
        local tile, items = sspec:match("^([^=]*)=(.*)$")
        if tile and not had[sspec] then
            for _, it in ipairs(Loot.splitTop(items, ",")) do if it == spec then return tile end end
        end
    end
    return ""
end
local function putsOf(cur, old)
    local have, had = itemBag(cur), itemBag(old)
    local haveW, hadW = itemBag(cur, true), itemBag(old, true)
    local out = {}
    for arch, n in pairs(have) do
        local extra = n - (had[arch] or 0)
        if extra > 0 then
            local pick
            for spec, m in pairs(haveW) do
                if spec:match("^([^{]*)") == arch and (not pick or m > (hadW[spec] or 0)) then pick = spec end
            end
            if pick then out[#out + 1] = { pick, extra, tileOf(cur, old, pick) } end
        end
    end
    return out
end
-- the container slot hooks' marks (one table per Lua state: the hooks stay registered across module reloads)
CoopSyncLootHook = CoopSyncLootHook or { dirty = {}, inv = false, quiet = false }
local LH = CoopSyncLootHook
local function hookContainers()
    if LH.done then return end
    LH.done = true
    for _, fn in ipairs({ "HandleSlotItemAdded", "HandleSlotItemRemoved" }) do
        local p = "/Script/PenDriverInventory.ItemContainer:" .. fn
        if isFunction(p) then
            pcall(Hook, p, function(ctx)
                if LH.quiet or not LH.on then return end
                pcall(function()
                    local o = ctx:get():GetOuter()
                    if not (o and o:IsValid()) then return end
                    local n = o:GetFullName()
                    if n:find("^BP_InventoryManager_C ") then LH.inv = true LH.fuelInv = true
                    else LH.dirty[n:gsub("^%S+ ", "")] = true end
                end)
            end)
        end
    end
    -- a wreck's trunk opened / pried here: its wreck at once (a far wreck waited for the full pass, 10 s; at 15 fps
    -- the host's pried trunk never showed on the guest's side within 8 s)
    local trunk = "/Game/Gameplay/Vehicles/Templates/BaseActors/BP_TemplatePart_Trunk.BP_TemplatePart_Trunk_C:"
    for _, fn in ipairs({ "UpdateTrunkState", "SetHighlightOpened" }) do
        if isFunction(trunk .. fn) then
            pcall(Hook, trunk .. fn, function(ctx)
                if LH.quiet or not LH.on then return end
                pcall(function()
                    local par = CoopSyncParentOf(ctx:get())
                    if par and par:IsValid() then LH.dirty[(par:GetFullName():gsub("^%S+ ", ""))] = true count("trunk_live") end
                end)
            end)
        end
    end
end

-- A wreck's trunk (owner, alpha 16: the guest's takes there never reached the host): its container belongs to the
-- trunk part's item, not to the wreck the lists know. The slot hooks' mark (that item's path) -> the wreck's key,
-- from the templates whose loot holds sub-containers; built again on a miss once those change (SUB.dirty).
-- loots: key -> loot string; resolve: key -> actor.
local SUB = { of = {}, dirty = true, at = -1e9, recheck = {} }
local function subOwner(p, loots, resolve)
    local k = SUB.of[p]
    if k then return k end
    if SUB.dirty or os.clock() - SUB.at > 5 then
        SUB.of, SUB.dirty, SUB.at = {}, false, os.clock()
        local own = not Loot.inPass()
        if own then Loot.beginPass() end
        for key, loot in pairs(loots) do
            if loot:sub(1, 2) == "T|" and loot:find("{", 1, true) then
                local a = resolve(key)
                if a then
                    for _, part in ipairs(Loot.templateParts(a)) do
                        local inst = part.ItemInstance
                        if inst and inst:IsValid() then SUB.of[(inst:GetFullName():gsub("^%S+ ", ""))] = key end
                    end
                end
            end
        end
        if own then Loot.endPass() end
    end
    return SUB.of[p]
end

local function sockets(loot)
    local s = {}
    for _, ps in ipairs(Loot.splitTop((Loot.splitStates(loot)):match("^T|(.*)$") or "", "~")) do
        local socket = ps:match("^([^=]*)=")
        if socket and socket ~= "" then s[socket] = ps end
    end
    return s
end

---------------------------------------------------------------------------------------------------
-- host

local prev -- previous snapshot (key -> loot)
local pass -- the host pass under way (hostBegin .. hostFinish)
local prevPos = {} -- world item key -> last sent location
local MOVE_EPS = 10
local byKey = {}

local IBL = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")

local hostTake, hostPut -- (below)
local function hostHandle(t)
    local op, key = t[1], t[2]
    if op:sub(1, 1) == "H" then HZ.hostHandle(t) return end
    if op == "DSR" then DOORS.handle(t) return end
    if op == "KB" or op == "KK" then CoopSyncKnock.handle(t) return end
    if op == "TS" then CoopSyncTour.apply(t) return end
    if op == "DROP" then
        -- the client dropped one of its own items: it becomes a world item here (the next pass sends it
        -- back as S, and the client adopts its local one)
        local loc = { X = tonumber(t[3]), Y = tonumber(t[4]), Z = tonumber(t[5]) }
        local xf = { Translation = loc, Rotation = Sync.quat(tonumber(t[6]) or 0, tonumber(t[7]) or 0, tonumber(t[8]) or 0), Scale3D = { X = 1, Y = 1, Z = 1 } }
        local ok, a = pcall(Loot.spawnWorldItem, t[2], xf)
        -- a canister's fuel (the item's own: a new one of the archetype comes empty)
        if ok and a and tonumber(t[9]) then CoopSyncFuel.set(a, tonumber(t[9])) end
        -- (it falls here as it fell there: a world item spawned this way - a car door the guest took off and threw
        -- down - stood in the air on the host, and its positions pulled the guest's falling one up again and again;
        -- owner's alpha 20 test)
        if ok and a then
            pcall(function()
                local r = a.RootComponent
                if r and r:IsValid() and r:IsA(StaticFindObject("/Script/Engine.PrimitiveComponent")) then
                    r:SetSimulatePhysics(true)
                    r:WakeAllRigidBodies()
                end
            end)
        end
        count((ok and a) and "req_DROP_done" or "req_DROP_failed")
        return
    end
    if op == "GOB" then count(CoopSyncGobbler.apply(t[2]) and "req_GOB_done" or "req_GOB_failed") return end
    if op == "WPH" then local okW, r = pcall(CoopSyncWreck.apply, t) count("req_WPH_" .. (okW and tostring(r) or "error")) return end
    local a = Sync.deref(key)
    if not a then count("req_" .. op .. "_missing") send("host.events", "NACK\t" .. op .. "\t" .. key) return end
    if op == "EXIT" then count(CoopSyncExit.apply(a) and "req_EXIT_done" or "req_EXIT_failed") return end
    if op == "FUEL" then count(CoopSyncFuel.set(a, tonumber(t[3])) and "req_FUEL_done" or "req_FUEL_failed") return end
    if op == "OPEN" then
        if not a.DataBlock_WasOpened then
            -- opened the quiet way (as lootsync applies an open one): HighlightInteract is the player's E - it opened
            -- the loot window on the host whenever the guest searched (owner's alpha 17 item 1, alpha 18 item 32)
            pcall(function() a.DataBlock_WasOpened = true end)
            pcall(function() a:SwitchToOpenedVisuals() end)
            pcall(function() a:UpdateInteractionOpened() end)
            a:OnRollForOpenItems()
            count("req_OPEN_done")
        else
            count("req_OPEN_already")
        end
    elseif op == "TAKE" or op == "PUT" then
        -- t[5] "<socket>#<n>": a wreck's part's sub-container (its trunk), else the lootable's own container
        local c
        if t[5] and t[5] ~= "" then
            local socket, n = t[5]:match("^(.*)#(%d+)$")
            c = socket and Loot.subContainer(a, socket, n)
        else
            pcall(function() c = a.InventoryContainer end)
        end
        if not (c and c:IsValid()) then
            count("req_" .. op .. "_nocontainer")
            send("host.events", "NACK\t" .. op .. "\t" .. key .. "\t" .. (tonumber(t[4]) or 1) .. "\t" .. t[3])
            return
        end
        if op == "TAKE" then hostTake(t, key, c) else hostPut(t, key, c) end
    elseif op == "PICK" then
        Loot.removeWorldItem(a)
        count("req_PICK_done")
        -- gone for the client at once (not with the next pass)
        send("host.events", "D\t" .. key)
        if prev then prev[key] = nil end
        if pass then pass.snap[key] = nil end
    elseif op == "BOOM" then
        -- the guest set off its copy of this hazard: the host's goes off (its hook then sends X, which the
        -- client skips: its copy already went off)
        local ok = pcall(function() a:StartExplode() end)
        count(ok and "req_BOOM_done" or "req_BOOM_failed")
    elseif op == "DETACH" then
        local done = false
        for _, p in ipairs(Loot.templateParts(a)) do
            if not done and p.MySocket:ToString() == t[3] then
                M.detachPart(p)
                done = true
            end
        end
        count(done and "req_DETACH_done" or "req_DETACH_missing")
        -- (taken off here first: the guest's copy of the part is a duplicate - lag test 150 ms, both took one wheel)
        if not done then send("host.events", "NACK\tDETACH\t" .. key .. "\t1\t" .. t[3]) end
    elseif op == "GRAB" then
        -- the guest grabbed a resource (an anchor): taken here, nobody gets it (the next pass sends U R|1)
        count(Loot.markGrabbed(a) and "req_GRAB_done" or "req_GRAB_already")
    elseif op == "TRUNK" then
        -- the guest opened / pried a wreck's trunk: here too (its loot string changes: the next pass sends U)
        local n = Loot.applyStates(a, { [t[3]] = tonumber(t[4]) })
        count(n > 0 and "req_TRUNK_done" or "req_TRUNK_same")
    end
end
hostTake = function(t, key, c)
    local arch = Loot.find(t[3])
    local want, got = tonumber(t[4]) or 1, 0
    for _ = 1, want do
        local inst = arch and c:FindItemOfType(arch)
        if inst and inst:IsValid() then c:RemoveItem(inst) got = got + 1 end
    end
    count("req_TAKE_items", got)
    if got < want then count("req_TAKE_denied", want - got) send("host.events", "NACK\tTAKE\t" .. key .. "\t" .. (want - got) .. "\t" .. t[3]) end
end
hostPut = function(t, key, c)
    local want, got = tonumber(t[4]) or 1, 0
    local x, y, r = (t[6] or ""):match("^(%-?%d+)_(%-?%d+)_(%d)$")
    for i = 1, want do
        local inst = Loot.newItem(t[3])
        if inst then
            c:AddItem(inst, true)
            local s = c:FindSlot(inst)
            if s and s:IsValid() then
                got = got + 1
                if i == 1 and x and s.Items:GetArrayNum() == 1 then
                    pcall(function() s.Location = { X = tonumber(x), Y = tonumber(y) } end)
                    pcall(function() s.bRotated = (r == "1") end)
                    count("req_PUT_placed")
                end
            end
        end
    end
    count("req_PUT_items", got)
    if got < want then count("req_PUT_denied", want - got) send("host.events", "NACK\tPUT\t" .. key .. "\t" .. (want - got) .. "\t" .. t[3]) end
end

-- Takes a part off a wreck the way the game's result looks: part gone, its item lying on the ground.
function M.detachPart(p)
    local inst = p.ItemInstance
    local arch = inst and inst:IsValid() and inst.Archetype or nil
    local l = p:K2_GetActorLocation()
    local xf = { Translation = { X = l.X, Y = l.Y, Z = l.Z + 30 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
    p:K2_DestroyActor()
    if arch then return Loot.inventorySystem():SpawnItemActor(FindFirstOf("PlayerController"), xf, arch, 0, 4) end
end

-- Host pass, spread over frames: at most every TICK_MS a pass starts over the cached replicated roots
-- (Sync.roots: full scan at most every 2 s); each frame serializes / checks movement for as many
-- actors as fit in FRAME_BUDGET_MS. When the pass is complete the diff is sent and requests are handled.
local lastPassStart = -1e9
local lootGen
-- Native (CoopNative world.cpp, 2026-10-26): every root's place read in one C++ call (TrackMoved: the M events), and
-- the loot serialized each pass only near the players (NEAR_CM of the host, its car, the guest, the guest's car), all
-- of it every FULL_PASS_S. The whole pass in Lua each second took 4.4 ms of every host frame (F lines).
local NT = CoopNative_TrackMoved ~= nil
local NEAR_CM, FULL_PASS_S = 3000, 10
local trackGen, lastFull = nil, -1e9
local function nearPoints()
    local t = {}
    local function add(l) if l and l.X then t[#t + 1] = string.format("%.0f %.0f %.0f", l.X, l.Y, l.Z) end end
    pcall(function() add(FindFirstOf("PlayerController").Pawn:K2_GetActorLocation()) end)
    pcall(function() add(FindFirstOf("BP_CarManager_C").NewCarActor:K2_GetActorLocation()) end)
    if CoopSyncOtherPoints then
        local ok, pts = pcall(CoopSyncOtherPoints)
        if ok then for _, l in ipairs(pts or {}) do add(l) end end
    end
    return table.concat(t, "\n")
end

local function hostBegin()
    local t0 = pstart()
    if not Sync.rootPaths() then Sync.roots() end -- first pass: synchronous scan once
    local paths = {}
    for _, p in ipairs(Sync.rootPaths()) do
        if not Sync.isDerivedPath(p) then paths[#paths + 1] = p end
    end
    -- the loot pre-pass maps hold object paths; rebuild them only after a full root scan
    if Sync.scanGeneration ~= lootGen then Loot.beginPass() lootGen = Sync.scanGeneration end
    pass = { paths = paths, i = 1, snap = {} }
    if NT then
        if trackGen ~= Sync.scanGeneration then CoopNative_TrackSet(table.concat(paths, "\n")) trackGen = Sync.scanGeneration end
        -- what moved: the M events at once (also the first time an actor is seen: the client's baseline)
        for k, x, y, z, rp, ry, rr in CoopNative_TrackMoved(MOVE_EPS):gmatch("([^\t\n]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\n]+)\n") do
            -- (a hazard the guest runs moved because the guest said so: no M back; a moving one of the host's
            -- streams faster from now on: HZ.frame)
            if not HZ.guest[k] then
                send("host.events", string.format("M\t%s\t%s\t%s\t%s\t%s\t%s\t%s", k, x, y, z, rp, ry, rr))
                count("ev_M")
                if (state.stats.passes or 0) > 0 then HZ.moved(k) end -- (the first pass: everything's baseline)
            end
        end
        local now = os.clock()
        if prev and now - lastFull < FULL_PASS_S then
            -- the loot near the players; the rest keeps its last state until the next full pass
            local near = {}
            for k in CoopNative_TrackNear(nearPoints(), NEAR_CM):gmatch("([^\n]+)\n") do near[#near + 1] = k end
            for _, k in ipairs(paths) do pass.snap[k] = prev[k] end
            pass.paths = near
            count("passes_near")
        else
            lastFull = now
            count("passes_full")
        end
    end
    pend("pass_begin", t0)
end

local function hostStep(deadline)
    while pass.i <= #pass.paths do
        if os.clock() > deadline then return false end
        local k = pass.paths[pass.i]
        pass.i = pass.i + 1
        local a = Sync.deref(k)
        if NT then
            -- (movement went out at the pass's start: C++)
            if a and not Sync.inPool(a) then pass.snap[k] = Loot.serialize(a) or "" else pass.snap[k] = nil end
        elseif a and not Sync.inPool(a) then
            pass.snap[k] = Loot.serialize(a) or ""
            -- anything that moves on the host (physics props, loose items, hazards): stream its transform
            local l = a:K2_GetActorLocation()
            local p = prevPos[k]
            if not HZ.guest[k] and (not p or (l.X - p.X) ^ 2 + (l.Y - p.Y) ^ 2 + (l.Z - p.Z) ^ 2 > MOVE_EPS ^ 2) then
                if p then HZ.moved(k) end
                -- also sent the first time an actor is seen: the client's baseline must be the host's
                -- current transform, not the one from the (older) spawn list
                local r = a:K2_GetActorRotation()
                send("host.events", string.format("M\t%s\t%.2f\t%.2f\t%.2f\t%.3f\t%.3f\t%.3f", k, l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll))
                count(p and "ev_M" or "ev_M_baseline")
                prevPos[k] = { X = l.X, Y = l.Y, Z = l.Z }
            end
        end
    end
    return true
end

local function hostFinish()
    local t0 = pstart()
    local snap = pass.snap
    pass = nil
    if prev then
        for k, loot in pairs(snap) do
            if prev[k] == nil then
                local a = Sync.deref(k)
                if a then send("host.events", "S\t" .. row(a, loot)) count("ev_S") end
            elseif prev[k] ~= loot then send("host.events", "U\t" .. k .. "\t" .. loot) count("ev_U") end
        end
        for k in pairs(prev) do
            if snap[k] == nil then send("host.events", "D\t" .. k) count("ev_D") end
        end
    end
    for k in pairs(prevPos) do if not snap[k] then prevPos[k] = nil end end
    prev = snap
    count("passes")
    pend("pass_finish", t0)
end

-- Every frame: the client's requests, then the containers the slot hooks marked (their U at once).
local function hostLive(deadline)
    for _, line in ipairs(receive("client.requests")) do
        local ok, e = pcall(hostHandle, split(line))
        if not ok then err("handle " .. line:sub(1, 80) .. ": " .. tostring(e)) end
    end
    if LH.inv then LH.inv = false lastPassStart = -1e9 end -- (the player picked up / dropped something: a pass now)
    if not (prev and next(LH.dirty)) then return end
    for k in pairs(LH.dirty) do
        LH.dirty[k] = nil
        if prev[k] == nil then k = subOwner(k, prev, Sync.deref) or k end -- (a wreck's trunk: the wreck)
        if prev[k] ~= nil then
            local a = Sync.deref(k)
            if a and not Sync.inPool(a) then
                local loot = Loot.serialize(a) or ""
                if loot ~= prev[k] then
                    send("host.events", "U\t" .. k .. "\t" .. loot)
                    prev[k] = loot
                    count("ev_U_live")
                end
                if pass then pass.snap[k] = loot end
            end
        end
        if os.clock() > deadline then break end
    end
end

local function hostFrame(deadline)
    local tl = pstart()
    hostLive(deadline)
    pend("host_live", tl)
    -- keep the replicated-root list fresh in the background (budgeted, see spawnsync scanFrame)
    local ts = pstart()
    Sync.scanFrame(deadline)
    pend("scan_frame", ts)
    if not pass then
        if os.clock() * 1000 - lastPassStart < TICK_MS then return end
        lastPassStart = os.clock() * 1000
        hostBegin()
    end
    local t0 = pstart()
    local done = hostStep(deadline)
    pend("pass_step", t0)
    if done then hostFinish() end
end
---------------------------------------------------------------------------------------------------
-- client

-- client copies of loose world items follow the host's transform instead of simulating physics
local function puppet(a)
    pcall(function()
        local rc = a.RootComponent
        if rc and rc:IsValid() and rc:IsSimulatingPhysics() then
            rc:SetSimulatePhysics(false)
            HZ.physOff[a:GetAddress()] = true -- (a hazard this side runs later gets its physics back)
        end
    end)
end

local hostPos = {} -- host key -> {loc, rot}: last transform the host reported
local SNAP_BACK = 20

local reverse = {} -- client actor path -> host key   (CoopSyncMap: host key -> client actor path)
local exploding = {} -- key -> true: went off for real (the client does not respawn it)
local remoteBoom = {} -- key -> true: the client set it off because the host said so (no BOOM back)
local lastBlast = -1e9 -- os.clock of the last hazard that went off on the client (sent or received)
local CHAIN_WINDOW_S = 2

-- Diagnostics for one local actor: its host key, the host transform the client holds, sync state.
function M.debugActor(a)
    local p = Sync.ref(a)
    local key = reverse[p]
    local hp = key and hostPos[key]
    return string.format("key=%s hostPos=%s applied=%s pending=%s", tostring(key),
        hp and string.format("%.1f,%.1f,%.1f", hp.loc.X, hp.loc.Y, hp.loc.Z) or "nil",
        key and tostring(state.applied[key] ~= nil) or "-", key and tostring(state.pending[key] ~= nil) or "-")
end

local function mapActor(key, a)
    local p = Sync.ref(a)
    CoopSyncMap[key] = p
    reverse[p] = key
end

-- One unit, one owner: a PICK / TAKE the host refuses (NACK) means the local copy was a duplicate.
local pickArch = {} -- key -> archetype path of a world item this side picked up (D may clear applied first)
local pickSent = {} -- key -> true once this side sent a PICK for it
local function objPath(o) return (o:GetFullName():gsub("^%S+%s+", "")) end
local INV = { "Inventory_Player", "Inventory_PlayerHand" }
-- remove n items of an archetype from what the local player carries; returns how many were removed
local function takeBack(archPath, n)
    local arch = Loot.find(archPath)
    if not arch or n <= 0 then return 0 end
    local im = FindFirstOf("BP_InventoryManager_C")
    local removed = 0
    for _, f in ipairs(INV) do
        if removed >= n then break end
        pcall(function()
            local c = im[f]
            local have = 0
            for i = 1, c.Slots:GetArrayNum() do
                local s = c.Slots[i]
                for j = 1, s.Items:GetArrayNum() do if objPath(s.Items[j].Archetype) == objPath(arch) then have = have + 1 end end
            end
            local k = math.min(have, n - removed)
            if k > 0 then c:RemoveItemsOfType(arch, k) removed = removed + k end
        end)
    end
    return removed
end

-- What the local player carries, archetype path -> count.
local function invCounts()
    local im = FindFirstOf("BP_InventoryManager_C")
    local h = {}
    for _, f in ipairs(INV) do
        pcall(function()
            local c = im[f]
            for i = 1, c.Slots:GetArrayNum() do
                local s = c.Slots[i]
                for j = 1, s.Items:GetArrayNum() do local p = objPath(s.Items[j].Archetype) h[p] = (h[p] or 0) + 1 end
            end
        end)
    end
    return h
end

local function applyLoot(a, loot)
    if loot == "" or loot:sub(1, 2) == "W|" then return end
    Loot.resetStats()
    LH.quiet = true -- (the host's state, not this player's doing)
    if loot:sub(1, 2) == "T|" then SUB.dirty = true end -- (its parts' items may be new: subOwner)
    local ok, e = pcall(function()
        Loot.applyDiff(a, loot)
        Loot.flushPending()
    end)
    LH.quiet = false
    if not ok then error(e) end
end
-- a PUT the host refused (its container was full): the item back to the local player
local function giveBackItem(spec, n)
    local inv = FindFirstOf("BP_InventoryManager_C").Inventory_Player
    local done = 0
    for _ = 1, n do
        local inst = Loot.newItem(spec)
        if inst then inv:AddItem(inst, true) done = done + 1 end
    end
    return done
end

-- a predicted local world item of the same item near the host's new one is adopted instead of spawning
local function adoptPredicted(e)
    if e.loot:sub(1, 2) ~= "W|" then return nil end
    local best, bestD
    Loot.beginPass()
    for _, a in ipairs(Sync.collect()) do
        if not reverse[Sync.ref(a)] and Loot.isItemActor(a) and (Loot.serialize(a) or "") == e.loot then
            local l = a:K2_GetActorLocation()
            local d = math.sqrt((l.X - e.loc.X) ^ 2 + (l.Y - e.loc.Y) ^ 2 + (l.Z - e.loc.Z) ^ 2)
            if d < ADOPT_DIST and (not bestD or d < bestD) then best, bestD = a, d end
        end
    end
    Loot.endPass()
    if best then pcall(function() best:K2_SetActorLocationAndRotation(e.loc, e.rot, false, {}, true) end) end
    return best
end

-- path -> actor for this tick (one collect() instead of a StaticFindObject per event: with forced
-- GUObjectArray iteration ~350 baseline events took ~12 s)
local tickIndex
local function resolve(key)
    local p = CoopSyncMap[key]
    if not p then return nil end
    if tickIndex then
        local a = tickIndex[p]
        if a then return a end
    end
    return Sync.deref(p)
end

-- A wreck's part this side took off that the host had already lost (NACK DETACH): this side's copy goes - from the
-- player's hands / inventory, else the item lying near the wreck that the host does not know (the host's own
-- one comes as S). Returns how many were removed.
local detachArch = {} -- "<key>\t<socket>" -> the part's item archetype name
local function undoDetach(key, socket)
    local arch = detachArch[key .. "\t" .. socket]
    detachArch[key .. "\t" .. socket] = nil
    if not arch or arch == "" then return 0 end
    local n = takeBack(arch, 1)
    if n > 0 then return n end
    local w = resolve(key)
    if not w then return 0 end
    local wl = w:K2_GetActorLocation()
    for _, a in ipairs(Sync.collect()) do
        if not reverse[Sync.ref(a)] and Loot.isItemActor(a) and (Loot.serialize(a) or ""):match("^W|([^{]*)") == arch then
            local l = a:K2_GetActorLocation()
            if (l.X - wl.X) ^ 2 + (l.Y - wl.Y) ^ 2 + (l.Z - wl.Z) ^ 2 < 800 ^ 2 then
                pcall(function() a:K2_DestroyActor() end)
                return 1
            end
        end
    end
    return 0
end

local request -- defined below (detection), used here for takes the host's update overtook

-- The host's update of a container can arrive before this side's detection pass noticed what the player
-- took out locally; applying it blindly would hide the take (the container then looks like the host's) and
-- the player would keep a duplicate. So compare first: what the player took and the host still has is
-- requested now; what the host no longer has (somebody else got it) is given back.
local function reconcileTake(key, a, newLoot)
    local old = state.applied[key]
    if state.pending[key] or not old or old:sub(1, 2) ~= "C|" or newLoot:sub(1, 2) ~= "C|" then return {} end
    Loot.beginPass()
    local cur = Loot.serialize(a) or ""
    Loot.endPass()
    if cur == old then return {} end
    local have, had, now = itemBag(cur), itemBag(old), itemBag(newLoot)
    local asks = {}
    for arch, n in pairs(had) do
        local taken = n - (have[arch] or 0)
        if taken > 0 then
            local still = math.min(taken, now[arch] or 0)
            if taken - still > 0 then count("contested_take_reverted", takeBack(arch, taken - still)) end
            if still > 0 then asks[#asks + 1] = string.format("TAKE\t%s\t%s\t%d", key, arch, still) end
        end
    end
    -- what the player put in: asked for now (the host's update would wipe it here until the host has it too)
    for _, p in ipairs(putsOf(cur, old)) do asks[#asks + 1] = string.format("PUT\t%s\t%s\t%d\t\t%s", key, p[1], p[2], p[3]) end
    return asks
end

local function clientApply(t)
    local op = t[1]
    if op:sub(1, 1) == "H" then HZ.clientApply(t) return end
    if op == "DS" then DOORS.handle(t) return end
    if op == "VP" then CoopSyncPaint.handle(t) return end
    if op == "GE" then CoopSyncEvent.handle(t) return end
    if op == "KB" or op == "KK" then CoopSyncKnock.handle(t) return end
    if op == "RG" then CoopSyncRange.apply(t) return end
    if op == "TP" or op == "TS" then CoopSyncTour.apply(t) return end
    if op == "GOB" then count(CoopSyncGobbler.apply(t[2]) and "ap_GOB" or "ap_GOB_failed") return end
    if op == "WPH" then local okW, r = pcall(CoopSyncWreck.apply, t) count("ap_WPH_" .. (okW and tostring(r) or "error")) return end
    if op == "FUEL" then
        local a = resolve(t[2])
        -- (a canister the host just dropped: its copy here may still be spawning - set when it comes)
        if not a then CoopSyncFuel.pend[t[2]] = { v = tonumber(t[3]), at = os.clock() } end
        count(not a and "ap_FUEL_unmapped" or CoopSyncFuel.set(a, tonumber(t[3])) and "ap_FUEL" or "ap_FUEL_failed")
        return
    end
    if op == "EXIT" then
        local a = resolve(t[2])
        count(not a and "ap_EXIT_unmapped" or CoopSyncExit.apply(a) and "ap_EXIT" or "ap_EXIT_failed")
        return
    end
    if op == "STORM" or op == "STST" or op == "STI" then
        local okS, r = pcall(CoopSyncStorm.apply, t)
        if op ~= "STI" then count("ap_" .. op .. "_" .. (okS and tostring(r) or "error")) end
        -- (for the session's status line: storms spawned here from the host's / lines skipped, one up already)
        if op == "STORM" and (r == "done" or r == "have") then CoopSyncStorm[r] = (CoopSyncStorm[r] or 0) + 1 end
        return
    end
    if op == "M" and HZ.mine[t[2]] then count("ap_M_mine") return end -- (sent before the host granted it)
    if op == "U" then
        local key, loot = t[2], t[3] or ""
        local a = resolve(key)
        local asks = {}
        if a then
            local okR, r = pcall(reconcileTake, key, a, loot)
            if okR then asks = r else err("reconcile: " .. tostring(r)) end
            applyLoot(a, loot)
            count("ap_U")
        else
            count("ap_U_unmapped")
        end
        state.applied[key] = loot
        state.pending[key] = nil
        for _, line in ipairs(asks) do request(key, line) end
    elseif op == "D" then
        local key = t[2]
        local a = resolve(key)
        local applied = state.applied[key]
        if a and Loot.isItemActor(a) then Loot.removeWorldItem(a) count("ap_D")
        -- (destroyTrees is a job over a list: called here with a map it raised, and the D of a hazard / container
        -- was never applied; a pooled hazard is parked in its pool by K2_DestroyActor)
        elseif a then pcall(function() a:K2_DestroyActor() end) count("ap_D")
        else
            count("ap_D_already")
            -- gone here too, with no PICK sent yet: this player picked it up while the host gave it to
            -- somebody else (the host's D overtook the detection pass) -> give the copy back
            -- (a PICK this side sent - accepted, or refused and already given back - is not a race)
            if applied and applied:sub(1, 2) == "W|" and not state.pending[key] and not pickSent[key] then
                local arch = applied:match("^W|([^{]*)")
                if arch then count("contested_pick_reverted", takeBack(arch, 1)) end
            end
            pickSent[key] = nil
        end
        CoopSyncMap[key] = nil
        state.applied[key] = nil
        state.pending[key] = nil
    elseif op == "S" then
        local e = parseRow(t, 1)
        local a = adoptPredicted(e)
        if a then count("ap_S_adopted") else
            local err2
            a, err2 = Sync.spawnEntry(e)
            if a then count("ap_S_spawned") applyLoot(a, e.loot) else count("ap_S_failed") err("spawn " .. tostring(err2)) end
        end
        if a then
            mapActor(e.key, a)
            state.applied[e.key] = e.loot
            hostPos[e.key] = { loc = e.loc, rot = e.rot }
            if e.loot:sub(1, 2) == "W|" then puppet(a) end
        end
    elseif op == "M" then
        local a = resolve(t[2])
        if a then
            local loc = { X = tonumber(t[3]), Y = tonumber(t[4]), Z = tonumber(t[5]) }
            local rot = { Pitch = tonumber(t[6]), Yaw = tonumber(t[7]), Roll = tonumber(t[8]) }
            local cur = a:K2_GetActorLocation()
            if (cur.X - loc.X) ^ 2 + (cur.Y - loc.Y) ^ 2 + (cur.Z - loc.Z) ^ 2 > 1 then
                -- only touch copies that are actually elsewhere (the baseline is mostly identical)
                puppet(a)
                pcall(function() a:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end)
                count("ap_M")
            else
                count("ap_M_same")
            end
        end
        hostPos[t[2]] = { loc = { X = tonumber(t[3]), Y = tonumber(t[4]), Z = tonumber(t[5]) }, rot = { Pitch = tonumber(t[6]), Yaw = tonumber(t[7]), Roll = tonumber(t[8]) } }
    elseif op == "X" then
        -- a hazard went off on the host: set off this copy too (unless it already went off here)
        local key = t[2]
        local a = resolve(key)
        if a and not exploding[key] then
            exploding[key] = true
            remoteBoom[key] = true
            lastBlast = os.clock()
            local ok = pcall(function() a:StartExplode() end)
            count(ok and "ap_X" or "ap_X_failed")
        else
            count("ap_X_skipped")
        end
    elseif op == "NACK" then
        -- the host said no: somebody else got that unit first -> give back what this side took locally
        count("nack_" .. (t[2] or "?"))
        if t[2] == "PICK" then
            local arch = pickArch[t[3]]
            pickArch[t[3]] = nil
            if arch then count("nack_reverted_items", takeBack(arch, 1)) end
        elseif t[2] == "TAKE" and t[5] then
            count("nack_reverted_items", takeBack(t[5], tonumber(t[4]) or 0))
        elseif t[2] == "PUT" and t[5] then
            count("nack_put_given_back", giveBackItem(t[5], tonumber(t[4]) or 0))
        elseif t[2] == "DETACH" and t[5] then
            count("nack_reverted_items", undoDetach(t[3], t[5]))
        end
        if t[3] then state.pending[t[3]] = nil end
    end
end

request = function(key, line)
    send("client.requests", line)
    state.pending[key] = now()
    count("rq_" .. line:match("^(%u+)"))
end

---------------------------------------------------------------------------------------------------
-- Moving hazards (anomaly sync, 2026-10-28). The game's hazards know one player: their range checks and chase
-- (GetDistanceToPlayer, IsPlayerOrCarInRange; the supercharger mine's MoveToCar / CreepTowardCar / LeapTowardCar) read
-- the local player and its car. With the host the authority for every position, one that went for the guest was
-- pulled back to the host's spot every pass (anomaly-probe: the guest's copy in range, "moving", standing still) and
-- the host's copy never woke. Now the side whose player is nearer runs it, as the game would pick:
--   guest -> host   HCLAIM <key>           its copy left the host's spot and the guest is the nearer player
--   host -> guest   HGRANT / HDENY <key>   granted when the guest is nearer by the host's view too
--   owner -> other  HM <key> x y z p y r   a moving hazard's pose 10 times a second (both ways)
--   host -> guest   HREVOKE <key>          the host's player got nearer by HZ.MARGIN: the host runs it again
--   guest -> host   HDEAD <key>            one the guest ran is gone there (went off, ...): gone on the host too
-- The other side's copy is a puppet (physics off) eased onto the owner's pose. Mines still go off through StartExplode
-- (BOOM / X); the damage is the owner's game's own: the hazard acts on the player it went after.
HZ.MARGIN = 500
HZ.CLAIM_RETRY_S = 2
HZ.SEND_S = 0.1
HZ.HOT_S = 3 -- a host hazard that moved streams this long after its last move
HZ.EPS = 3
HZ.EASE_S = 0.1
HZ.LEAD_S = 0.15     -- the puppet runs ahead along the last velocity by the pose's age + this (the link, the ease)
HZ.LEAD_MAX_S = 0.4

local function first(cls) return (CoopSyncFirst or FindFirstOf)(cls) end
local function dist2(a, b) return (a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 end
-- how far this side's player (its character, its car) and the other player (its puppet, its car) are from l
function HZ.dists(l)
    local here, there = math.huge, math.huge
    pcall(function()
        local p = first("PlayerController").Pawn
        if p and p:IsValid() then here = math.min(here, dist2(p:K2_GetActorLocation(), l)) end
    end)
    pcall(function()
        local c = first("BP_CarManager_C").NewCarActor
        if c and c:IsValid() then here = math.min(here, dist2(c:K2_GetActorLocation(), l)) end
    end)
    if CoopSyncOtherPoints then
        local ok, pts = pcall(CoopSyncOtherPoints)
        for _, o in ipairs(ok and pts or {}) do there = math.min(there, dist2(o, l)) end
    end
    return math.sqrt(here), math.sqrt(there)
end

local function poseLine(key, a)
    local l, r = a:K2_GetActorLocation(), a:K2_GetActorRotation()
    return string.format("HM\t%s\t%.1f\t%.1f\t%.1f\t%.2f\t%.2f\t%.2f", key, l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll), l
end
local function physicsBack(a)
    if not HZ.physOff[a:GetAddress()] then return end
    HZ.physOff[a:GetAddress()] = nil
    pcall(function() a.RootComponent:SetSimulatePhysics(true) end)
end

-- host: an actor moved this pass - a hazard streams faster for a while
function HZ.moved(k)
    local h = HZ.isHz[k]
    if h == nil then
        local a = Sync.deref(k)
        h = a and Sync.clsName(a):find("^BP_Hazard") ~= nil or false
        HZ.isHz[k] = h
    end
    if h then HZ.hot[k] = os.clock() + HZ.HOT_S end
end

-- guest: its copy left the host's spot. True = let it run (this side asked for it, or runs it).
function HZ.claim(key, a, l, e) -- (e: the host list row)
    if not (e and e.cls:find("/BP_Hazard_", 1, true)) then return false end
    local t = os.clock()
    if HZ.asked[key] then return t - HZ.asked[key] < 3 end -- (runs while the host decides)
    if (HZ.claimAt[key] or -1e9) + HZ.CLAIM_RETRY_S > t then return false end -- (denied / taken back a moment ago)
    local here, there = HZ.dists(l)
    if here >= there then return false end
    HZ.asked[key] = t
    physicsBack(a)
    send("client.requests", "HCLAIM\t" .. key)
    count("hz_claim")
    return true
end

-- guest: one it ran is gone here
function HZ.died(key)
    HZ.mine[key] = nil
    exploding[key] = true
    send("client.requests", "HDEAD\t" .. key)
    count("hz_died")
end

-- (the velocity from the last two poses: the puppet is led along it - a grabber flying ~600 u/s trailed ~210 units)
local function setTarget(key, t)
    local loc = { X = tonumber(t[3]), Y = tonumber(t[4]), Z = tonumber(t[5]) }
    local rot = { Pitch = tonumber(t[6]), Yaw = tonumber(t[7]), Roll = tonumber(t[8]) }
    if not (loc.X and rot.Roll) then return end
    local now, old = os.clock(), HZ.target[key]
    local v = { X = 0, Y = 0, Z = 0 }
    if old and now - old.t > 0.02 and now - old.t < 0.5 then
        local dt = now - old.t
        v = { X = (loc.X - old.loc.X) / dt, Y = (loc.Y - old.loc.Y) / dt, Z = (loc.Z - old.loc.Z) / dt }
    end
    HZ.target[key] = { loc = loc, rot = rot, t = now, v = v }
end

-- host, every second: the hazards within HZ.NEAR_GUEST of the guest (its character, its car) and nearer to it than to
-- the host's player by HZ.MARGIN become the guest's (puppet here, HGRANT there) - the rule a claim follows, before the
-- host's copy acts on the guest's twin. The list of hazards is looked up every HZ.LIST_S.
HZ.NEAR_GUEST, HZ.LIST_S = 4000, 5
function HZ.handOver()
    if not CoopSyncOtherPoints then return end
    local t = os.clock()
    if not HZ.list or t - (HZ.listAt or -1e9) > HZ.LIST_S then
        HZ.listAt, HZ.list = t, {}
        for _, a in ipairs(FindAllOf("BP_Base_Hazard_C") or {}) do if Sync.alive(a) then HZ.list[#HZ.list + 1] = a end end
    end
    local okP, pts = pcall(CoopSyncOtherPoints)
    if not (okP and pts and #pts > 0) then return end
    for _, a in ipairs(HZ.list) do
        if Sync.alive(a) and not Sync.inPool(a) then
            local l = a:K2_GetActorLocation()
            local nearG = false
            for _, o in ipairs(pts) do if dist2(o, l) < HZ.NEAR_GUEST ^ 2 then nearG = true break end end
            if nearG then
                local key = Sync.ref(a)
                if not HZ.guest[key] and not exploding[key] then
                    local host, guest = HZ.dists(l)
                    if guest + HZ.MARGIN < host then
                        HZ.guest[key] = true
                        HZ.hot[key] = nil
                        puppet(a)
                        send("host.events", "HGRANT\t" .. key)
                        count("hz_handover")
                    end
                end
            end
        end
    end
end

function HZ.hostHandle(t)
    local op, key = t[1], t[2]
    local a = Sync.deref(key)
    if op == "HCLAIM" then
        if not a or Sync.inPool(a) then send("host.events", "HDENY\t" .. key) count("hz_deny_gone") return end
        local host, guest = HZ.dists(a:K2_GetActorLocation())
        if guest < host then
            HZ.guest[key] = true
            HZ.hot[key] = nil
            puppet(a)
            send("host.events", "HGRANT\t" .. key)
            count("hz_grant")
        else
            send("host.events", "HDENY\t" .. key)
            count("hz_deny")
        end
    elseif op == "HM" then
        if HZ.guest[key] then setTarget(key, t) count("hz_pose_in") end
    elseif op == "HDEAD" then
        HZ.guest[key] = nil
        HZ.target[key] = nil
        -- (a pooled actor: K2_DestroyActor parks it in its pool, the next pass sends D)
        if a and not Sync.inPool(a) then pcall(function() a:K2_DestroyActor() end) end
        count("hz_dead_in")
    end
end

function HZ.clientApply(t)
    local op, key = t[1], t[2]
    HZ.asked[key] = nil
    if op == "HGRANT" then
        HZ.mine[key] = true
        HZ.target[key] = nil
        local a = resolve(key)
        if a then physicsBack(a) end
        count("hz_granted")
    elseif op == "HDENY" then
        HZ.claimAt[key] = os.clock()
        count("hz_denied")
    elseif op == "HREVOKE" then
        HZ.mine[key] = nil
        HZ.claimAt[key] = os.clock() -- (not asked for again at once)
        local a = resolve(key)
        if a then puppet(a) end
        count("hz_revoked")
    elseif op == "HM" then
        if not HZ.mine[key] then
            setTarget(key, t)
            local g = HZ.target[key]
            if g then hostPos[key] = { loc = g.loc, rot = g.rot } end -- (the detection pass compares with it)
            count("hz_pose_in")
        end
    end
end

-- Every frame (both sides): ease the puppets onto the owner's pose; every SEND_S the poses this side runs; the host
-- every second takes back what the guest runs once the host's player is the nearer one.
HZ.lastSend, HZ.lastCheck, HZ.lastFrame = 0, 0, os.clock()
-- (not `host and deref or resolve`: a host hazard gone fell through to the guest's map - nil on the host: an error)
local function hzActor(key)
    if role == "host" then return Sync.deref(key) end
    return resolve(key)
end
function HZ.frame()
    local t = os.clock()
    local dt = t - HZ.lastFrame
    HZ.lastFrame = t
    for key, g in pairs(HZ.target) do
        local a = hzActor(key)
        if not a or t - g.t > 2 then
            HZ.target[key] = nil
        else
            local l = a:K2_GetActorLocation()
            local f = math.min(1, dt / HZ.EASE_S)
            -- (no pose for 2.5 sends: it stopped, the owner sends only moves - no lead, it settles on the last one)
            local lead = t - g.t > HZ.SEND_S * 2.5 and 0 or math.min(t - g.t + HZ.LEAD_S, HZ.LEAD_MAX_S)
            local gx, gy, gz = g.loc.X + g.v.X * lead, g.loc.Y + g.v.Y * lead, g.loc.Z + g.v.Z * lead
            local loc = { X = l.X + (gx - l.X) * f, Y = l.Y + (gy - l.Y) * f, Z = l.Z + (gz - l.Z) * f }
            pcall(function() a:K2_SetActorLocationAndRotation(loc, g.rot, false, {}, true) end)
        end
    end
    if t - HZ.lastSend >= HZ.SEND_S then
        HZ.lastSend = t
        local runs, file = HZ.mine, "client.requests"
        if role == "host" then
            runs, file = {}, "host.events"
            for k, untilT in pairs(HZ.hot) do if t > untilT then HZ.hot[k] = nil else runs[k] = true end end
        end
        for key in pairs(runs) do
            local a = hzActor(key)
            if a and not Sync.inPool(a) then
                local line, l = poseLine(key, a)
                local s = HZ.sent[key]
                if not s or dist2(s, l) + (s.Z - l.Z) ^ 2 > HZ.EPS ^ 2 then
                    send(file, line)
                    HZ.sent[key] = l
                    count("hz_pose_out")
                end
            end
        end
    end
    if role == "host" and t - HZ.lastCheck >= 1 then
        HZ.lastCheck = t
        -- (handed over before it moves: the guest drove past a tourist mine some way off, the host's copy - going by the
        -- guest's car's twin - swayed toward it and went off on the host only; owner's alpha 20 test. A guest claims
        -- only once its copy moved: one near the guest and not the host is the guest's at once now)
        pcall(HZ.handOver)
        for key in pairs(HZ.guest) do
            local a = Sync.deref(key)
            if not a or Sync.inPool(a) then
                HZ.guest[key] = nil
            else
                local host, guest = HZ.dists(a:K2_GetActorLocation())
                if host + HZ.MARGIN < guest then
                    HZ.guest[key] = nil
                    HZ.target[key] = nil
                    physicsBack(a)
                    HZ.hot[key] = t + HZ.HOT_S
                    send("host.events", "HREVOKE\t" .. key)
                    count("hz_revoke")
                end
            end
        end
    end
end

---------------------------------------------------------------------------------------------------
-- World doors (owner, alpha 16: "a container with its door open and a chest inside - shut on the friend's side"):
-- the buildings' and containers' doors (BP_Door_Single_C, BP_Door_Sliding_Single_C and their kinds) keep CurrentState
-- (0 shut, 2 open, 3 locked; the zone opens some at random) and were never synced - a door opened on one side stayed
-- shut on the other. Matched by place (the dressing's doors are not in the key map):
--   DS <x> <y> <z> <state>    host -> guest   a door's state (the changed ones every 1 s, all of them every 20 s)
--   DSR <x> <y> <z> <state>   guest -> host   the guest opened / shut one: the host's does the same, then DS back
-- "Set Door from State" sets a door to a state (its swing, its lock), ForceUnlockDoor first out of the locked state.
DOORS = { last = {}, sentAll = -1e9, scanAt = -1e9, applied = {}, quiet = {} }
local DOOR_CLASSES = { "BP_Door_Single_C", "BP_Door_Sliding_Single_C" }
local function doorKey(l) return string.format("%d,%d,%d", math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5), math.floor(l.Z / 10 + 0.5)) end
local function doorList()
    -- (one search per half second: a full DS round asks for 60 doors at once)
    if DOORS.cache and os.clock() - DOORS.cache.at < 0.5 then return DOORS.cache.list end
    local out = {}
    for _, cn in ipairs(DOOR_CLASSES) do
        for _, d in ipairs(FindAllOf(cn) or {}) do
            if Sync.alive(d) and d:GetFullName():find(":PersistentLevel.", 1, true) then
                local ok, s = pcall(function() return d.CurrentState end)
                if ok and tonumber(s) then out[#out + 1] = { d = d, key = doorKey(d:K2_GetActorLocation()), state = tonumber(s) } end
            end
        end
    end
    DOORS.cache = { at = os.clock(), list = out }
    return out
end
-- the door nearest to x y z (10 units' grid: 3 cells at most), else nil
local function doorAt(x, y, z)
    local best, bd
    for _, e in ipairs(doorList()) do
        local l = Sync.alive(e.d) and e.d:K2_GetActorLocation() or { X = 1e12, Y = 0, Z = 0 }
        local d2 = (l.X - x * 10) ^ 2 + (l.Y - y * 10) ^ 2 + (l.Z - z * 10) ^ 2
        if d2 < 60 ^ 2 and (not bd or d2 < bd) then best, bd = e, d2 end
    end
    return best
end
local function setDoor(e, state)
    if e.state == state then return false end
    DOORS.quiet[e.key] = os.clock() + 2 -- (this side's own detection: not the player's doing)
    if e.state == 3 then pcall(function() e.d:ForceUnlockDoor() end) end
    return (pcall(function() e.d["Set Door from State"](e.d, state) end))
end
function DOORS.tick()
    local now = os.clock()
    if now - DOORS.scanAt < 1 then return end
    DOORS.scanAt = now
    local all = role == "host" and now - DOORS.sentAll > 20
    if all then DOORS.sentAll = now end
    for _, e in ipairs(doorList()) do
        local was = DOORS.last[e.key]
        DOORS.last[e.key] = e.state
        local x, y, z = e.key:match("^(-?%d+),(-?%d+),(-?%d+)$")
        if role == "host" then
            if all or (was and was ~= e.state) then send("host.events", string.format("DS\t%s\t%s\t%s\t%d", x, y, z, e.state)) count("ev_DS") end
        elseif was and was ~= e.state and DOORS.applied[e.key] ~= e.state and not ((DOORS.quiet[e.key] or 0) > now) then
            -- the guest's own door change (its E): to the host
            send("client.requests", string.format("DSR\t%s\t%s\t%s\t%d", x, y, z, e.state))
            count("rq_DSR")
        end
    end
end
-- host: the guest's change; guest: the host's state
function DOORS.handle(t)
    local x, y, z, s = tonumber(t[2]), tonumber(t[3]), tonumber(t[4]), tonumber(t[5])
    if not (x and y and z and s) then return end
    local e = doorAt(x, y, z)
    if not e then count(t[1] == "DS" and "ap_DS_missing" or "req_DSR_missing") return end
    if t[1] == "DS" then DOORS.applied[e.key] = s end
    if setDoor(e, s) then
        DOORS.last[e.key] = s
        count(t[1] == "DS" and "ap_DS" or "req_DSR_done")
        -- (the host's own door now: sent back as DS with its next scan - every guest sees it)
        if t[1] == "DSR" then DOORS.last[e.key] = -1 end
    end
end

---------------------------------------------------------------------------------------------------
-- Abandoned cars' paint (owner's alpha 19 item 16: "all abandoned cars on the guest have the same orange-blue paint").
-- A BP_Template_BaseVehicle_C picks its paint / decal palette at random (ChoosePaintAndDecalPalettes) and builds its
-- dynamic materials (SetupMaterials, SetupTintOnVehicleAndParts); the guest's never built them (probed 2026-11-03: no
-- dynamic materials, the mesh's own MI_CivCar_Metal_Painted_Rust - most stood in BP_Palette_Paint_Crafted_01). The
-- host sends each one's palettes by place, the guest sets them and builds the materials (then the same colours):
--   VP <x> <y> <z> <paint class> <decal class>   host -> guest   all of them every 20 s (the first after 3 s)
CoopSyncPaint = { sentAt = -1e9, startAt = nil, applied = {}, pal = {} }
local function paintList()
    local out = {}
    for _, c in ipairs(FindAllOf("BP_Template_BaseVehicle_C") or {}) do
        if Sync.alive(c) and c:GetFullName():find(":PersistentLevel.", 1, true) then
            local l = c:K2_GetActorLocation()
            if math.abs(l.X) + math.abs(l.Y) > 1000 then out[#out + 1] = { c = c, l = l } end -- (not the parked ones at 0, 0)
        end
    end
    return out
end
local function classPath(c)
    local ok, p = pcall(function() return c:GetFullName() end)
    return ok and p and (p:gsub("^%S+%s+", "")) or ""
end
function CoopSyncPaint.tick()
    local P = CoopSyncPaint
    if role ~= "host" then return end
    local now = os.clock()
    P.startAt = P.startAt or now
    if now - P.startAt < 3 or now - P.sentAt < 20 then return end
    P.sentAt = now
    for _, e in ipairs(paintList()) do
        local okP, pp = pcall(function() return classPath(e.c.SelectedPaintPalette) end)
        local okD, dp = pcall(function() return classPath(e.c.SelectedDecalPalette) end)
        if okP and pp ~= "" then
            send("host.events", string.format("VP	%d	%d	%d	%s	%s", math.floor(e.l.X / 10 + 0.5), math.floor(e.l.Y / 10 + 0.5), math.floor(e.l.Z / 10 + 0.5), pp, okD and dp or ""))
            count("ev_VP")
        end
    end
end
function CoopSyncPaint.palette(path)
    local P = CoopSyncPaint
    if path == "" then return nil end
    local c = P.pal[path]
    if c and c:IsValid() then return c end
    c = SFO(path)
    if not (c and c:IsValid()) then pcall(function() LoadAsset((path:gsub("%.[^.]+$", ""))) end) c = SFO(path) end
    if c and c:IsValid() then P.pal[path] = c return c end
    return nil
end
function CoopSyncPaint.handle(t)
    local P = CoopSyncPaint
    local x, y, z, pp, dp = tonumber(t[2]), tonumber(t[3]), tonumber(t[4]), t[5] or "", t[6] or ""
    if not (x and y and z) then return end
    local key = x .. "," .. y .. "," .. z
    -- (applied once per place before; owner's alpha 20 test: all the guest's wrecks orange-blue again - a wreck whose
    -- dynamic materials are gone again, or never built, is done again on the host's next line, every 20 s)
    if not (P.list and os.clock() - P.list.at < 1) then
        -- (and each wreck's attached parts, by the wreck's address: the parts' paint below)
        local parts = {}
        for _, p in ipairs(FindAllOf("LootableTemplatePart") or {}) do
            local okA, a = pcall(function() return p:IsValid() and p:GetAttachParentActor() end)
            if okA and a and a:IsValid() then
                local k = a:GetAddress()
                parts[k] = parts[k] or {}
                parts[k][#parts[k] + 1] = p
            end
        end
        P.list = { at = os.clock(), l = paintList(), parts = parts }
    end
    local was = P.applied[key]
    if was and was.v == pp .. dp and Sync.alive(was.car) then
        local okN, nm = pcall(function() return #was.car.DynamicMaterialInstances end)
        if okN and nm > 0 then P.paintParts(was) return end
        count("ap_VP_again")
    end
    local best, bd
    for _, e in ipairs(P.list.l) do
        local d2 = (e.l.X - x * 10) ^ 2 + (e.l.Y - y * 10) ^ 2 + (e.l.Z - z * 10) ^ 2
        if d2 < 150 ^ 2 and (not bd or d2 < bd) then best, bd = e, d2 end
    end
    if not (best and Sync.alive(best.c)) then count("ap_VP_missing") return end
    local pal, dec = P.palette(pp), P.palette(dp)
    if not pal then count("ap_VP_no_palette") return end
    local car = best.c
    local ok = pcall(function()
        car.SelectedPaintPalette = pal
        if dec then car.SelectedDecalPalette = dec end
        car:SetupMaterials()
        car:SetupTintOnVehicleAndParts()
    end)
    P.applied[key] = { v = pp .. dp, car = car, pal = pal, dec = dec, done = {} }
    local okN, nm = pcall(function() return #car.DynamicMaterialInstances end)
    count(ok and (okN and nm > 0 and "ap_VP" or "ap_VP_no_mid") or "ap_VP_failed")
    P.paintParts(P.applied[key])
end
-- The parts' paint (owner, 2026-11-09: "all the guest's abandoned cars orange-blue - for a long time"; the palettes and
-- the body's materials above were the same since alpha 19, the doors / panels / hood / trunk still in their material's
-- own orange-blue): a part is painted by its BP_TintableComponent from its item's tint property, which the wreck's
-- SetupTintOnVehicleAndParts sets for the parts in its AttachedParts - empty on the guest, whose parts lootsync
-- attached again (probed: the host's door material with 7 colour parameters, the guest's with none). Each part's
-- tintable component gets the wreck's palettes (SetPaint / SetDecal, as the game's paint does), once per part: a part
-- attached later (an import again) is painted on the host's next line.
function CoopSyncPaint.paintParts(e)
    local P = CoopSyncPaint
    if not P.tintCls then
        local any = FindFirstOf("BP_TintableComponent_C")
        if not (any and any:IsValid()) then return end
        P.tintCls = any:GetClass()
    end
    local list = P.list and P.list.parts and P.list.parts[e.car:GetAddress()] or {}
    for _, p in ipairs(list) do
        local k = Sync.alive(p) and (p:GetAddress() .. p:GetFName():ToString()) -- (a freed address is used again)
        if k and not e.done[k] then
            e.done[k] = true
            local tc = p:GetComponentByClass(P.tintCls)
            if tc and tc:IsValid() then
                local okT = pcall(function()
                    tc:SetPaint(e.pal, {})
                    if e.dec then tc:SetDecal(e.dec, {}) end
                end)
                count(okT and "ap_VP_part" or "ap_VP_part_failed")
            end
        end
    end
end

-- Gameplay events (owner, alpha 19 items 10 / 15: "anomaly clouds at different places on the map", "the guest got a
-- high-radiation event the host had not"): each game's BP_GameplayEventDirector_C rolled its own events - a
-- GEV_BaseGameplayEvent_C status effect on the director's event item, a locational one with a BP_LocationalEvent_C cloud
-- (its map icon) that drifts from a random start (StartLoc, MoveDirecton, MoveSpeed, SizeOfEvent); more than one can
-- run (a GEV_WindSquall and a GEV_HeavyFog at once, no cloud for the fog). Probed 2026-11-04 (Wilderness_Swamp_14): the
-- host in a GEV_WindSquall, the guest in none. Now the guest's director rolls none (ForceNoEvents) and the host's
-- events are the guest's:
--   GE <event>...   every 2 s, "-" = none; an event: <id>,<class>[,<x>,<y>,<z>,<start x>,<start y>,<dir x>,<dir y>,<speed>,<size>]
-- the guest starts the host's main event's class once per host event (its object's name; Internal_StartNewEvent:
-- probed, the cloud spawns), gives the cloud the host's start, way, speed and size and puts it where the host's is
-- (when > 300 off). Any other event of the guest's ends (the director's ClearCurrentEvent left them - its CurrentEvent
-- stays empty, they live on its event item). An event the guest's game ended first is not started again.
CoopSyncEvent = { sentAt = -1e9, cls = {}, map = {}, done = {}, ended = {} }
-- the events running: an ended one stays a while, its cloud winding down (InWindDown; IsRemoved still false - probed)
function CoopSyncEvent.live()
    local out = {}
    for _, e in ipairs(FindAllOf("GEV_BaseGameplayEvent_C") or {}) do
        if e:IsValid() and not e:GetFullName():find("Default__", 1, true) then
            local a = e.LocationEventActor
            if not (a and a:IsValid() and a.InWindDown) then out[e:GetFName():ToString()] = e end
        end
    end
    return out
end
function CoopSyncEvent.tick()
    local E = CoopSyncEvent
    if role ~= "host" then return end
    local now = os.clock()
    if now - E.sentAt < 2 then return end
    E.sentAt = now
    local line = { "GE" }
    for id, e in pairs(E.live()) do
        local f = { id, (e:GetClass():GetFullName():gsub("^%S+%s+", "")) }
        local a = e.LocationEventActor
        if a and a:IsValid() then
            local l = a:K2_GetActorLocation()
            for _, v in ipairs({ l.X, l.Y, l.Z, a.StartLoc.X, a.StartLoc.Y }) do f[#f + 1] = string.format("%.0f", v) end
            for _, v in ipairs({ a.MoveDirecton.X, a.MoveDirecton.Y }) do f[#f + 1] = string.format("%.4f", v) end
            f[#f + 1] = string.format("%.1f", a.MoveSpeed)
            f[#f + 1] = string.format("%.0f", a.SizeOfEvent)
        end
        line[#line + 1] = table.concat(f, ",")
    end
    if #line == 1 then line[2] = "-" end
    send("host.events", table.concat(line, "\t"))
    count("ev_GE")
end
function CoopSyncEvent.class(path)
    local E = CoopSyncEvent
    local cls = E.cls[path]
    if not (cls and cls:IsValid()) then
        cls = SFO(path)
        if not (cls and cls:IsValid()) then pcall(function() LoadAsset((path:gsub("_C$", ""))) end) cls = SFO(path) end
        E.cls[path] = cls
    end
    return cls and cls:IsValid() and cls or nil
end
-- the host's cloud on the guest's copy of the event
function CoopSyncEvent.cloud(e, v)
    local a = e.LocationEventActor
    local x, y, z = tonumber(v[3]), tonumber(v[4]), tonumber(v[5])
    if not (x and y and z and tonumber(v[11]) and a and a:IsValid()) then return end
    if a.MoveSpeed ~= tonumber(v[10]) or math.abs(a.SizeOfEvent - tonumber(v[11])) > 1 then
        a.StartLoc = { X = tonumber(v[6]), Y = tonumber(v[7]), Z = z }
        a.MoveDirecton = { X = tonumber(v[8]), Y = tonumber(v[9]), Z = 0 }
        a.MoveSpeed, a.SizeOfEvent = tonumber(v[10]), tonumber(v[11])
        pcall(function() a:ConfigureVisuals() end)
        count("ap_GE_cloud")
    end
    local l = a:K2_GetActorLocation()
    if (l.X - x) ^ 2 + (l.Y - y) ^ 2 > 300 ^ 2 then
        a:K2_SetActorLocation({ X = x, Y = y, Z = z }, false, {}, true)
        count("ap_GE_moved")
    end
end
function CoopSyncEvent.handle(t)
    local E = CoopSyncEvent
    local d = FindFirstOf("BP_GameplayEventDirector_C")
    if not (d and d:IsValid()) then count("ap_GE_no_director") return end
    if not d.ForceNoEvents then d.ForceNoEvents = true count("ap_GE_own_off") end
    -- the host's main event: the one with a cloud, else the first (a new event started ends the director's last one:
    -- probed - so one copy)
    local v
    for i = 2, #t do
        local f = {}
        for x in t[i]:gmatch("[^,]+") do f[#f + 1] = x end
        if f[2] and f[2]:sub(1, 1) == "/" and (not v or (#f >= 11 and #v < 11)) then v = f end
    end
    local live, keep = E.live(), nil
    if v then
        local id, g = v[1], nil
        g = E.map[id] and live[E.map[id]]
        if not g and not E.done[id] then
            E.done[id] = true
            local cls = E.class(v[2])
            if cls and pcall(function() d:Internal_StartNewEvent(cls) end) then
                -- (its copy found by class: an event of the guest's own may start at the same moment - its async load)
                for name, e in pairs(E.live()) do
                    if not live[name] and e:GetClass():GetAddress() == cls:GetAddress() then E.map[id], g = name, e end
                end
                count(g and "ap_GE" or "ap_GE_unseen")
            else
                count("ap_GE_failed")
            end
        end
        if g then
            keep = E.map[id]
            pcall(E.cloud, g, v)
        end
    end
    -- the guest's others end (UStatusEffectLibrary.Remove: at once, probed; RemoveFrom right after an event's start did
    -- not end it once); three tries each
    E.lib = E.lib and E.lib:IsValid() and E.lib or SFO("/Script/PenDriverPro.Default__StatusEffectLibrary")
    for name, e in pairs(E.live()) do
        if name ~= keep and (E.ended[name] or 0) < 3 then
            E.ended[name] = (E.ended[name] or 0) + 1
            local ok = E.lib and pcall(function() E.lib:Remove(e) end) or pcall(function() e:RemoveFrom() end)
            if ok then count("ap_GE_ended") end
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Stray hazards (owner, alpha 19 item 11: "the guest sees a pillar anomaly from under the ground that the host has
-- not"). The import's cleanup removes the guest's own roots once; hazards its game spawns later (an event's copy, a
-- spawner or a helper waking up) stayed - an anomaly the host never had. The guest's copies of the host's hazards
-- are all mapped (the import, S); every STRAY.EVERY_S a hazard in the level mapped to no host key for STRAY.GRACE_S (time
-- for the host's S of the same one to arrive) is destroyed (a pooled one is parked by its pool).
CoopSyncStray = { at = -1e9, seen = {} }
local STRAY = CoopSyncStray
STRAY.EVERY_S = 3
STRAY.GRACE_S = 6
function STRAY.tick()
    if role == "host" then return end
    local now = os.clock()
    if now - STRAY.at < STRAY.EVERY_S then return end
    STRAY.at = now
    local seen, mapped = {}, {}
    -- (every copy of a host actor, whoever mapped it: the import, its repair after the cleanup, S, a respawn)
    for _, p in pairs(CoopSyncMap or {}) do mapped[p] = true end
    -- (the hazards' base class: ~2 ms; the guest keeps no root scan of its own and a full one is ~16 ms)
    for _, a in ipairs(FindAllOf("BP_Base_Hazard_C") or {}) do
        local p = CoopSyncUsable(a) and Sync.ref(a)
        if p and p:find(":PersistentLevel.", 1, true) and not mapped[p] and not reverse[p] and not Sync.inPool(a)
            and not (CoopSyncKeep or {})[a:GetFullName()] and Sync.isRoot(a) then
            local ok, c = pcall(function() return a:GetClass():GetFName():ToString() end)
            if ok and Sync.matches(c) then
                seen[p] = STRAY.seen[p] or now
                if now - seen[p] >= STRAY.GRACE_S then
                    seen[p] = nil
                    if pcall(function() a:K2_DestroyActor() end) then count("stray_hazard") end
                end
            end
        end
    end
    STRAY.seen = seen
end

---------------------------------------------------------------------------------------------------
-- Knocked and kicked objects (owner, alpha 18 items 31 / 38: "a tree / barrel / physical object knocked by the host's
-- car stays standing on the guest", "destruction / pushing objects by a kick not synced"). The breakables are
-- BP_Crash_Base_C actors: placed ones (BP_Destruct_*, in the spawn list) and ones the foliage manager swaps in for a
-- foliage / road-spline instance near the player (BP_IF_* shrubs and trees, cones, signs: each side swaps in its own,
-- at the same places). A break is SimpleBreak(Impulse) / ComplexBreak(BreakImpulse, BreakingPrimitive), a kick
-- ObjectKicked(component, location, vector). Each side's game breaks only what its own car / player hits - the other's
-- car is a kinematic twin its game does not count (probed 2026-11-02: the host's car broke three shrubs, the guest's
-- copies stayed) - so each side sends its own and the other repeats it on its copy, found by class and place:
--   KB <class> <x> <y> <z> <ix> <iy> <iz>                 a break (the actor's place in 10 units, the impulse)
--   KK <class> <x> <y> <z> <lx> <ly> <lz> <vx> <vy> <vz>  a kick (the kick's place and vector)
-- host -> guest on the events, guest -> host on the requests. A break of one the other side has not swapped in yet
-- (its player far) waits until it is (SetupSwappable).
local CRASH_DIR = "/Game/Gameplay/Destruction/Base/"
local KNOCK_FNS = {
    { fn = CRASH_DIR .. "BP_Crash_Simple_Base.BP_Crash_Simple_Base_C:SimpleBreak", kind = "B" },
    { fn = CRASH_DIR .. "BP_Crash_Complex_Base.BP_Crash_Complex_Base_C:ComplexBreak", kind = "B" },
    { fn = CRASH_DIR .. "BP_Crash_Complex_Foliage_Base.BP_Crash_Complex_Foliage_Base_C:ComplexBreak", kind = "B" },
    { fn = CRASH_DIR .. "BP_Crash_Simple_Base.BP_Crash_Simple_Base_C:ObjectKicked", kind = "K" },
    { fn = CRASH_DIR .. "BP_Crash_Complex_Base.BP_Crash_Complex_Base_C:ObjectKicked", kind = "K" },
    { fn = CRASH_DIR .. "BP_Crash_Base.BP_Crash_Base_C:SetupSwappable", kind = "S" },
}
local COMPLEX_CLS = CRASH_DIR .. "BP_Crash_Complex_Base.BP_Crash_Complex_Base_C"
CoopSyncKnock = CoopSyncKnock or { hooked = {}, quiet = false }
local KNOCK = CoopSyncKnock
local KNOCK_PER_TICK = 3 -- (a find per line: a crash through a row of cones sends a burst)
local function v3(p)
    local ok, v = pcall(function() local x = p:get() return { X = x.X, Y = x.Y, Z = x.Z } end)
    return ok and v or nil
end
local function knockKey(cls, l) return cls .. "@" .. doorKey(l) end
-- the other player's car on this side (the twin): what a repeated break is broken by
local function otherCarPrimitive()
    local P = rawget(_G, "CoopPlayers")
    local T = P and P.twinModule and P.twinModule()
    if not T then return nil end
    for _, x in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
        if x:IsValid() and T.isTwin(x) then return x.RootComponent end
    end
    return nil
end
local function onKnock(kind, a, p1, p2, p3)
    if M.stopped or not role or not Sync.alive(a) then return end
    local cls = Sync.clsName(a)
    local l = a:K2_GetActorLocation()
    local key = knockKey(cls, l)
    local x, y, z = doorKey(l):match("^(-?%d+),(-?%d+),(-?%d+)$")
    local line
    if kind == "S" then
        -- swapped in on this side: a break the other side sent for it is due now (next tick, out of its BeginPlay)
        if KNOCK.pending[key] then KNOCK.queue[#KNOCK.queue + 1] = KNOCK.pending[key] KNOCK.pending[key] = nil end
        return
    elseif kind == "B" then
        if KNOCK.done[key] then return end -- (the foliage base's break calls the complex one: one line)
        KNOCK.done[key] = true
        local i = v3(p1) or { X = 0, Y = 0, Z = 0 }
        line = string.format("KB\t%s\t%s\t%s\t%s\t%.0f\t%.0f\t%.0f", cls, x, y, z, i.X, i.Y, i.Z)
    else
        local kl, kv = v3(p2), v3(p3)
        if not (kl and kv) then return end
        line = string.format("KK\t%s\t%s\t%s\t%s\t%.0f\t%.0f\t%.0f\t%.1f\t%.1f\t%.1f", cls, x, y, z, kl.X, kl.Y, kl.Z, kv.X, kv.Y, kv.Z)
    end
    if role == "host" then send("host.events", line) count("ev_K" .. kind) else send("client.requests", line) count("rq_K" .. kind) end
end
local function hookKnocks()
    KNOCK.notify = onKnock
    for _, h in ipairs(KNOCK_FNS) do
        if not KNOCK.hooked[h.fn] then
            if isFunction(h.fn) then
                KNOCK.hooked[h.fn] = true
                local kind = h.kind
                Hook(h.fn, function(ctx, p1, p2, p3)
                    if KNOCK.quiet or not KNOCK.notify then return end
                    local ok, a = pcall(function() return ctx:get() end)
                    if ok and a then pcall(KNOCK.notify, kind, a, p1, p2, p3) end
                end)
            else
                count("knock_fn_missing")
            end
        end
    end
end
-- this side's breakable of that class at that place (60 units), else nil
local function crashAt(cls, x, y, z)
    for _, a in ipairs(FindAllOf(cls) or {}) do
        if Sync.alive(a) then
            local l = a:K2_GetActorLocation()
            if (l.X - x * 10) ^ 2 + (l.Y - y * 10) ^ 2 + (l.Z - z * 10) ^ 2 < 60 ^ 2 then return a end
        end
    end
    return nil
end
local function applyKnock(e)
    local a = crashAt(e.cls, e.x, e.y, e.z)
    local tag = e.op == "KB" and (role == "host" and "req_KB" or "ap_KB") or (role == "host" and "req_KK" or "ap_KK")
    if not a then
        -- a break of one not swapped in here: when it is (a kick of one far away is let go)
        if e.op == "KB" then KNOCK.pending[e.key] = e count(tag .. "_pending") else count(tag .. "_missing") end
        return
    end
    KNOCK.quiet = true
    local ok = pcall(function()
        if e.op == "KK" then
            a:ObjectKicked(a.BaseMesh, e.at, e.vec)
        elseif a.IsBroken then
            -- (broken here already: both cars hit it)
        elseif a:IsA(SFO(COMPLEX_CLS)) then
            a:ComplexBreak(e.vec, otherCarPrimitive())
        else
            a:SimpleBreak(e.vec)
        end
    end)
    KNOCK.quiet = false
    if e.op == "KB" then KNOCK.done[e.key] = true end
    count(ok and tag or tag .. "_failed")
end
function KNOCK.handle(t)
    local x, y, z = tonumber(t[3]), tonumber(t[4]), tonumber(t[5])
    if not (t[2] and x and y and z) then return end
    local e = { op = t[1], cls = t[2], x = x, y = y, z = z, key = t[2] .. "@" .. string.format("%d,%d,%d", x, y, z) }
    if t[1] == "KB" then
        if KNOCK.done[e.key] then count("kb_already") return end
        e.vec = { X = tonumber(t[6]) or 0, Y = tonumber(t[7]) or 0, Z = tonumber(t[8]) or 0 }
    else
        e.at = { X = tonumber(t[6]) or 0, Y = tonumber(t[7]) or 0, Z = tonumber(t[8]) or 0 }
        e.vec = { X = tonumber(t[9]) or 0, Y = tonumber(t[10]) or 0, Z = tonumber(t[11]) or 0 }
    end
    KNOCK.queue[#KNOCK.queue + 1] = e
end
function KNOCK.tick()
    for _ = 1, KNOCK_PER_TICK do
        local e = table.remove(KNOCK.queue, 1)
        if not e then return end
        applyKnock(e)
    end
end

-- Hazards go off through the host. Every hazard class with a StartExplode event (landmines; the electric
-- mine overrides it) gets a pre-hook: on the host it sends X <key> (the client's copy goes off too, with
-- its effect, instead of just vanishing on the following D); on the client a mine this player set off
-- sends BOOM <key> and the host sets off its own. Hooks are registered once per Lua state and call the
-- current module (tests reload it).
local function onExplode(a)
    if M.stopped or not role then return end
    local path = Sync.ref(a)
    if role == "host" then
        send("host.events", "X\t" .. path)
        count("ev_X")
    else
        local key = reverse[path]
        if not key or remoteBoom[key] then return end
        exploding[key] = true
        -- a blast sets off its neighbours: only the first mine of a burst is the player's doing, the host
        -- runs its own chain reaction and sends X for it (sending every neighbour ping-ponged whole fields)
        if os.clock() - lastBlast < CHAIN_WINDOW_S then lastBlast = os.clock() count("boom_chain_local") return end
        lastBlast = os.clock()
        send("client.requests", "BOOM\t" .. key)
        count("rq_BOOM")
    end
end
local function hop(name, t0) if CoopSyncHitch then CoopSyncHitch.op(name, (os.clock() - t0) * 1000) end end
local function hookHazards()
    CoopSyncHazardHooks = CoopSyncHazardHooks or { done = {} }
    CoopSyncHazardHooks.notify = onExplode
    local seen = {}
    for _, a in ipairs(Sync.roots(true) or {}) do -- (fresh: the last scan's paths may be of an earlier visit)
        local c = Sync.clsName(a)
        if c:find("^BP_Hazard") and not seen[c] then
            seen[c] = true
            local cls = a:GetClass():GetFullName():gsub("^%S+%s+", "")
            local fn = cls .. ":StartExplode"
            if not CoopSyncHazardHooks.done[fn] and isFunction(fn) then
                CoopSyncHazardHooks.done[fn] = true
                pcall(Hook, fn, function(ctx)
                    local ok, self = pcall(function() return ctx:get() end)
                    if ok and self and CoopSyncHazardHooks.notify then pcall(CoopSyncHazardHooks.notify, self) end
                end)
            end
        end
    end
end

-- Anchors into the ARC (owner, alpha 18 item 39: "put into the ARC of the host's car by the guest: the exit's charge
-- only on the guest"). The ARC is the car's Gobbler part; each side has one, its own car's (a twin carries none), and
-- the charge is that Gobbler item's property. A deposit ends in the part's AddingAnchorCompleteLogic(anchor), which adds
-- that anchor's charge; called with a new anchor of the same archetype it charges the same way (probed 2026-11-01:
-- 0 -> 1.1). So each deposit goes to the other side and is repeated on its own ARC: both charges move together -
-- roughly: an anchor's charge is rolled per anchor (a medium one 1.1 / 1.3), and the exact value is out of Lua's reach
-- (the item properties' getter takes a class UE4SS cannot read from IP_Anchor / IP_Gobbler).
--   GOB <anchor archetype>   (guest -> host on the requests, host -> guest on the events)
local GOB_FN = "/Game/Gameplay/Inventory/Items/Car/Internal/Gobbler/BP_Carpart_Internal_Gobbler.BP_Carpart_Internal_Gobbler_C:AddingAnchorCompleteLogic"
CoopSyncGobbler = CoopSyncGobbler or { hooked = false, quiet = false }
local GOB = CoopSyncGobbler
local function onGobble(arch)
    if M.stopped or not role then return end
    if role == "host" then send("host.events", "GOB\t" .. arch) count("ev_GOB")
    else send("client.requests", "GOB\t" .. arch) count("rq_GOB") end
end
local function hookGobbler()
    GOB.notify = onGobble
    if GOB.hooked then return end
    GOB.hooked = true
    Hook(GOB_FN, function(ctx, anchor)
        if GOB.quiet or not GOB.notify then return end
        local ok, arch = pcall(function() return (anchor:get().Archetype:GetFullName():gsub("^%S+ ", "")) end)
        if ok and arch then pcall(GOB.notify, arch) end
    end)
end
-- the other side's deposit, on this side's own ARC
function GOB.apply(arch)
    local gob
    local P = rawget(_G, "CoopPlayers")
    local T = P and P.twinModule and P.twinModule()
    for _, x in ipairs(FindAllOf("BP_Carpart_Internal_Gobbler_C") or {}) do
        if x:IsValid() and not (T and T.isTwin(x:GetAttachParentActor())) then gob = x end
    end
    if not gob then return false end
    local inst = Loot.newItem(arch)
    if not (inst and inst:IsValid()) then return false end
    GOB.quiet = true
    local ok = pcall(function() gob:AddingAnchorCompleteLogic(inst) end)
    GOB.quiet = false
    return ok
end

-- The exit home (owner, alpha 18 item 40: "the host opened the exit: not opened on the guest, the instability did not
-- start closing"). Picking an exit portal on the ARC ends in the storm manager's "Select Exit Portal Actor"(portal): the
-- portal becomes the zone's exit (EvolvedGatewayExit) and ~10 s later the closing storm (BP_ZoneStormRoyale_C) spawns
-- around it (probed 2026-11-02). The portals are in the spawn list, so the pick is repeated on the other side with its
-- copy of the portal.
--   EXIT <portal key>   (guest -> host on the requests, host -> guest on the events)
local EXIT_FN = "/Game/Systems/Managers/BP_StormManager.BP_StormManager_C:Select Exit Portal Actor"
CoopSyncExit = CoopSyncExit or { hooked = false, quiet = false }
local EXIT = CoopSyncExit
local function onExitPick(p)
    if M.stopped or not role then return end
    local path = Sync.ref(p)
    if role == "host" then send("host.events", "EXIT\t" .. path) count("ev_EXIT") return end
    local key = reverse[path]
    if not key then count("rq_EXIT_unmapped") return end
    send("client.requests", "EXIT\t" .. key)
    count("rq_EXIT")
end
local function hookExit()
    EXIT.notify = onExitPick
    if EXIT.hooked then return end
    if not isFunction(EXIT_FN) then error("no " .. EXIT_FN) end
    EXIT.hooked = true
    Hook(EXIT_FN, function(ctx, portal)
        if EXIT.quiet or not EXIT.notify then return end
        local ok, p = pcall(function() return portal:get() end)
        if ok and p and p:IsValid() then pcall(EXIT.notify, p) end
    end)
end
-- the other side's pick, on this side's storm manager (a portal already picked is left alone)
function EXIT.apply(p)
    local m = first("BP_StormManager_C")
    if not (m and m:IsValid() and p and p:IsValid()) then return false end
    local okC, cur = pcall(function() local x = m.EvolvedGatewayExit return x and x:IsValid() and Sync.ref(x) end)
    if okC and cur == Sync.ref(p) then return true end
    EXIT.quiet = true
    local ok = pcall(function() m["Select Exit Portal Actor"](m, p) end)
    EXIT.quiet = false
    return ok
end

-- The instability storm (owner's alpha 21 test: "at an unstable junction my siren started and the instability came, my
-- friend's not"). Each side's storm manager (BP_StormManager_C) runs its own instability timer; when it runs out the
-- manager calls SpawnRoyaleStorm(location, fromTimer, gateway) - BP_ZoneStormRoyale_C, the walls closing in, its weak
-- storm darkening the sky (WeakStormOverride) - and ChangeStormTimerState (the ARC's storm state). The guest's did not
-- fire with the host's. A second SpawnRoyaleStorm while one is up does nothing (probed 2026-11-08). Now the host's go
-- to the guest:
--   STORM <x,y,z> <fromTimer 0/1> <gateway key | ->   host -> guest at the spawn, again every STORM.ALL_S while up
--   STST <state>                                      host -> guest on a change, again every STORM.ALL_S
-- (all in one table: statesync's main chunk is near Lua's 200 locals)
CoopSyncStorm = CoopSyncStorm or { hooked = false, quiet = false }
local STORM = CoopSyncStorm
STORM.ALL_S = 10
STORM.FN = "/Game/Systems/Managers/BP_StormManager.BP_StormManager_C:"
function STORM.line(loc, fromTimer, gw)
    local key = (gw and gw:IsValid()) and Sync.ref(gw) or "-"
    return string.format("STORM\t%.1f,%.1f,%.1f\t%d\t%s", loc.X, loc.Y, loc.Z, fromTimer and 1 or 0, key)
end
function STORM.on(kind, a, b, c)
    if M.stopped or not role then return end
    if role ~= "host" then count("own_" .. kind) return end -- (the guest's own timer: counted)
    if kind == "STORM" then
        local loc, ft, gw = a:get(), b:get(), nil
        pcall(function() gw = c:get() end)
        send("host.events", STORM.line(loc, ft, gw))
        STORM.sent = (STORM.sent or 0) + 1
    else
        local s = tonumber(a:get())
        STORM.state = s
        send("host.events", "STST\t" .. tostring(s))
    end
    count("ev_" .. kind)
end
function STORM.hook()
    STORM.notify = STORM.on
    if STORM.hooked then return end
    for _, f in ipairs({ "SpawnRoyaleStorm", "ChangeStormTimerState" }) do
        if not isFunction(STORM.FN .. f) then error("no " .. STORM.FN .. f) end
    end
    STORM.hooked = true
    -- (a pre-hook here runs after the body: the storm is up when it sends)
    Hook(STORM.FN .. "SpawnRoyaleStorm", function(_, loc, ft, gw)
        if STORM.quiet or not STORM.notify then return end
        pcall(STORM.notify, "STORM", loc, ft, gw)
    end)
    Hook(STORM.FN .. "ChangeStormTimerState", function(_, s)
        if STORM.quiet or not STORM.notify then return end
        pcall(STORM.notify, "STST", s)
    end)
end
-- The guest's own timer must not go off before the host's (owner, 2026-11-08). The timer (probed): the game calls
-- InstabilityTimerTick all along; while it runs the instability grows (IncrementStormInstability) and "Check
-- Instability" calls SpawnInstabilityStorm once it is past the tolerance (FinalInstabilityTollerance, rolled with a
-- random variance on each side - the guest's could be the lower one). So the host sends both every STORM.STI_S:
--   STI <instability> <tolerance>   host -> guest
-- and the guest takes the host's tolerance and holds its own instability at the host's, never closer than
-- STORM.MARGIN to the tolerance: its check never fires, the storm comes from the host's STORM line (and the ARC's
-- instability shows the host's). The hold runs on the guest's frames too (its own timer between two lines).
STORM.STI_S, STORM.MARGIN = 1, 0.02
function STORM.inst(m)
    local it = {}
    m:GetCurrentInstabilityTime(it)
    return tonumber(it.CurrentInstabilityTime) or 0
end
function STORM.hold(m, want)
    local tol = tonumber(m.FinalInstabilityTollerance) or 0
    if tol <= 0 then return "notol" end
    local cur = STORM.inst(m)
    local lim = tol * (1 - STORM.MARGIN)
    want = math.min(want or cur, lim)
    if math.abs(want - cur) < 0.5 then return "same" end
    m:IncrementStormInstability(want - cur)
    STORM.held = (STORM.held or 0) + 1
    return "held"
end
-- host: the storm that is up and the state, again every STORM.ALL_S (a guest that missed a line, a resync)
function STORM.tick()
    local now = os.clock()
    if role ~= "host" then
        -- (the guest: its own instability under the tolerance between two of the host's lines)
        if now - (STORM.holdAt or -1e9) < 0.25 then return end
        STORM.holdAt = now
        local m = first("BP_StormManager_C")
        if m and m:IsValid() then STORM.hold(m, nil) end
        return
    end
    if now - (STORM.stiAt or -1e9) >= STORM.STI_S then
        STORM.stiAt = now
        local m = first("BP_StormManager_C")
        if m and m:IsValid() then
            send("host.events", string.format("STI\t%.2f\t%.2f", STORM.inst(m), tonumber(m.FinalInstabilityTollerance) or 0))
        end
    end
    if now - (STORM.at or -1e9) < STORM.ALL_S then return end
    STORM.at = now
    local m = first("BP_StormManager_C")
    if not (m and m:IsValid()) then return end
    local s = m.SpawnedStormIfValid
    if s and s:IsValid() then
        local gw
        pcall(function() gw = s.SummonedExitGateway end)
        send("host.events", STORM.line(s:K2_GetActorLocation(), s.TimerSpawn, gw))
        count("ev_STORM_all")
        STORM.sent = (STORM.sent or 0) + 1
    end
    send("host.events", "STST\t" .. tostring(m.CurrentStormState))
end
-- guest: the host's storm here (none up yet) / the host's storm state
function STORM.apply(t)
    local m = first("BP_StormManager_C")
    if not (m and m:IsValid()) then return "nomanager" end
    if t[1] == "STI" then
        local tol = tonumber(t[3])
        if tol and tol > 0 then m.FinalInstabilityTollerance = tol end
        STORM.hostInst = tonumber(t[2])
        return STORM.hold(m, STORM.hostInst)
    end
    if t[1] == "STST" then
        local s = tonumber(t[2])
        if not s or m.CurrentStormState == s then return "same" end
        STORM.quiet = true
        local ok = pcall(function() m:ChangeStormTimerState(s) end)
        STORM.quiet = false
        return ok and "done" or "failed"
    end
    local cur = m.SpawnedStormIfValid
    if cur and cur:IsValid() then return "have" end
    local x, y, z = (t[2] or ""):match("^([-%d.]+),([-%d.]+),([-%d.]+)$")
    if not z then return "bad" end
    local gw = (t[4] and t[4] ~= "-") and resolve(t[4]) or nil
    STORM.quiet = true
    local ok = pcall(function() m:SpawnRoyaleStorm({ X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, t[3] == "1", gw) end)
    STORM.quiet = false
    cur = m.SpawnedStormIfValid
    return (ok and cur and cur:IsValid()) and "done" or "failed"
end

-- Fuel barrels (owner, alpha 18 item 37: "a fuel barrel's level differs"). A gas barrel (BP_Spawn_GasBarrel_C, in the
-- spawn list) rolls its fuel at BeginPlay (RandomizeFuel: each side's copy its own) and keeps it in its
-- BP_FuelableComponent (GetFuelStatus / "Set Fuel"; the actor's IP_Fuelable_Fuel stays the first roll - probed
-- 2026-11-02); siphoning it changed only that side's. Each side reads its barrels every second; one changed here (not
-- by the other side's line) goes over and the other side sets its copy. The host sends all of them every 30 s too.
--   FUEL <key> <fuel>   (host -> guest on the events, guest -> host on the requests)
-- Fuel canisters on the ground too (owner, 2026-11-09: "I dropped a full canister, the friend's was empty"): a world
-- item (BP_WorldItem_Fuelable_C, same BP_FuelableComponent) is spawned on the other side from its archetype, which
-- comes empty. The guest's drop carries its fuel (DROP's last field); one the host has not sent yet (new in its list,
-- which a pick-up / drop refreshes at once) goes over at once, and a line for a copy still spawning on the guest waits
-- for it (FUEL.pend, 30 s).
CoopSyncFuel = CoopSyncFuel or {}
local FUEL = CoopSyncFuel
FUEL.pend = FUEL.pend or {}
local FUEL_ALL_S = 30
local function fuelOf(a)
    local t = { {}, {}, {}, {}, {}, {}, {} }
    a.BP_FuelableComponent:GetFuelStatus(t[1], t[2], t[3], t[4], t[5], t[6], t[7])
    return math.floor((tonumber(t[1].Fuel) or 0) * 100 + 0.5) / 100
end
FUEL.of = fuelOf
function FUEL.set(a, v)
    if not (Sync.alive(a) and v) then return false end
    local ok = pcall(function() local fc = a.BP_FuelableComponent fc["Set Fuel"](fc, v) end)
    if ok then FUEL.last[Sync.ref(a)] = math.floor(v * 100 + 0.5) / 100 end
    return ok
end
function FUEL.tick()
    local now = os.clock()
    if now - FUEL.at < 1 then return end
    FUEL.at = now
    if LH.fuelInv and now - FUEL.listAt > 2 then LH.fuelInv = false FUEL.listAt = -1e9 end
    if now - FUEL.listAt > 10 then
        FUEL.listAt = now
        FUEL.list = {}
        for _, cls in ipairs({ "BP_Spawn_GasBarrel_C", "BP_WorldItem_Fuelable_C" }) do
            for _, a in ipairs(FindAllOf(cls) or {}) do if Sync.alive(a) then FUEL.list[#FUEL.list + 1] = a end end
        end
    end
    if role ~= "host" then
        for k, p in pairs(FUEL.pend) do
            local a = resolve(k)
            if a then FUEL.pend[k] = nil count(FUEL.set(a, p.v) and "ap_FUEL_late" or "ap_FUEL_failed")
            elseif now - p.at > 30 then FUEL.pend[k] = nil end
        end
    end
    local all = role == "host" and now - FUEL.sentAll > FUEL_ALL_S
    if all then FUEL.sentAll = now end
    for _, a in ipairs(FUEL.list) do
        local okF, v = pcall(fuelOf, a)
        if Sync.alive(a) and okF then
            local ref = Sync.ref(a)
            local was = FUEL.last[ref]
            FUEL.last[ref] = v
            local changed = was and math.abs(v - was) > 0.005
            if role == "host" then
                if all or changed or was == nil then send("host.events", "FUEL\t" .. ref .. "\t" .. v) count("ev_FUEL") end
            elseif changed and reverse[ref] then
                send("client.requests", "FUEL\t" .. reverse[ref] .. "\t" .. v)
                count("rq_FUEL")
            end
        end
    end
end

-- Abandoned cars' parts (owner, 2026-11-09: "on an abandoned car the friend sawed off the whole white bar of a part,
-- the red one never started, so the part could not be broken"; "the parts' breakage is not synced"). A wreck part's
-- BP_HealthComponent_C has the health (the white bar) and, once that is gone, the break health (the red one, filled up
-- to the item's MaxBreak by more hits, then the part breaks off) - only if the component's CanBeBreaking is set (the
-- game sets it on its own parts: 169/169 on the host; the guest's parts are the host's attached by lootsync, 0/169:
-- now set there, see lootsync applyTemplate). Each side also rolled its own health (a wheel 108 on the host, 10 on the
-- guest) and saw only its own hits. Now a hit on a wreck part (the component's "Process Damage Message", hooked: it
-- only marks the part) sends the part's two values over on the next frames, the other side sets them on its copy; the
-- host sends every part's every WRK.ALL_S (the guest's own roll, a lost line; a part this side hit in the last
-- WRK.HOLD_S keeps its own). A part broken off goes as before (the loot's part list).
--   WPH <wreck key> <socket> <health> <break health>   (host -> guest on the events, guest -> host on the requests)
CoopSyncWreck = CoopSyncWreck or { hooked = false }
do -- (a block: statesync's main chunk is near Lua's 200 locals; outside it is CoopSyncWreck)
local WRK = CoopSyncWreck
WRK.ALL_S, WRK.HOLD_S, WRK.WATCH_S, WRK.SWEEP_S = 30, 3, 1, 10
WRK.HC = "/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_HealthComponent.BP_HealthComponent_C"
function WRK.hook()
    WRK.notify = function(comp)
        local p = comp:GetOwner()
        if p and p:IsValid() and p:IsA(WRK.partCls) then WRK.dirty[p:GetAddress()] = { p = p, at = os.clock() } end
    end
    if WRK.hooked then return end
    if not isFunction(WRK.HC .. ":Process Damage Message") then error("no Process Damage Message") end
    WRK.hooked = true
    Hook(WRK.HC .. ":Process Damage Message", function(self)
        if not WRK.notify then return end
        pcall(WRK.notify, self:get())
    end)
end
function WRK.values(p)
    local hc = p:GetComponentByClass(WRK.hcCls)
    if not (hc and hc:IsValid()) then return nil end
    return math.floor(hc:HC_GetHealth() * 10 + 0.5) / 10, math.floor(hc:HC_GetBreakHealth() * 10 + 0.5) / 10, hc
end
-- the part's wreck key (the host's) and socket, or nil
function WRK.keyOf(p)
    local w = p:GetAttachParentActor()
    if not (w and w:IsValid()) then return nil end
    local ref = Sync.ref(w)
    local key = role == "host" and ref or reverse[ref]
    return key, p.MySocket:ToString()
end
function WRK.sendPart(p, force)
    local key, sock = WRK.keyOf(p)
    if not key then return end
    local h, b = WRK.values(p)
    if not h then return end
    local k = key .. "\t" .. sock
    local was = WRK.last[k]
    if not force and was and was[1] == h and was[2] == b then return end
    WRK.last[k] = { h, b }
    send(role == "host" and "host.events" or "client.requests", string.format("WPH\t%s\t%s\t%.1f\t%.1f", key, sock, h, b))
    WRK.sent = (WRK.sent or 0) + 1
    count(role == "host" and "ev_WPH" or "rq_WPH")
end
function WRK.tick()
    WRK.partCls = WRK.partCls or StaticFindObject("/Script/PenDriverPro.LootableTemplatePart")
    WRK.hcCls = WRK.hcCls or StaticFindObject(WRK.HC)
    if not (WRK.partCls and WRK.partCls:IsValid() and WRK.hcCls and WRK.hcCls:IsValid()) then return end
    local now = os.clock()
    -- (the hit's effect shows on the next frames: a hit part is read for WATCH_S after its last hit)
    for addr, e in pairs(WRK.dirty) do
        if not e.p:IsValid() or now - e.at > WRK.WATCH_S then WRK.dirty[addr] = nil
        else
            WRK.mine[addr] = now
            pcall(WRK.sendPart, e.p, false)
        end
    end
    if role ~= "host" then
        -- (lines whose part was not there yet - lootsync attaches the host's parts over a few frames; part-break-test
        -- 2026-11-09: two parts kept the guest's own health until the host's next full list 30 s later): once a
        -- second, the index built again, for up to 60 s
        if next(WRK.missed) and now - (WRK.missedAt or -1e9) >= 1 then
            WRK.missedAt, WRK.indexAt = now, -1e9
            local list = {}
            for k, e in pairs(WRK.missed) do list[#list + 1] = { k, e } end
            for _, x in ipairs(list) do
                local k, e = x[1], x[2]
                local okA, r = pcall(WRK.apply, e.t)
                WRK.missed[k] = (okA and r == "nopart" and now - e.at < 60) and e or nil
                if okA and r ~= "nopart" then WRK.lateApplied = (WRK.lateApplied or 0) + 1 end
            end
        end
        -- the guest's parts are the host's attached by lootsync (AttachTemplatePart), never set up to break by the
        -- game: CanBeBreaking false (0 of 169; the host's 169 of 169), so once the health was gone more hits did
        -- nothing. Set at the start and every WRK.SWEEP_S for parts attached since; before any hit counts: the game
        -- starts the breaking as the health reaches zero.
        if now - WRK.sweepAt < WRK.SWEEP_S then return end
        WRK.sweepAt = now
        for _, p in ipairs(FindAllOf("LootableTemplatePart") or {}) do
            pcall(function()
                local hc = p:IsValid() and p:GetComponentByClass(WRK.hcCls)
                if hc and hc:IsValid() and not hc.CanBeBreaking then hc.CanBeBreaking = true WRK.breakable = (WRK.breakable or 0) + 1 end
            end)
        end
        return
    end
    if now - WRK.allAt < WRK.ALL_S then return end
    WRK.allAt = now
    for _, p in ipairs(FindAllOf("LootableTemplatePart") or {}) do
        if p:IsValid() then pcall(WRK.sendPart, p, true) end
    end
    count("ev_WPH_all")
end
-- the other side's values onto this side's copy of the part (key: the host's wreck key)
function WRK.apply(t)
    local w = role == "host" and Sync.deref(t[2]) or resolve(t[2])
    if not w then return "unmapped" end
    local h, b = tonumber(t[4]), tonumber(t[5])
    if not (h and b) then return "bad" end
    -- (parts by wreck address and socket, built at most every 5 s or when one is missing: the host's full list is
    -- 169 lines)
    local k = tostring(w:GetAddress()) .. "\t" .. t[3]
    local p = WRK.index and WRK.index[k]
    if not (p and p:IsValid()) and os.clock() - (WRK.indexAt or -1e9) > 5 then
        WRK.indexAt, WRK.index = os.clock(), {}
        for _, x in ipairs(FindAllOf("LootableTemplatePart") or {}) do
            local par = x:IsValid() and x:GetAttachParentActor()
            if par and par:IsValid() then WRK.index[tostring(par:GetAddress()) .. "\t" .. x.MySocket:ToString()] = x end
        end
        p = WRK.index[k]
    end
    do
        if p and p:IsValid() then
            if os.clock() - (WRK.mine[p:GetAddress()] or -1e9) < WRK.HOLD_S then return "mine" end
            local ch, cb, hc = WRK.values(p)
            if not ch then return "nohealth" end
            if not hc.CanBeBreaking then hc.CanBeBreaking = true end
            if math.abs(ch - h) >= 0.1 then hc:SetHealth(h) end
            if math.abs(cb - b) >= 0.1 then hc:SetBreakHealth(b) end
            WRK.last[t[2] .. "\t" .. t[3]] = { h, b }
            WRK.applied = (WRK.applied or 0) + 1
            return (math.abs(ch - h) >= 0.1 or math.abs(cb - b) >= 0.1) and "set" or "same"
        end
    end
    if role ~= "host" then local old = WRK.missed[k] WRK.missed[k] = { t = t, at = old and old.at or os.clock() } end
    return "nopart"
end
end

-- Range-started hazards (owner, alpha 18 item 23: "the saw lags on the guest", "the geyser fires later on the guest").
-- A saw blade (BP_Hazard_SawBlade_C: rises, runs its track, holds, runs back - timelines) and a geyser
-- (BP_Hazard_*Geyser_C: waves of acid globs) start when their BP_HazardProperty_PlayerRange component finds the local
-- player within DistanceToActivate (a 1 s timer; out again past + RangeBuffer) and call the actor's OnPlayerInRange /
-- OnPlayerOutOfRange event. Each side's copy started by its own player only, at its own moment, with its own random
-- saw Phase (probed 2026-11-02). Now the range timers are stopped on both sides and the host starts / stops its copy
-- by the nearer of the two players, and tells the guest, whose copy starts with the host's phase:
--   RG <key> 1 <phase> <dir> / RG <key> 0   host -> guest (again every RANGE_ALL_S for all started ones)
CoopSyncRange = CoopSyncRange or {}
local RANGE = CoopSyncRange
local RANGE_CLASSES = { "BP_Hazard_SawBlade_C", "BP_Hazard_SmallGeyser_C", "BP_Hazard_LargeGeyser_C", "BP_Hazard_Geyser_Large_C" }
local RANGE_ALL_S = 15
RANGE.fns = RANGE.fns or {} -- class name -> { inFn, outFn }
local function rangeFns(a)
    local cn = Sync.clsName(a)
    local f = RANGE.fns[cn]
    if f then return f end
    f = {}
    local cls = a:GetClass()
    while cls and cls:IsValid() and not (f.inFn and f.outFn) do
        cls:ForEachFunction(function(fn)
            local n = fn:GetFName():ToString()
            if n:find("PlayerRange.*OnPlayerInRange__DelegateSignature$") then f.inFn = f.inFn or n end
            if n:find("PlayerRange.*OnPlayerOutOfRange__DelegateSignature$") then f.outFn = f.outFn or n end
        end)
        cls = cls:GetSuperStruct()
    end
    RANGE.fns[cn] = f
    return f
end
local function rangeCall(a, on)
    local f = rangeFns(a)
    local n = on and f.inFn or f.outFn
    if not n then return false end
    return (pcall(function() a[n](a) end))
end
-- this side's copies: their range timers stopped (one running by this side's own player is stopped too)
function RANGE.scan()
    RANGE.list = {}
    for _, cn in ipairs(RANGE_CLASSES) do
        for _, a in ipairs(FindAllOf(cn) or {}) do
            if Sync.alive(a) then
                local c = a.BP_HazardProperty_PlayerRange
                if c and c:IsValid() then
                    local ref = Sync.ref(a)
                    if not RANGE.stopped[ref] then
                        RANGE.stopped[ref] = true
                        pcall(function() c:StopCheck() end)
                        local okI, was = pcall(function() return c.PlayerInRange end)
                        if okI and was then
                            pcall(function() c.PlayerInRange = false end)
                            if role == "host" then RANGE.inside[ref] = true else rangeCall(a, false) end
                        end
                        count("range_taken")
                    end
                    RANGE.list[#RANGE.list + 1] = { a = a, c = c, ref = ref }
                end
            end
        end
    end
end
local function rangeLine(e, on)
    local ph = ""
    if on then
        local ok, v, d = pcall(function() return e.a.Phase, e.a.Direction end)
        if ok and v then ph = string.format("\t%.5f\t%d", v, d and 1 or 0) end
    end
    send("host.events", "RG\t" .. e.ref .. "\t" .. (on and "1" or "0") .. ph)
end
function RANGE.tick()
    local now = os.clock()
    if now - RANGE.at < 0.5 then return end
    RANGE.at = now
    if now - RANGE.scanAt > 10 then RANGE.scanAt = now RANGE.scan() end
    if role ~= "host" then return end
    local all = now - RANGE.sentAll > RANGE_ALL_S
    if all then RANGE.sentAll = now end
    for _, e in ipairs(RANGE.list) do
        if Sync.alive(e.a) then
            local here, there = HZ.dists(e.a:K2_GetActorLocation())
            local d = math.min(here, there)
            local okD, reach = pcall(function() return e.c.DistanceToActivate end)
            local okB, buf = pcall(function() return e.c.RangeBuffer end)
            reach = okD and tonumber(reach) or 12000
            buf = okB and tonumber(buf) or 500
            local inside = RANGE.inside[e.ref]
            if not inside and d < reach then
                RANGE.inside[e.ref] = true
                count(rangeCall(e.a, true) and "range_in" or "range_in_failed")
                rangeLine(e, true)
            elseif inside and d > reach + buf then
                RANGE.inside[e.ref] = nil
                count(rangeCall(e.a, false) and "range_out" or "range_out_failed")
                rangeLine(e, false)
            elseif all and inside then
                rangeLine(e, true)
            end
        end
    end
end
-- guest: the host's start / stop on this side's copy
function RANGE.apply(t)
    local a = resolve(t[2])
    if not a then count("ap_RG_unmapped") return end
    local on = t[3] == "1"
    local ref = Sync.ref(a)
    if not RANGE.stopped[ref] then RANGE.scan() end
    if (RANGE.inside[ref] or false) == on then count("ap_RG_same") return end
    RANGE.inside[ref] = on or nil
    if on and t[4] then pcall(function() a.Phase = tonumber(t[4]) end) end
    if on and t[5] then pcall(function() a.Direction = t[5] == "1" end) end -- (the way its next run goes)
    count(rangeCall(a, on) and "ap_RG" or "ap_RG_failed")
end

-- Tourists (owner, alpha 18 item 23: "the mannequin is in other poses, it does not sway on a kick"). A tourist
-- (BP_Hazard_Landmine_C) rolls its body at BeginPlay - one of four meshes, a yaw / tilt, a mirrored scale - and the body
-- simulates on a constraint to its base: a kick or a car sways it. Each side rolled its own pose; a sway was each side's.
--   TP <key> <mesh> <pitch> <yaw> <roll> <sx> <sy> <sz>   host -> guest: the body's pose (each every TOUR_POSE_S)
--   TS <key> <vx> <vy> <vz>                                 both ways: a body began to sway here (its tip's velocity)
-- The other side pushes its copy's body at the tip the same, its tilt fuse off for a while (no blast the swaying side
-- did not have; a pose set is fused the same way). (An angular velocity set on the body died out in 0.2 s; a push at
-- the tip sways it ~1 s, as a kick does - probed 2026-11-02.)
CoopSyncTour = CoopSyncTour or {}
local TOUR = CoopSyncTour
local TOUR_CLS = "BP_Hazard_Landmine_C"
local TOUR_NEAR = 3000
local TOUR_SPIN = 30     -- deg/s: a body turning faster sways
local TOUR_QUIET_S = 2   -- after a sway sent / taken: not sent again
local TOUR_FUSE_S = 4    -- the taken sway's tilt fuse off this long
local TOUR_PER_TICK = 20 -- TP lines a tick
local TOUR_POSE_S = 30   -- each pose again this often (one the guest had not mapped yet)
local TOUR_PUSH_MAX = 500 -- cm/s at the tip
local function v3s(v) return string.format("%.1f\t%.1f\t%.1f", v.X, v.Y, v.Z) end
local function tourKey(a)
    local ref = Sync.ref(a)
    if role == "host" then return ref end
    return reverse[ref]
end
function TOUR.tick()
    local now = os.clock()
    if now - TOUR.listAt > 10 then
        TOUR.listAt = now
        TOUR.list = {}
        for _, a in ipairs(FindAllOf(TOUR_CLS) or {}) do if Sync.alive(a) then TOUR.list[#TOUR.list + 1] = a end end
    end
    -- the poses, a few a tick
    if role == "host" then
        local n = 0
        for _, a in ipairs(TOUR.list) do
            if n >= TOUR_PER_TICK then break end
            local ref = Sync.alive(a) and Sync.ref(a)
            if ref and now - (TOUR.posed[ref] or -1e9) > TOUR_POSE_S then
                TOUR.posed[ref] = now
                n = n + 1
                local ok, line = pcall(function()
                    local b = a.Body
                    local m = b.StaticMesh
                    local r, sc = b:K2_GetComponentRotation(), b.RelativeScale3D
                    return string.format("TP\t%s\t%s\t%.2f\t%.2f\t%.2f\t%.3f\t%.3f\t%.3f", ref, m:GetFullName():gsub("^%S+ ", ""), r.Pitch, r.Yaw, r.Roll, sc.X, sc.Y, sc.Z)
                end)
                if ok then send("host.events", line) count("ev_TP") end
            end
        end
    end
    -- the fuses back on
    for a, at in pairs(TOUR.fuse) do
        if now > at then TOUR.fuse[a] = nil pcall(function() a.PreventExplodeOnAngle = false end) end
    end
    -- the sways near this side's player, 10 times a second
    if now - TOUR.at < 0.1 then return end
    TOUR.at = now
    if now - TOUR.nearAt > 1 then
        TOUR.nearAt = now
        TOUR.near = {}
        local pts = {}
        pcall(function() pts[#pts + 1] = first("PlayerController").Pawn:K2_GetActorLocation() end)
        pcall(function() pts[#pts + 1] = first("BP_CarManager_C").NewCarActor:K2_GetActorLocation() end)
        for _, a in ipairs(TOUR.list) do
            if Sync.alive(a) then
                local l = a:K2_GetActorLocation()
                for _, p in ipairs(pts) do
                    if dist2(l, p) < TOUR_NEAR ^ 2 then TOUR.near[#TOUR.near + 1] = a break end
                end
            end
        end
    end
    for _, a in ipairs(TOUR.near) do
        if Sync.alive(a) then
            local ok, w = pcall(function() return a.Body:GetPhysicsAngularVelocityInDegrees(FName("None")) end)
            if ok and w and w.X * w.X + w.Y * w.Y + w.Z * w.Z > TOUR_SPIN ^ 2 then
                local key = tourKey(a)
                local okV, v = pcall(function() return a.Body:GetPhysicsLinearVelocityAtPoint(a.TipScene:K2_GetComponentLocation(), FName("None")) end)
                if key and okV and v and now - (TOUR.quiet[key] or -1e9) > TOUR_QUIET_S then
                    TOUR.quiet[key] = now
                    -- (a body in a heap or a blast flies off at 1000s: the other side's push held to a kick's)
                    local n = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
                    if n > TOUR_PUSH_MAX then v = { X = v.X / n * TOUR_PUSH_MAX, Y = v.Y / n * TOUR_PUSH_MAX, Z = v.Z / n * TOUR_PUSH_MAX } end
                    send(role == "host" and "host.events" or "client.requests", "TS\t" .. key .. "\t" .. v3s(v))
                    count(role == "host" and "ev_TS" or "rq_TS")
                end
            end
        end
    end
end
local function tourActor(key) if role == "host" then return Sync.deref(key) end return resolve(key) end
function TOUR.apply(t)
    local tag = role == "host" and "req_" or "ap_"
    local a = tourActor(t[2])
    if not a then count(tag .. t[1] .. "_missing") return end
    if t[1] == "TP" then
        local same = false
        local ok = pcall(function()
            local b = a.Body
            local cur = b.StaticMesh
            local sameMesh = cur and cur:IsValid() and cur:GetFullName():gsub("^%S+ ", "") == t[3]
            local r = b:K2_GetComponentRotation()
            local dy = math.abs(((r.Yaw - tonumber(t[5])) % 360 + 540) % 360 - 180)
            if sameMesh and dy < 2 and math.abs(r.Pitch - tonumber(t[4])) < 2 and math.abs(r.Roll - tonumber(t[6])) < 2 then same = true return end
            local w = b:GetPhysicsAngularVelocityInDegrees(FName("None"))
            if w.X * w.X + w.Y * w.Y + w.Z * w.Z > TOUR_SPIN ^ 2 then same = true return end -- (swaying: the next one)
            a.PreventExplodeOnAngle = true
            TOUR.fuse[a] = os.clock() + TOUR_FUSE_S
            if not sameMesh then
                local m = SFO(t[3])
                if not (m and m:IsValid()) then pcall(function() LoadAsset((t[3]:gsub("%.[^.]+$", ""))) end) m = SFO(t[3]) end
                b:SetStaticMesh(m)
            end
            b:SetRelativeScale3D({ X = tonumber(t[7]), Y = tonumber(t[8]), Z = tonumber(t[9]) })
            b:K2_SetWorldRotation({ Pitch = tonumber(t[4]), Yaw = tonumber(t[5]), Roll = tonumber(t[6]) }, false, {}, true)
            b:SetPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false, FName("None"))
            b:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName("None"))
            a:SetupConstraints()
        end)
        count(not ok and tag .. "TP_failed" or same and tag .. "TP_same" or tag .. "TP")
        return
    end
    -- TS: swaying here already (both sides' bodies hit at once) is left alone
    local now = os.clock()
    TOUR.quiet[t[2]] = now
    local ok = pcall(function()
        local b = a.Body
        local w = b:GetPhysicsAngularVelocityInDegrees(FName("None"))
        if w.X * w.X + w.Y * w.Y + w.Z * w.Z > TOUR_SPIN ^ 2 then count(tag .. "TS_already") return end
        a.PreventExplodeOnAngle = true
        TOUR.fuse[a] = now + TOUR_FUSE_S
        local m = b:GetMass()
        b:AddImpulseAtLocation({ X = tonumber(t[3]) * m, Y = tonumber(t[4]) * m, Z = tonumber(t[5]) * m }, a.TipScene:K2_GetComponentLocation(), FName("None"))
        count(tag .. "TS")
    end)
    if not ok then count(tag .. "TS_failed") end
end

local partCount = {} -- key -> { loot = applied T| string, n = its part count }
local listEntry, respawns = {}, {} -- host list row by key (client), hazard respawns by key
local respawnQueue = {} -- hazards to put back once they stayed gone RESPAWN_DELAY_S on the same map
local RESPAWN_DELAY_S = 3
local function respawnDue(startWorld)
    if #respawnQueue == 0 or os.clock() - respawnQueue[1].t < RESPAWN_DELAY_S then return end
    -- the map changed, or hazards die by the dozen (the zone being torn down, not mines going off)
    if Sync.worldName() ~= startWorld or #respawnQueue > 20 then respawnQueue = {} return end
    local q = table.remove(respawnQueue, 1)
    local hp = hostPos[q.key]
    local b = Sync.spawnEntry({ cls = q.e.cls, loc = hp and hp.loc or q.e.loc, rot = hp and hp.rot or q.e.rot, scale = q.e.scale, loot = "" })
    if b then
        CoopSyncMap[q.key] = Sync.ref(b)
        reverse[Sync.ref(b)] = q.key
        count("hazard_respawned")
    end
end

-- Look at one mapped actor: was it changed locally (opened, taken from, picked up, part removed)?
-- Positions belong to the host: copies that drifted on their own are pulled back.
local function detectOne(key, live)
    local path = CoopSyncMap[key]
    if not path then return end
    local a = Sync.deref(path)
    if a and Sync.inPool(a) then a = nil end -- returned to its pool = gone from the world
    local applied = state.applied[key]
    if not applied then return end
    -- (a live mark while the host has not answered the last change: looked at again with the next pass)
    if state.pending[key] then if live then SUB.recheck[key] = true end return end
    if not a then
        if applied:sub(1, 2) == "W|" then
            pickArch[key] = applied:match("^W|([^{]*)")
            pickSent[key] = true
            request(key, "PICK\t" .. key)
        end
        CoopSyncMap[key] = nil
        if HZ.mine[key] then HZ.died(key) return end -- (one this side ran: gone for the host too, not put back)
        -- a hazard that went off here on its own (imported landmines did, the host's stayed): the host is
        -- the authority, put it back where the host has it (a few times at most)
        -- Deferred: while the game travels away the whole zone dies, and spawning into it then hung the client.
        local e = listEntry[key]
        if e and e.cls:find("/BP_Hazard_", 1, true) and not exploding[key] and (respawns[key] or 0) < 3 then
            respawns[key] = (respawns[key] or 0) + 1
            respawnQueue[#respawnQueue + 1] = { key = key, e = e, t = os.clock() }
        end
        return
    end
    local hp = hostPos[key]
    if hp and not HZ.mine[key] then
        local l = a:K2_GetActorLocation()
        local drift = (l.X - hp.loc.X) ^ 2 + (l.Y - hp.loc.Y) ^ 2 + (l.Z - hp.loc.Z) ^ 2 > SNAP_BACK ^ 2
        if drift and HZ.claim(key, a, l, listEntry[key]) then
            count("hz_claim_running") -- (a hazard going after this player: it runs here while the host decides)
        elseif drift then
            puppet(a)
            pcall(function() a:K2_SetActorLocationAndRotation(hp.loc, hp.rot, false, {}, true) end)
            count("snap_back")
        end
    end
    -- car wrecks: serializing every part (3-10 ms each, measured) only to find nothing changed was most of
    -- the client's detection cost; a part taken off lowers the part count, so compare counts first
    if applied:sub(1, 2) == "T|" then
        local memo = partCount[key]
        if not memo or memo.loot ~= applied then
            local n = 0
            for _ in pairs(sockets(applied)) do n = n + 1 end
            local _, st = Loot.splitStates(applied)
            memo = { loot = applied, n = n, states = next(st) and st or nil }
            partCount[key] = memo
        end
        -- the wreck's trunk opened / pried here (its TrunkState: lootsync "#S"): to the host
        if memo.states then
            for socket, s in pairs(Loot.statesOf(a)) do
                if memo.states[socket] and s > memo.states[socket] then -- (opened only: a shut is the host's re-apply)
                    request(key, string.format("TRUNK\t%s\t%s\t%d", key, socket, s))
                    return
                end
            end
        end
        -- (a live mark - the slot hooks saw its trunk change - looks at the parts' contents too)
        if not (live or SUB.recheck[key]) and Loot.templatePartCount(a) >= memo.n then return end
        SUB.recheck[key] = nil
    end
    local cur = Loot.serialize(a) or ""
    if cur == applied then return end
    if cur == "R|1" then
        -- a resource (an anchor) grabbed here: taken on the host too
        if applied == "R|0" then request(key, "GRAB\t" .. key) end
        return
    end
    if cur:sub(1, 2) == "C|" then
        if cur:sub(-2) == "#O" and applied:sub(-2) ~= "#O" then
            request(key, "OPEN\t" .. key) -- the host's roll replaces whatever we rolled
        else
            local have, had = itemBag(cur), itemBag(applied)
            for arch, n in pairs(had) do
                local missing = n - (have[arch] or 0)
                if missing > 0 then request(key, string.format("TAKE\t%s\t%s\t%d", key, arch, missing)) end
            end
            for _, p in ipairs(putsOf(cur, applied)) do request(key, string.format("PUT\t%s\t%s\t%d\t\t%s", key, p[1], p[2], p[3])) end
        end
    elseif cur:sub(1, 2) == "T|" then
        local have = sockets(cur)
        for socket, was in pairs(sockets(applied)) do
            local now = have[socket]
            if not now then
                detachArch[key .. "\t" .. socket] = was:match("^[^@]*@([^@{]*)")
                request(key, "DETACH\t" .. key .. "\t" .. socket)
            elseif now ~= was and now:gsub("%b{}", "") == was:gsub("%b{}", "") then
                -- the same part, its trunk's contents changed: takes / puts there ("<socket>#<n>": its n-th container)
                local nc, oc = Loot.partSubs(now), Loot.partSubs(was)
                for i = 1, math.max(#nc, #oc) do
                    local c, o = "C|" .. (nc[i] or "!"), "C|" .. (oc[i] or "!")
                    if c ~= o then
                        local sub = socket .. "#" .. i
                        local h, hd = itemBag(c), itemBag(o)
                        for arch, n in pairs(hd) do
                            local missing = n - (h[arch] or 0)
                            if missing > 0 then request(key, string.format("TAKE\t%s\t%s\t%d\t%s", key, arch, missing, sub)) end
                        end
                        for _, p in ipairs(putsOf(c, o)) do request(key, string.format("PUT\t%s\t%s\t%d\t%s\t%s", key, p[1], p[2], sub, p[3])) end
                    end
                end
            end
        end
    end
end

-- Detection pass over all mapped actors, spread over frames (at most one pass per TICK_MS).
local dpass
local lastDetectStart = -1e9

-- Dropped items: the player's inventory lost items of an archetype and an unmapped world item of that
-- archetype lies near the player -> it was dropped (or thrown) here; ask the host to put it into the world
-- (it comes back as S and is adopted). Requiring the inventory loss keeps items the local game spawned on
-- its own (broken crates etc.; the host spawns its own and sends S) from being duplicated.
-- The car's equipment and storages count too: a part knocked off the own car (a crash) lies on the ground near the car -
-- it stayed on this side only, the host never saw it (soak test 2026-10-28: a door off the guest's car).
local DROP_RADIUS = 800
local invPrev
local dropAsked = {} -- local actor path -> true
-- (lost kinds and the places the player / cars were kept DROP_KEEP_S: the dropped item may come a pass later, and
-- from a moving car it lies far behind by then - soak test 2026-10-28: items taken out in a driving car)
-- A part knocked off the car first hangs on it and falls later: those kinds are kept CAR_KEEP_S (soak seed 7: of
-- three doors off the guest's car one lay on its side only). Only car parts: a resource the game spawns on its own
-- near the player (a broken crate) would be taken for a drop of the same kind lost a while ago.
local dropMem = { lost = {}, near = {}, KEEP_S = 10, CAR_KEEP_S = 30 } -- lost: kind -> { n, until }; near: { loc, until }
local function detectDrops()
    local cur = invCounts()
    local carKinds = {}
    pcall(function()
        local c = FindFirstOf("BP_InventoryManager_C").Inventory_CarEquipped
        for i = 1, c.Slots:GetArrayNum() do
            local s = c.Slots[i]
            for j = 1, s.Items:GetArrayNum() do
                local p = objPath(s.Items[j].Archetype)
                cur[p] = (cur[p] or 0) + 1
                carKinds[p] = true
            end
        end
    end)
    -- the car's storages too (their asset paths in the storage line): an item dropped from the trunk screen, or
    -- one taken out with no room in the backpack, lay on this side only (soak test 2026-10-28: scrap steel)
    pcall(function()
        local P = rawget(_G, "CoopPlayers")
        local line = P and P.twinModule and P.twinModule().Store.ownLine()
        for p in (line or ""):gmatch("/Game/[%w_/%.]+") do cur[p] = (cur[p] or 0) + 1 end
    end)
    local before, carBefore = invPrev, dropMem.carKinds or {}
    invPrev = cur
    dropMem.carKinds = carKinds
    if not before then return end
    local t = os.clock()
    local lost, any = dropMem.lost, false
    for p, e in pairs(lost) do
        if e.n <= 0 then lost[p] = nil
        elseif t > e.untilT then lost[p] = nil count("drop_unmatched") end
    end
    for p, n in pairs(before) do
        local d = n - (cur[p] or 0)
        if d > 0 then
            local keep = carBefore[p] and dropMem.CAR_KEEP_S or dropMem.KEEP_S
            lost[p] = { n = (lost[p] and lost[p].n or 0) + d, untilT = t + keep }
        end
    end
    any = next(lost) ~= nil
    local pc = FindFirstOf("PlayerController")
    local pawn = pc and pc.Pawn
    if not (pawn and pawn:IsValid()) then return end
    local near = {}
    for _, e in ipairs(dropMem.near) do if t <= e.untilT then near[#near + 1] = e end end
    near[#near + 1] = { loc = pawn:K2_GetActorLocation(), untilT = t + dropMem.KEEP_S }
    for _, car in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
        if car:IsValid() then near[#near + 1] = { loc = car:K2_GetActorLocation(), untilT = t + dropMem.KEEP_S } end
    end
    -- (a place kept per 200 units: a long drive keeps a trail, not every pass's point)
    local kept = {}
    for _, e in ipairs(near) do
        local dup = false
        for _, k in ipairs(kept) do
            if (e.loc.X - k.loc.X) ^ 2 + (e.loc.Y - k.loc.Y) ^ 2 < 200 ^ 2 then dup = true k.untilT = math.max(k.untilT, e.untilT) break end
        end
        if not dup then kept[#kept + 1] = e end
    end
    dropMem.near = kept
    if not any then return end
    Loot.beginPass()
    for _, a in ipairs(Sync.collect()) do
        local ap = Sync.ref(a)
        if not reverse[ap] and not dropAsked[ap] and Loot.isItemActor(a) then
            local loot = Loot.serialize(a) or ""
            local arch = loot:match("^W|([^{]*)")
            if arch and lost[arch] and lost[arch].n > 0 then
                local l = a:K2_GetActorLocation()
                local close = false
                for _, e in ipairs(kept) do
                    local pl = e.loc
                    if (l.X - pl.X) ^ 2 + (l.Y - pl.Y) ^ 2 + (l.Z - pl.Z) ^ 2 < DROP_RADIUS ^ 2 then close = true break end
                end
                if close then
                    local r = a:K2_GetActorRotation()
                    local okF, fv = pcall(CoopSyncFuel.of, a)
                    send("client.requests", string.format("DROP\t%s\t%.2f\t%.2f\t%.2f\t%.3f\t%.3f\t%.3f\t%s", loot, l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll, okF and tostring(fv) or ""))
                    count("rq_DROP")
                    dropAsked[ap] = true
                    lost[arch].n = lost[arch].n - 1
                end
            end
        end
    end
    Loot.endPass()
end

-- The host's events wait in evQueue and are applied EVENTS_MS per frame: the backlog at the sync's start (a second
-- visit to a zone: 20 s of the host's events) took one frame of 3-5 s. While some wait, nothing local is detected
-- (an event not applied yet would look like the player's own change).
local EVENTS_MS = 6
local evQueue, evHead = {}, 1
local function clientFrame(deadline)
    local t0 = pstart()
    local got = receive("host.events")
    for _, line in ipairs(got) do evQueue[#evQueue + 1] = line end
    if #got > 200 and CoopSyncHitch then CoopSyncHitch.note("host events: " .. #got .. " at once, " .. (#evQueue - evHead + 1) .. " waiting") end
    local evEnd = os.clock() + EVENTS_MS / 1000
    while evHead <= #evQueue do
        local line = evQueue[evHead]
        evQueue[evHead] = nil
        evHead = evHead + 1
        local ok, e = pcall(clientApply, split(line))
        if not ok then err("apply " .. line:sub(1, 80) .. ": " .. tostring(e)) end
        if os.clock() > evEnd then break end
    end
    local waiting = evHead <= #evQueue
    if not waiting then evQueue, evHead = {}, 1 end
    pend("client_events", t0)
    if waiting then state.eventsWaiting = #evQueue - evHead + 1 return end
    state.eventsWaiting = 0
    -- the containers the slot hooks marked: looked at now (TAKE / PUT), not with the next detection pass
    if LH.inv then
        LH.inv = false
        lastDetectStart = -1e9 -- (a pick-up / drop: a detection pass now)
        -- a picked world item: its PICK at once, not when the pass reaches it (15 fps: a pass took ~2.5 s, the
        -- host saw the pick-up after 4.4 s); only the gone ones (cheap: no serializing)
        for key, applied in pairs(state.applied) do
            if applied:sub(1, 2) == "W|" and CoopSyncMap[key] and not state.pending[key] then
                local a = Sync.deref(CoopSyncMap[key])
                if not a or Sync.inPool(a) then
                    local ok, e = pcall(detectOne, key, true)
                    if ok then count("live_pick") else err("live pick: " .. tostring(e)) end
                end
            end
        end
    end
    if next(LH.dirty) then
        t0 = pstart()
        if not dpass then Loot.beginPass() end
        for p in pairs(LH.dirty) do
            LH.dirty[p] = nil
            local key = reverse[p] or subOwner(p, state.applied, resolve)
            if key then
                local ok, e = pcall(detectOne, key, true)
                if ok then count("live_detect") else err("live detect: " .. tostring(e)) end
            end
            if os.clock() > deadline then break end
        end
        if not dpass then Loot.endPass() end
        pend("client_live", t0)
    end
    if not dpass then
        if os.clock() * 1000 - lastDetectStart < TICK_MS then return end
        lastDetectStart = os.clock() * 1000
        local keys = {}
        for k in pairs(CoopSyncMap) do keys[#keys + 1] = k end
        Loot.beginPass()
        dpass = { keys = keys, i = 1 }
    end
    t0 = pstart()
    while dpass.i <= #dpass.keys and os.clock() <= deadline do
        local key = dpass.keys[dpass.i]
        dpass.i = dpass.i + 1
        local td = os.clock()
        detectOne(key)
        td = (os.clock() - td) * 1000
        if td > 3 then count("slow_detect_" .. ((state.applied[key] or ""):sub(1, 1) ~= "" and state.applied[key]:sub(1, 1) or "none")) state.slowDetectMax = math.max(state.slowDetectMax or 0, td) end
    end
    pend("client_detect_step", t0)
    if dpass.i > #dpass.keys then
        Loot.endPass()
        dpass = nil
        count("passes")
        local okD, eD = pcall(detectDrops)
        if not okD then err("drops: " .. tostring(eD)) end
        -- revert predictions the host did not confirm
        local t = now()
        for key, since in pairs(state.pending) do
            if t - since > REVERT_SEC then
                state.pending[key] = nil
                local a = resolve(key)
                if a and state.applied[key] then applyLoot(a, state.applied[key]) count("reverted") end
            end
        end
    end
end
---------------------------------------------------------------------------------------------------

-- role: "host" | "client". The client must have run import() before (CoopSyncMap) and passes the
-- host spawn list path so it knows the host state it starts from.
function M.start(syncModule, r, channelDir, hostListPath)
    CoopSyncPaint.startAt, CoopSyncPaint.sentAt, CoopSyncPaint.applied, CoopSyncPaint.list = nil, -1e9, {}, nil
    CoopSyncEvent.sentAt, CoopSyncEvent.map, CoopSyncEvent.done, CoopSyncEvent.ended = -1e9, {}, {}, {}
    Sync, Loot, role, chan = syncModule, syncModule.Loot, r, channelDir
    DOORS.last, DOORS.applied, DOORS.quiet, DOORS.cache, DOORS.sentAll, DOORS.scanAt = {}, {}, {}, nil, -1e9, -1e9
    KNOCK.done, KNOCK.pending, KNOCK.queue = {}, {}, {}
    FUEL.last, FUEL.list, FUEL.at, FUEL.listAt, FUEL.sentAll, FUEL.pend = {}, {}, -1e9, -1e9, -1e9, {}
    RANGE.list, RANGE.stopped, RANGE.inside, RANGE.at, RANGE.scanAt, RANGE.sentAll = {}, {}, {}, -1e9, -1e9, -1e9
    TOUR.list, TOUR.near, TOUR.posed, TOUR.quiet, TOUR.fuse = {}, {}, {}, {}, {}
    TOUR.at, TOUR.listAt, TOUR.nearAt = -1e9, -1e9, -1e9
    if role == "host" then
        io.open(chan .. "/host.events", "wb"):close()
        io.open(chan .. "/client.requests", "wb"):close()
        Link.drain("client.requests")
        -- baseline = the spawn list the client imported (hostListPath: the host's own export), so the first
        -- pass sends what changed since the export (a minefield that came alive later) instead of
        -- silently taking the current zone as what the client already has
        prev = nil
        if hostListPath then
            prev = {}
            for _, e in ipairs(Sync.readList(hostListPath)) do
                if e.kind ~= "D" and e.kind ~= "F" and e.kind ~= "P" then prev[e.key] = e.loot end
            end
        end
    else
        listEntry, respawns, respawnQueue = {}, {}, {}
        evQueue, evHead = {}, 1
        local t0 = os.clock()
        local rows = Sync.readList(hostListPath)
        hop("state start read", t0)
        t0 = os.clock()
        for _, e in ipairs(rows) do
            listEntry[e.key] = e
            if CoopSyncMap[e.key] then
                state.applied[e.key] = e.loot
                reverse[CoopSyncMap[e.key]] = e.key
                hostPos[e.key] = { loc = e.loc, rot = e.rot }
            end
        end
        hop("state start map", t0)
    end
    -- Runs on the game thread (no LoopAsync: its callback shares this lua_State from another thread,
    -- which corrupted the Lua registry and crashed UE4SS under load).
    -- Every frame, with a small time budget: the work of one pass is spread over several frames.
    -- The session belongs to this map: once the game travels elsewhere (home, death) stop for good —
    -- a client in its garage would otherwise see every mapped actor "gone" and ask the host to pick them up.
    local startWorld = Sync.worldName()
    local startAddr = Sync.worldAddr()
    M.stopped = false
    exploding, remoteBoom = {}, {}
    CoopSyncStray.at, CoopSyncStray.seen = -1e9, {}
    for _, k in ipairs({ "guest", "mine", "asked", "claimAt", "target", "hot", "isHz", "sent" }) do HZ[k] = {} end
    local tH = os.clock()
    local okH, eH = pcall(hookHazards)
    hop("state start hooks", tH)
    if not okH then err("hazard hooks: " .. tostring(eH)) end
    LH.dirty, LH.inv, LH.on = {}, false, true
    local okG, eG = pcall(hookGobbler)
    local okX, eX = pcall(hookExit)
    local okSt, eSt = pcall(STORM.hook)
    if not okSt then err("storm hooks: " .. tostring(eSt)) end
    STORM.at, STORM.sent, STORM.done, STORM.have = nil, 0, 0, 0
    local W = CoopSyncWreck
    local okW, eW = pcall(W.hook)
    if not okW then err("wreck part hook: " .. tostring(eW)) end
    -- (the host's first full list 3 s in: the guest imported the host's parts before this start, with its own health)
    W.dirty, W.mine, W.last, W.index, W.allAt, W.sent, W.applied = {}, {}, {}, nil, os.clock() - W.ALL_S + 3, 0, 0
    W.sweepAt, W.breakable, W.missed, W.missedAt, W.lateApplied = -1e9, 0, {}, nil, 0
    local okK, eK = pcall(hookKnocks)
    if not okK then err("knock hooks: " .. tostring(eK)) end
    if not okX then err("exit hook: " .. tostring(eX)) end
    if not okG then err("gobbler hook: " .. tostring(eG)) end
    local okC, eC = pcall(hookContainers)
    if not okC then err("container hooks: " .. tostring(eC)) end
    loop(1, function()
        if M.stopped then return true end
        state.ticks = (state.ticks or 0) + 1
        -- (every frame: Sync.worldAddr)
        if Sync.worldAddr() ~= startAddr then
            LH.on = false
            M.stopped = true
            count("stopped_world_changed")
            return true
        end
        local t0 = os.clock()
        local deadline = t0 + (role == "host" and FRAME_BUDGET_MS or CLIENT_BUDGET_MS) / 1000
        local ok, e = pcall(role == "host" and hostFrame or clientFrame, deadline)
        if role ~= "host" then pcall(respawnDue, startWorld) end
        if not ok then err("tick: " .. tostring(e)) end
        local okD, eD = pcall(DOORS.tick)
        local okP, eP = pcall(CoopSyncPaint.tick)
        if not okP then err("paint: " .. tostring(eP)) end
        local okG, eG = pcall(CoopSyncEvent.tick)
        if not okG then err("events: " .. tostring(eG)) end
        local okK, eK = pcall(KNOCK.tick)
        local okS, eS = pcall(STRAY.tick)
        if not okS then err("stray: " .. tostring(eS)) end
        local okF, eF = pcall(FUEL.tick)
        local okSt, eSt = pcall(STORM.tick)
        if not okSt then err("storm: " .. tostring(eSt)) end
        local okWp, eWp = pcall(CoopSyncWreck.tick)
        if not okWp then err("wreck parts: " .. tostring(eWp)) end
        local okR, eR = pcall(RANGE.tick)
        if not okR then err("range: " .. tostring(eR)) end
        local okT, eT = pcall(TOUR.tick)
        if not okT then err("tourists: " .. tostring(eT)) end
        if not okF then err("fuel: " .. tostring(eF)) end
        if not okK then err("knocks: " .. tostring(eK)) end
        if not okD then err("doors: " .. tostring(eD)) end
        local okZ, eZ = pcall(HZ.frame)
        if not okZ then err("hazards: " .. tostring(eZ)) end
        state.lastMs = math.floor((os.clock() - t0) * 1000)
        state.maxMs = math.max(state.maxMs or 0, state.lastMs)
    end)
    return role .. " sync started"
end

function M.profile()
    local t = {}
    for k, p in pairs(prof) do t[#t + 1] = string.format("%s=%.1f/max%.0fms", k, p.ms / math.max(p.n, 1), p.mx) end
    table.sort(t)
    return table.concat(t, " ")
end
function M.resetProfile() prof = {} end
-- (tests) one hazard's run state on this side
function M.hzInfo(key)
    return string.format("mine=%s asked=%s guest=%s target=%s respawns=%d exploding=%s", tostring(HZ.mine[key] or false),
        tostring(HZ.asked[key] ~= nil), tostring(HZ.guest[key] or false), tostring(HZ.target[key] ~= nil),
        respawns[key] or 0, tostring(exploding[key] or false))
end

function M.report()
    local t = {}
    for k, v in pairs(state.stats) do t[#t + 1] = k .. "=" .. v end
    table.sort(t)
    local p = 0
    for _ in pairs(state.pending) do p = p + 1 end
    return table.concat(t, " ") .. " pending=" .. p .. string.format(" ticks=%s tick_ms=%s max_ms=%s", tostring(state.ticks), tostring(state.lastMs), tostring(state.maxMs)) .. (#state.errors > 0 and (" ERRORS: " .. table.concat(state.errors, " || ")) or "")
end

return M









