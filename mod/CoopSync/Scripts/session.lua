-- Session automation: what the test scripts did by hand, done by the mod itself in a real game.
-- The in-game network (link.lua -> CoopNative's net.cpp) gives the session its commands; a test writes them into
-- <chan>/control.txt instead (CoopNet.exe did too). The mod writes <chan>/status.txt.
-- The channel directory: $COOPSYNC_CHAN, else <Saved>/CoopSync (per profile). The network moves the lines
-- (host.events, host.fast, client.*: in memory, or files for CoopNet.exe / the tests' relays) and outbox -> peer's
-- inbox between the players.
--   session commands:  role host | role client     mode foot | mode car     go     stop
--   status.txt (rewritten every tick): role=.. mode=.. state=.. world=.. gstate=.. seq=.. note=..
-- Host: on arriving in a zone it publishes the run descriptor, the gates and a session line with list=- (the guest
--   travels and generates its own zone meanwhile); once the generator is done (CoopSync.zoneReady for a few seconds), it exports the zone
--   (outbox/host-spawnlist-<seq>.tsv), publishes the run descriptor (outbox/host-run.txt) and the session line
--   (outbox/host-session.txt: seq, world, list) and starts the state + player sync. Every new zone (next leg)
--   gets a new seq. Its travels end the zone's sync by themselves (playersync / statesync stop on travel).
-- Guest: on "go" (the network: the host left its garage for a run, or this member of that run came back) - as soon as
--   the host hosts, Run.join (the game's travel to the host's map; with its own car or on foot, the role); a guest
--   in another zone is moved to the host's map the same way. Start flow (owner, 2026-10-24): the lobby gathers in
--   the garage (each its own; they see each other: playersync garage mode), only the host picks the destination
--   (guests' map clicks blocked), the host's departure starts the run for the lobby (network "start"), back home
--   "runend"; the main menu or loading a save leaves the lobby.
--   In the host's zone: once its zone is ready and the host's list for that world is in, import, cleanup 10 s
--   later, then state + player sync (own-car mode for "car"). A next leg: playersync follows the host (foot) or
--   splits (car); the new zone is imported the same way.
local M = {}
-- the texts in the game's language (loc.lua)
local L = (CoopSyncLoc or dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "loc.lua")).L
-- the game's functions hooked only once they exist (hooks.lua)
local Hook = CoopSyncHook or dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "hooks.lua").hook
local After = CoopSyncAfter or dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "hooks.lua").after -- (never ExecuteWithDelay: hooks.lua)
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

local function loop(ms, fn)
    local h
    h = LoopInGameThreadWithDelay(ms, function()
        -- (an error escaping here made UE4SS drop the loop for good: the co-op menu item never came back, alpha 9)
        local t0 = os.clock()
        local ok, r = pcall(fn)
        if CoopSyncHitch then CoopSyncHitch.spent(os.clock() - t0, "session") end
        if not ok then
            if CoopSyncHitch then CoopSyncHitch.note("loop error: " .. tostring(r):sub(1, 200)) end
            return
        end
        if r == true and h then CancelDelayedAction(h) end
    end)
    return h
end

local TICK_MS = 500
local READY_TICKS = 2        -- zoneReady for 1 s in a row (6 before)
local JOIN_RETRY_S = 30      -- a guest still in its garage this long after joining joins again
-- and at least this long after arriving: 25 s before ("the generator's first waves"); the timeline (2026-11-09) had the
-- host's zone ready 0.0 s after arriving in both zones of nextzone-test - 27 s of the guest's wait for nothing
local MIN_ZONE_S = 0
local LOAD_SLICE_MS = 40     -- the jobs' ms per frame under the guest's loading screen (6 while playing)
local CLEANUP_AFTER_S = 3    -- import -> cleanup (the imported actors' own spawns on their first frames; 10 s before)

local S = { role = nil, mode = "car", go = false, state = "idle", seq = 0, note = "" }
local chan, ctlOff = nil, 0
local Sync, Run, State, Players, Weather, Map
local TwinMod -- twincar.lua (session start)
local Hitch = require("hitch")
-- the host's zone through the game's own save (zonesave.lua); CoopSyncZoneSave = false: the old way (the guest keeps
-- the zone the game generated from the seed, the host's list imported over it)
local ZoneSave
local ZONE_SAVE_WAIT_S = 20
local function zoneSaveOn() return ZoneSave ~= nil and CoopSyncZoneSave ~= false and CoopNative_SaveSplice ~= nil end
-- one instance per Lua state (tests dofile the modules from another mod: require would not find it)
local Link = CoopSyncLink or dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "link.lua")

local function nowS() return os.clock() end
local function readFile(p)
    if p:sub(1, 4) == "doc:" then return Link.read(p) end
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("*a") f:close()
    return s
end
local function writeFile(p, s)
    if p:sub(1, 4) == "doc:" then return Link.write(p, s) end
    local f = io.open(p .. ".tmp", "wb")
    if not f then return false end
    f:write(s) f:close()
    os.remove(p)
    return os.rename(p .. ".tmp", p)
end
local function copyFile(from, to)
    local s = readFile(from)
    return s and writeFile(to, s)
end
local function kv(line)
    local t = {}
    for k, v in (line or ""):gmatch("(%w+)=(%S+)") do t[k] = v end
    return t
end

-- a command for the network (what the menu sends)
local function netCmd(s) Link.cmd(s) end
local function netHead() return kv(Link.status()[1]) end

-- a session command; fromNet: the in-game network gave it (the lines then go through it, see link.lua)
local function sessionCmd(cmd, arg, fromNet)
    if cmd == "role" and (arg == "host" or arg == "client") then S.role = arg S.state = "idle" Link.carries = fromNet
    elseif cmd == "mode" and (arg == "foot" or arg == "car") then S.mode = arg
    elseif cmd == "go" then S.go = true
    elseif cmd == "stop" then S.go = false S.role = nil S.state = "idle" end
end
local function readNet()
    for _, line in ipairs(Link.sessionLines()) do
        local cmd, arg = line:match("^(%S+)%s*(%S*)")
        if cmd then sessionCmd(cmd, arg, true) end
    end
end

local function readControl()
    local f = io.open(chan .. "/control.txt", "rb")
    if not f then return end
    local size = f:seek("end")
    if size < ctlOff then ctlOff = 0 end -- rewritten
    f:seek("set", ctlOff)
    local data = f:read("*a") or ""
    f:close()
    local last = data:match(".*\n()") -- consume complete lines only
    if not last then return end
    ctlOff = ctlOff + last - 1
    for line in data:sub(1, last - 1):gmatch("[^\r\n]+") do
        local cmd, arg = line:match("^(%S+)%s*(%S*)")
        -- the menu, for the automated test: "menu open" | "menu press <label start>" -> <chan>/menu-status.txt
        if cmd == "menu" and M.menu then
            local what, rest = line:match("^menu%s+(%S+)%s*(.-)%s*$")
            local ok, r = pcall(function()
                if what == "open" then M.menu.open() return "opening"
                elseif what == "press" then return M.menu.press(rest)
                else return M.menu.info() end
            end)
            writeFile(chan .. "/menu-status.txt", tostring(ok and r or ("ERR " .. tostring(r))) .. "\n" .. M.menu.info() .. "\n")
        -- the F7 panel, for the automated test: "panel open|close|info" | "panel press <label start>" -> panel-status.txt
        elseif cmd == "panel" and CoopSyncPanel then
            local what, rest = line:match("^panel%s+(%S+)%s*(.-)%s*$")
            local P = CoopSyncPanel
            local ok, r = pcall(function()
                if what == "open" then P.open() return "opening"
                elseif what == "close" then P.close() return "closed"
                elseif what == "press" then return P.press(rest)
                else return P.info() end
            end)
            writeFile(chan .. "/panel-status.txt", tostring(ok and r or ("ERR " .. tostring(r))) .. "\n" .. P.info() .. "\n")
        elseif cmd then sessionCmd(cmd, arg, false) end
    end
end

local function gameState()
    local gi = FindFirstOf("DrivingGameInstance")
    local ok, st = pcall(function() return gi.CurrentGameplayState end)
    return ok and tonumber(st) or -1
end

-- the zone save's state for tests (zonesave.lua): <state>/<saved>/<sent>/<loaded>
local function zoneSaveShort()
    if not ZoneSave then return "-" end
    return string.format("%s/%d/%d/%d", (ZoneSave.s.state:gsub("%s", "_")), ZoneSave.stats.saved, ZoneSave.stats.sent, ZoneSave.stats.loaded)
end
-- the other player's cars here (twincar.lua's CoopSyncTwins: address -> weak handle, or true without the native half):
-- tests compare it with the cars the level has (the cmds run in another Lua state: no access to the mod's globals)
local function twinCount()
    local n = 0
    for _, h in pairs(CoopSyncTwins or {}) do
        if h == true then n = n + 1
        elseif type(h) == "number" and CoopNative_Get then
            local ok, a = pcall(CoopNative_Get, h)
            if ok and a and a:IsValid() then n = n + 1 end
        end
    end
    return n
end
local function writeStatus(gstate, world)
    -- the other player as this side sees it (puppet=yes/no) once the player sync runs
    local puppet = "-"
    if S.state == "hosting" or S.state == "playing" or S.garageWorld then
        local ok, r = pcall(Players.report)
        puppet = ok and (tostring(r):match("puppet=(%S+)") or "?") or "?"
    end
    writeFile(chan .. "/status.txt", string.format("role=%s mode=%s state=%s world=%s gstate=%d seq=%d go=%s puppet=%s unpaused=%d weather=%s map=%d/%d/%d gate=%d/%d/%d hitch=%s anim=%s zs=%s twins=%d mapblock=%d cars=%s extra=%d chk=%d cover=%d/%d exitmap=%d/%d/%d travels=%d gmap=%s storm=%s copies=%d note=%s\n",
        tostring(S.role), S.mode, (S.state:gsub("%s", "_")), world, gstate, S.seq, tostring(S.go), puppet, M.pauseLifted, Weather and Weather.short() or "-", M.mapSent or 0, M.mapApplied or 0, M.mapRestores or 0, M.gateClosed or 0, M.gateOpened or 0, M.exitTaken or 0, Hitch.short(), (Players and Players.puppetAnim and Players.puppetAnim()) or "-", zoneSaveShort(), twinCount(), M.plannerUnbound or 0, M.carsSeen, M.extraCars or 0, CoopSyncChecklist and CoopSyncChecklist.rows or 0, M.covered or 0, S.coverShown and 1 or 0, M.mapClosed or 0, M.zoneExits or 0, M.follows or 0, (Run and Run.stats and Run.stats.travels) or 0, M.guestMap and string.format("%d/%d/%d/%d", M.guestMap.legs, M.guestMap.edges, M.guestMap.travel, M.guestMap.reveal) or "-", (CoopSyncStorm and string.format("%d/%d/%d/%d", CoopSyncStorm.sent or 0, CoopSyncStorm.done or 0, CoopSyncStorm.have or 0, CoopSyncStorm.held or 0) or "-"), M.copiesDropped or 0, ((S.note or ""):gsub("%s", "_"))))
end

-- zone ready = generator done for READY_TICKS ticks and MIN_ZONE_S after arriving
-- (a zone loaded from the host's save is whole at once: no generator waves to wait for)
local function zoneSettled()
    local ok, ready = pcall(Sync.zoneReady)
    S.readyTicks = (ok and ready) and (S.readyTicks or 0) + 1 or 0
    -- (the timeline: when the generator was first done here)
    if S.readyTicks == 1 then pcall(Hitch.note, string.format("timeline zone ready %.1f s after arriving", nowS() - (S.arrived or 0))) end
    -- a zone loaded from the host's save is whole: ready once is enough (owner, 2026-11-09: only real work)
    if S.fromSave then return S.readyTicks >= 1 end
    return S.readyTicks >= READY_TICKS and nowS() - (S.arrived or 0) >= (tonumber(os.getenv("COOPTEST_MIN_ZONE_S") or "") or MIN_ZONE_S)
end
local function worldAddr()
    local ok, a = pcall(function() local w = FindFirstOf("World") return w and w:IsValid() and w:GetAddress() end)
    return ok and a or nil
end

local function hostTick(gstate, world)
    if gstate ~= 5 then
        if gstate == 4 then S.state = "garage" end
        -- the zone is closed: a guest coming home must not join it again
        if S.zoneWorld and S.seq > 0 then writeFile(Link.docPath(chan, "outbox", "host-session.txt"), string.format("seq=%d world=- list=-\n", S.seq)) end
        if S.zoneWorld and gstate == 4 then netCmd("runend") end -- the run is over: no one joins it any more
        S.zoneWorld = nil
        return
    end
    if S.zoneWorld ~= world then
        S.zoneWorld, S.arrived, S.readyTicks, S.state = world, nowS(), 0, "zone: generating"
        -- the map and the gates at once, the list later (owner, alpha 16: the guest waited on the map screen until
        -- the host's zone had settled, then for its own): the guest travels and generates its zone meanwhile
        S.seq = S.seq + 1
        S.early = S.seq
        pcall(Run.publish, Link.docPath(chan, "outbox", "host-run.txt"))
        pcall(Run.publishGates, Link.docPath(chan, "outbox", "host-gates.txt"))
        writeFile(Link.docPath(chan, "outbox", "host-session.txt"), string.format("seq=%d world=%s list=-\n", S.seq, world))
    end
    if S.state == "hosting" then
        -- the gates change during the run (an exit opens later): send them again when they did (every 3 s)
        S.gateTicks = (S.gateTicks or 0) + 1
        if S.gateTicks % 6 == 0 then
            local okG, sig = pcall(Run.gateSig)
            if okG and sig ~= S.gateSig then S.gateSig = sig pcall(Run.publishGates, Link.docPath(chan, "outbox", "host-gates.txt")) end
        end
    end
    if S.state ~= "zone: generating" then return end
    if not zoneSettled() then return end
    -- a resync: the zone's earlier sync loops end first (they see the flag within a frame or two)
    if S.stoppedAt and nowS() - S.stoppedAt < 1.5 then return end
    if S.early ~= S.seq then S.seq = S.seq + 1 end -- (a resync: a new seq; the arrival's own seq otherwise)
    S.early = nil
    local list = string.format("host-spawnlist-%d.tsv", S.seq)
    S.zsave = nil
    if zoneSaveOn() then
        local doc = string.format("host-zonesave-%d", S.seq)
        local okZ, r = Hitch.timed("zone save", ZoneSave.hostSave, Link.docPath(chan, "outbox", doc))
        if okZ and tostring(r):find("^saving") then S.zsave = doc end
        S.zsaveNote = okZ and tostring(r) or ("zone save failed: " .. tostring(r))
    end
    local okE, n = Hitch.timed("export", Sync.export, chan .. "/" .. list) -- local copy: the statesync baseline
    if not okE then error(n) end
    copyFile(chan .. "/" .. list, Link.docPath(chan, "outbox", list))
    Run.publish(Link.docPath(chan, "outbox", "host-run.txt"))
    pcall(Run.publishGates, Link.docPath(chan, "outbox", "host-gates.txt"))
    S.gateSig = select(2, pcall(Run.gateSig))
    writeFile(Link.docPath(chan, "outbox", "host-session.txt"), string.format("seq=%d world=%s list=%s%s\n", S.seq, world, list, S.zsave and (" zsave=" .. S.zsave) or ""))
    State.start(Sync, "host", chan, chan .. "/" .. list)
    Players.start(Sync, "host", chan)
    Weather.start(Players, "host")
    S.state = "hosting"
    S.note = string.format("published %d actors; zone save: %s", n or 0, tostring(S.zsaveNote or (zoneSaveOn() and "?" or "off")))
end

local function clientTick(gstate, world)
    local session = kv(readFile(Link.docPath(chan, "inbox", "host-session.txt")))
    S.lastSession = session
    if gstate == 4 then
        -- home again: its own sky (not in the lobby: there the garage follows the host's sky, lobbyTick)
        if S.zoneWorld and not S.garageWorld then Weather.release() end
        -- a new trip to the same zone (late join of a run member) imports the host's list again
        -- (and loads the host's zone save again: its own game generated the zone anew - startflow's late join)
        S.zoneWorld, S.importedSeq, S.zoneLoadedSeq, S.zoneWaitSince, S.fromSave = nil, nil, nil, nil, nil
        -- "go" is used once: back home after a run the guest waits for a new "go". The garage's exit gate
        -- (owner, 2026-10-24) stays closed until "go" (gateTick); the guest drives out through it and the drive-
        -- through (onGuestExit) takes it to the host's map - no junction picking, as soon as the host's zone is up
        if not (S.go or S.joinPending) then
            if S.state ~= "joining" then S.state = "garage" return end
            -- the game did not travel (a late join at 15 fps stayed in the garage for 8 min): join again
            if nowS() - (S.joinAt or nowS()) > JOIN_RETRY_S and (S.joinTries or 0) < 3 then
                S.joinTries, S.joinAt = (S.joinTries or 0) + 1, nowS()
                local ok, r = pcall(Run.join, Link.docPath(chan, "inbox", "host-run.txt"))
                S.note = "join again (" .. S.joinTries .. "): " .. (ok and tostring(r) or ("failed: " .. tostring(r)))
                M.joinRetries = (M.joinRetries or 0) + 1
            end
            return
        end
        if not S.joinPending then S.state = "garage: the gate is open" return end
        if not session.seq or session.world == "-" then S.state = "garage: waiting for the host's zone" return end
        local function why(w) if S.garageWhy ~= w then S.garageWhy = w pcall(Hitch.note, "timeline drive-out waits: " .. w) end end
        -- the game's own exit fired: it travels by itself (left the garage within a moment: the step above the
        -- garage block) - no second travel (owner, alpha 19 item 6: both in one frame, "concurrent save/load on top
        -- of LOADING LEVEL", and the guest had its car twice, the controls jumping between them). Still here after
        -- 3 s: the exit only opened the map (a new game's) - our join then.
        -- (owner, 2026-11-09: events, not waits just in case - a fixed 3 s here before): the game's own travel is seen
        -- by the TravelTo hook in the frame of the exit; none seen = the exit only opened the map, our join at once
        if S.gameTravelAt and S.gameTravelSeen and S.gameTravelSeen > S.gameTravelAt - 1 and nowS() - S.gameTravelAt < 15 then why("the game's own travel") return end
        -- (the drive-through volume saw the car first: the game's own exit gets a moment to fire)
        if S.exitSeenAt and nowS() - S.exitSeenAt < 1.2 then why("the exit's own event") return end
        S.garageWhy = nil
        pcall(Hitch.note, "timeline drive-out: our join")
        S.gameTravelAt, S.exitSeenAt, S.gameTravelSeen = nil, nil, nil
        S.go, S.joinPending = false, false
        -- the game's own travel to the host's map with the own car
        local ok, r = pcall(Run.join, Link.docPath(chan, "inbox", "host-run.txt"))
        S.note = ok and tostring(r) or ("join failed: " .. tostring(r))
        S.state, S.joinAt, S.joinTries = "joining", nowS(), 0
        return
    end
    -- out of the garage by the game's own travel (its exit fired): that is the join; "go" stays for the step below
    if S.joinPending and S.gameTravelAt then
        S.joinPending, S.gameTravelAt, S.exitSeenAt = false, nil, nil
        S.state, S.joinAt, S.joinTries, S.note = "joining", nowS(), 0, "drove out: the game's own travel"
        M.gameTravels = (M.gameTravels or 0) + 1
    end
    if gstate ~= 5 then return end
    -- a member of the host's run in another zone (its own run, came back to the lobby; or the game's own travel
    -- went to another junction than the host's): to the host's map
    if S.go and session.seq and session.world ~= "-" and session.world ~= world then
        S.go = false
        local ok, r = pcall(Run.join, Link.docPath(chan, "inbox", "host-run.txt"))
        S.note = ok and ("to the host's map: " .. tostring(r)) or ("join failed: " .. tostring(r))
        S.state = "joining"
        return
    end
    if S.go and session.world == world then S.go = false end -- (arrived by the game's own travel)
    if gstate ~= 5 then return end
    -- the host left this zone (its next zone, home) while the guest stays: the sync stops here. Before, the guest's
    -- loops applied the host's next zone's lines in this world (nextzone-test, 2026-11-08: 528 events at once, the
    -- host's twin at the new zone's spot, a crash ~10 s later in ProcessEvent from a Lua loop). 2 ticks (1 s) of the
    -- other world first; the host's world here again (the same import) starts the sync again.
    local syncing = S.state == "playing" or S.state == "zone: at the exit"
    if syncing and not S.hostAway and session.world ~= world then
        S.awayTicks = (S.awayTicks or 0) + 1
        if S.awayTicks >= 2 then
            State.stopped = true
            pcall(Players.stop)
            S.hostAway, S.awayTicks = true, 0
            M.hostAwayStops = (M.hostAwayStops or 0) + 1
            S.note = "the host left this zone (" .. tostring(session.world) .. "): sync stopped"
        end
    elseif not S.hostAway then
        S.awayTicks = 0
    end
    if S.hostAway and S.zoneWorld ~= world then S.hostAway = nil end -- (a new world: the usual arrival)
    if S.hostAway and syncing and session.world == world and tonumber(session.seq) == S.importedSeq then
        S.hostAway = nil
        State.start(Sync, "client", chan, S.list)
        Players.start(Sync, "client", chan, { ownCar = S.mode == "car" })
        Weather.start(Players, "client")
        S.note = "the host is back in this zone: sync again"
    end
    -- at a zone's exit gate: after the host to its next zone (onGuestExit, zoneExitTick)
    M.zoneExitTick(world, session)
    if S.state == "zone: at the exit" then return end
    -- the host's zone through the game's own save (zonesave.lua): the game loads it into this world again; then the
    -- usual import (its list finds every actor in place). The load keeps the game state at 5 all along: the new
    -- World object tells it is done. (This step came after the arrival step below, which took the state back to
    -- "generating" at once: the guest then waited the generator's 25 s again in a zone that comes whole from the
    -- save - most of the guest's minute in the owner's alpha 19 test.)
    if S.state == "zone: loading the host's" then
        -- (the new World object is the event: no fixed 2 s first)
        if worldAddr() == S.loadWorld and nowS() - (S.zoneLoadAt or 0) < 120 then return end
        S.state, S.justLoaded, S.zoneWorld = "zone: generating", true, nil -- (the arrival step again: gates, clock)
        if ZoneSave.s.state == "guest loading" then ZoneSave.s.state = "guest loaded" end
    end
    if S.zoneWorld ~= world then
        S.zoneWorld, S.arrived, S.readyTicks, S.state, S.imported = world, nowS(), 0, "zone: generating", nil
        S.fromSave, S.justLoaded = S.justLoaded, nil -- (a new world of a later leg: generated again)
        -- the car next to the host's right on arrival: moving it km away makes the engine stream that area in (a
        -- 4-6 s frame); here it joins the arrival's own load instead of stalling the guest 25 s into the zone
        if session.world == world then
            local okG, g = Hitch.timed("gates on arrival", Run.applyGates, Link.docPath(chan, "inbox", "host-gates.txt"), FindFirstOf("BP_CarManager_C").NewCarActor)
            S.gatesNote = okG and tostring(g) or ("gates failed: " .. tostring(g))
        end
    end
    if zoneSaveOn() and session.zsave and session.world == world and S.zoneLoadedSeq ~= tonumber(session.seq)
        and (S.state == "zone: generating" or S.state == "zone: waiting for the host's list") then
        local okL, r, e = pcall(ZoneSave.guestLoad, Link.docPath(chan, "inbox", session.zsave), 500)
        if okL and r then
            S.zoneLoadedSeq = tonumber(session.seq)
            S.state, S.zoneLoadAt, S.zoneWorld, S.note = "zone: loading the host's", nowS(), nil, r
            S.loadWorld = worldAddr()
            return
        end
        S.note = "zone save: " .. tostring(okL and e or r)
        -- (the document comes after the session line that names it: waited for ZONE_SAVE_WAIT_S, then the old way -
        -- the generated zone, the host's list over it)
        S.zoneWaitSince = S.zoneWaitSince or nowS()
        if okL and e == "no host zone save yet" and nowS() - S.zoneWaitSince < ZONE_SAVE_WAIT_S then return end
        S.zoneLoadedSeq, S.zoneWaitSince = tonumber(session.seq), nil
    end
    if S.state == "zone: generating" then
        if not zoneSettled() then return end
        S.state = "zone: waiting for the host's list"
    end
    if S.state == "zone: waiting for the host's list" then
        if session.world ~= world or not session.list then S.note = "host is in " .. tostring(session.world) return end
        if session.list == "-" then S.note = "the host's zone is still generating" return end
        -- this list was already imported (the world name flickers while the game kills a left-behind guest)
        if tonumber(session.seq) == S.importedSeq then S.state = "playing" return end
        local list = Link.docPath(chan, "inbox", session.list)
        if not readFile(list) then return end
        -- the host's entrance / exits here too, and the guest's car next to the host's (before the import: the
        -- player sees the host's car while the zone fills in)
        local okG, g = Hitch.timed("gates", Run.applyGates, Link.docPath(chan, "inbox", "host-gates.txt"), FindFirstOf("BP_CarManager_C").NewCarActor)
        S.gatesNote = okG and tostring(g) or ("gates failed: " .. tostring(g))
        -- the import spread over frames (12 s in one frame in a big zone before)
        S.state = "zone: importing"
        local seq = tonumber(session.seq)
        Sync.importJob(list, function(ok, r)
            S.note = ok and tostring(r):sub(1, 120) or ("import failed: " .. tostring(r))
            S.imported, S.list, S.seq = nowS(), list, seq or S.seq
            S.importedSeq = seq
            S.state = ok and "zone: imported" or "zone: waiting for the host's list"
        end)
        return
    end
    if S.state == "zone: importing" or S.state == "zone: cleaning" then return end
    -- the host's gates held here (the game closes an exit its own route does not have): every 3 s
    if S.state == "playing" then
        S.gateTicks = (S.gateTicks or 0) + 1
        if S.gateTicks % 6 == 0 then pcall(Run.applyGates, Link.docPath(chan, "inbox", "host-gates.txt"), nil, true) end
    end
    -- the host published this zone again (its "resync" in the debug menu): import it once more
    if S.state == "playing" and session.world == world and tonumber(session.seq) and tonumber(session.seq) ~= S.importedSeq then
        State.stopped, Players.stopped, S.hostAway = true, true, nil
        S.state, S.note = "zone: waiting for the host's list", "host resent the zone"
        return
    end
    if S.state == "zone: imported" and nowS() - S.imported >= CLEANUP_AFTER_S then
        S.state = "zone: cleaning"
        Sync.cleanupJob(function(ok, r)
            S.note = ok and tostring(r):sub(1, 120) or ("cleanup failed: " .. tostring(r))
            if S.state ~= "zone: cleaning" then return end
            State.start(Sync, "client", chan, S.list)
            Players.start(Sync, "client", chan, { ownCar = S.mode == "car" })
            Weather.start(Players, "client")
            S.state = "playing"
            pcall(Run.applyGates, Link.docPath(chan, "inbox", "host-gates.txt"), nil, true) -- the game may have shut an exit since
            -- (the load's second copy of the own car, if it built one: gone before the screen lifts)
            pcall(function() local r = Players.twinModule().dropCopies() if r > 0 then M.copiesDropped = (M.copiesDropped or 0) + r end end)
        end)
    end
end

-- co-op pause (owner's rule): in a running session the pause menu does not stop the world - the other player
-- plays on; single-player pause is untouched. The game pauses through BP_UIManager.PauseGame; right after it, the
-- world is unpaused again while the session runs.
-- (the garage lobby too: owner, alpha 18 - a paused player's puppet slid about on the other side)
local function coopActive() return S.state == "hosting" or S.state == "playing" or S.garageWorld ~= nil end
M.coopActive = coopActive
M.pauseLifted = 0
local function hookPause()
    local ok, e = pcall(Hook, "/Game/Systems/Managers/BP_UIManager.BP_UIManager_C:PauseGame", function() end,
        function(self, instigator, paused)
            if not coopActive() then return end
            local p = false
            pcall(function() p = paused:get() end)
            if not p then return end
            local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            pcall(function() GS:SetGamePaused(self:get(), false) end)
            M.pauseLifted = M.pauseLifted + 1
        end)
    return ok and "pause hook" or ("pause hook failed: " .. tostring(e))
end
-- fallback while the session runs: a paused world (another pause path) is unpaused on the next tick
-- The session ending under an open pause menu (owner's alpha 21 test: after leaving the lobby the pause menu no longer
-- closed - neither Esc nor Continue; esc-test step 5): the menu was opened as a pause the mod lifted, and the game's Esc
-- / Continue close it only from a paused world. So the world is paused again then, as the menu expects.
local function pauseMenuOpen()
    for _, m in ipairs(FindAllOf("PDP_PauseMenu_C") or {}) do
        local ok, v = pcall(function() return m:IsValid() and m:GetFullName():find("/Engine/Transient", 1, true) and m:IsVisible() end)
        if ok and v then return true end
    end
end
local function keepRunning()
    local active = coopActive()
    if S.coopWas and not active then
        pcall(function()
            if pauseMenuOpen() then
                local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
                GS:SetGamePaused(FindFirstOf("PlayerController"), true)
                M.pauseRestored = (M.pauseRestored or 0) + 1
            end
        end)
    end
    S.coopWas = active
    if not active or S.coverPaused then return end
    local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local pc = FindFirstOf("PlayerController")
    pcall(function()
        if GS:IsGamePaused(pc) then GS:SetGamePaused(pc, false) M.pauseLifted = M.pauseLifted + 1 end
    end)
end

-- The lobby around the run (owner, 2026-10-24):
--   * the main menu: the lobby is left (the host's leave closes it for the member);
--   * in the garage both see each other (playersync garage mode: puppets only) while the other one is there,
--     and the guest's garage has the host's sky (weathersync over the garage channel: time of day, weather
--     preset and overrides, rain, wetness, wind, clouds - the light through the windows with them);
--   * the guest's map: its route nodes take no clicks (only the host picks; the guest may look) - post-hook on the
--     planner interaction's IsCursorOverInteraction, its IsOver out-param -> false (registered once the planner UI
--     class exists).
local PLANNER = "/Game/UI/RunUI/Planner/PlannerInteractionWidget/UMG_PlannerInteraction_Base.UMG_PlannerInteraction_Base_C"

-- The guest's garage exit (owner, 2026-10-24: "keep the gate closed until the host picks, as in single player;
-- take the friend over as soon as he drives out of the gate, no junction picking"). Probed (NOTES "The garage
-- exit"): the garage's BP_LevelTransition_EnterExit_C (IsGarageExit) ~230 m down the road: SetExit opens its
-- barrier (green), SetClosed shuts it; driving into it calls DoLevelTransition, which opens the map to pick a
-- junction; a pick is BaseRouteState:TravelTo.
local function garageExit()
    local p = S.exitPath and SFO(S.exitPath)
    if p and p:IsValid() then return p end
    for _, e in ipairs(FindAllOf("BP_LevelTransition_EnterExit_C") or {}) do
        local ok, g = pcall(function() return e:IsValid() and e.IsGarageExit end)
        if ok and g then S.exitPath = e:GetFullName():gsub("^%S+ ", "") return e end
    end
end
M.gateClosed, M.gateOpened, M.exitTaken = 0, 0, 0
M.garageExit = garageExit
-- the player menu (the map, at the map table or an exit) on screen
local function playerMenuOpen()
    for _, w in ipairs(FindAllOf("UMG_PlayerMenu_Main_C") or {}) do
        local ok, v = pcall(function() return w:IsInViewport() and w:IsVisible() end)
        if ok and v then return true end
    end
    return false
end
-- the car inside a level transition's exit volume (the garage exit's drive-through, a zone exit gate)
local function carInExit(ex, car)
    local inside = false
    pcall(function()
        car = car or FindFirstOf("BP_CarManager_C").NewCarActor
        local box = ex.Collision_Exit
        local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
        local l = KML:InverseTransformLocation(box:K2_GetComponentToWorld(), car:K2_GetActorLocation())
        local e = box:GetUnscaledBoxExtent()
        inside = math.abs(l.X) <= e.X and math.abs(l.Y) <= e.Y and math.abs(l.Z) <= e.Z
    end)
    return inside
end
-- the car in an exit volume of the zone's open exit gates
local function carInZoneExit()
    for _, e in ipairs(FindAllOf("BP_LevelTransition_EnterExit_C") or {}) do
        local okE, isExit = pcall(function() return e:IsValid() and e.ExitActive and not e.IsGarageExit end)
        if okE and isExit and carInExit(e) then return true end
    end
    return false
end
-- The map the game opens at an exit (the progression manager's "Open Map UI": the junction pick) is never the
-- guest's (owner's alpha 20 test: "do not show the guest the map at all, a loading screen instead"): the guest goes
-- where the host goes. Closed while the guest drives out of its garage, arrives in a zone, or waits at a zone exit
-- for the host's pick. (It opens a moment after the exit fired - the post-hook's close came too early: the map stayed
-- open through the load and was open again in the zone. The game does not open it again once closed - probed.) The
-- map table in the garage lobby stays the guest's to look at.
local function mapGuard()
    if S.role ~= "client" then return false end
    local g = gameState()
    if g == 4 then return S.go or S.joinPending or S.state == "joining" end
    if g == 5 then return S.state ~= "playing" or S.followPending == true end
    return false
end
M.mapClosed = 0
local function closeMap(why)
    if pcall(function() FindFirstOf("BP_ProgressionManager_C"):CloseMapUI() end) then
        M.mapClosed = M.mapClosed + 1
        S.mapClosedWhy = why
        pcall(Hitch.note, "timeline map closed (" .. tostring(why) .. ")")
    end
end
local function onGuestExit(fromGame)
    if S.role ~= "client" then return end
    local g = gameState()
    -- a zone's exit gate (owner's alpha 20 test: the guest picked a junction of its own and the two split): the guest
    -- waits there for the host's pick, the screen dark, and follows the host to its zone (zoneExitTick)
    if g == 5 then
        if not S.followPending and S.state == "playing" then
            S.followPending, S.followAt = true, nowS()
            -- (the host already gone on: its descriptor now is where to go - the guest left behind follows it)
            S.followFrom = S.hostAway and "" or (readFile(Link.docPath(chan, "inbox", "host-run.txt")) or ""):match("^[^\r\n]*")
            M.zoneExits = (M.zoneExits or 0) + 1
            S.state, S.note = "zone: at the exit", "at the zone's exit: waiting for the host's pick"
        end
        if S.state == "zone: at the exit" then M.raiseCover() end
        closeMap("zone exit")
        return
    end
    if g ~= 4 then return end
    -- the game's own exit is travelling (an advanced save's exit does: to the junction planned on the map, the
    -- host's - mapsync gave it the host's plan)
    if fromGame then S.gameTravelAt = nowS() end
    pcall(Hitch.note, "timeline garage exit (" .. (fromGame and "the exit's event" or "the car in its volume") .. ", go=" .. tostring(S.go) .. ")")
    -- the map the game opens for a pick: not for the guest, the host's map is where it goes
    closeMap("garage exit")
    if S.go or S.joinPending then
        S.joinPending = true
        M.raiseCover()
        M.exitTaken = M.exitTaken + 1
        S.note = "drove out: to the host's map"
    end
end
-- the exits' DoLevelTransition, hooked once for the class (every exit: the garage's and the zones')
local function hookExits()
    if S.exitHooked then return end
    local any = FindFirstOf("BP_LevelTransition_EnterExit_C")
    if not (any and any:IsValid()) then return end
    S.exitHooked = true
    local cls = any:GetClass():GetFullName():gsub("^%S+ ", "")
    pcall(Hook, cls .. ":DoLevelTransition", function() end, function() pcall(onGuestExit, true) end)
    local pm = FindFirstOf("BP_ProgressionManager_C")
    local pmCls = pm and pm:GetClass():GetFullName():gsub("^%S+ ", "")
    if pmCls and isFunction(pmCls .. ":Open Map UI") then
        pcall(Hook, pmCls .. ":Open Map UI", function() end, function()
            -- (a zone's exit gate opens the map without its DoLevelTransition on the guest - nextzone-test: the car in
            -- the gate, the map open, the hook silent): the map opening with the car in an exit gate is the exit
            if S.role == "client" and gameState() == 5 and S.state == "playing" and not S.followPending and carInZoneExit() then
                pcall(onGuestExit, true)
            end
            -- (the guest's garage exit opened the map: the game is not travelling by itself - our join at once, not
            -- after the 3 s that wait for the game's own travel)
            if S.role == "client" and gameState() == 4 and S.joinPending and S.gameTravelAt then
                S.gameTravelAt, S.exitSeenAt = nil, nil
                pcall(Hitch.note, "timeline the exit opened the map: our join")
            end
            if mapGuard() then
                if S.joinPending or S.state == "joining" or S.state == "zone: at the exit" then M.raiseCover() end
                closeMap("opened")
            end
        end)
    end
end
local function gateTick(gstate)
    if gstate == 4 or gstate == 5 then pcall(hookExits) end
    -- (a map that opened anyway: a hook missed, or the game's own way in)
    if S.role == "client" and gstate == 5 and S.state == "playing" and not S.followPending and playerMenuOpen() and carInZoneExit() then
        pcall(onGuestExit, true)
    end
    if mapGuard() and playerMenuOpen() then closeMap("tick") end
    if gstate ~= 4 or S.role ~= "client" then S.exitPath = nil return end
    local ex = garageExit()
    if not ex then return end
    local open = S.go or S.joinPending
    local active = false
    pcall(function() active = ex.ExitActive end)
    -- the car inside the exit's drive-through volume counts as driving out too: a new game's first garage (story)
    -- never called DoLevelTransition for an open exit (an advanced save did)
    if open and active and not S.joinPending and carInExit(ex) then
        S.exitSeenAt = nowS()
        onGuestExit(false)
    end
    if open and not active then
        if pcall(function() ex:SetExit(false) end) then M.gateOpened = M.gateOpened + 1 end
    elseif not open and active then
        if pcall(function() ex:SetClosed() end) then M.gateClosed = M.gateClosed + 1 end
    end
end
-- The guest at a zone's exit gate: when the host has picked and arrived (its new descriptor), the guest follows it
-- (Run.follow: the host's own junction). Driven out of the gate again before that: back to playing.
local FOLLOW_MAX_S = 300
local function zoneExitTick(world, session)
    if not S.followPending then return end
    local desc = (readFile(Link.docPath(chan, "inbox", "host-run.txt")) or ""):match("^[^\r\n]*")
    if desc and desc ~= "" and desc ~= S.followFrom and session.world and session.world ~= world and session.world ~= "-" then
        S.followPending = false
        local ok, r = pcall(Run.follow, desc)
        S.note = ok and tostring(r) or ("follow failed: " .. tostring(r))
        M.follows = (M.follows or 0) + 1
        S.state, S.joinAt = ok and "joining" or "playing", nowS()
        return
    end
    -- still in the exit? (the host may take its time at the map; the car left the gate = not leaving after all)
    local inside = carInZoneExit()
    if inside then S.followOutAt = nil else S.followOutAt = S.followOutAt or nowS() end
    if (S.followOutAt and nowS() - S.followOutAt > 4) or nowS() - (S.followAt or nowS()) > FOLLOW_MAX_S then
        local why = S.followOutAt and "car out of the gate" or "waited too long"
        S.followPending, S.followOutAt = false, nil
        if S.state == "zone: at the exit" then S.state = "playing" end
        S.note = "left the zone's exit: playing on"
        -- (into the report: a later note - the host gone on - hides this one in the status line)
        pcall(Hitch.note, "left the zone's exit (" .. why .. "): playing on")
    end
end
M.zoneExitTick = zoneExitTick
-- The garage map (mapsync.lua): the host's map, junctions and conditions on the guests' map tables.
--   * host in its garage with a peer: its route map -> outbox/host-map.tsv whenever it changed (forced at a new
--     garage visit: the guest may have joined since);
--   * guest in its garage in the lobby: inbox/host-map.tsv -> its route state when it changed (its own map to
--     <chan>/map-backup.tsv first); an open player menu is opened again (its map caches the junction icons);
--   * guest in its garage out of the lobby (left it, or a game start): its own map back from the backup; the backup
--     is dropped on its next own departure (that departure saves the restored map).
local MAP_EVERY = 4 -- lobby ticks (2 s)
local function mapTick(gstate, world, peer)
    S.mapTicks = (S.mapTicks or 0) + 1
    if not peer then S.mapPeer = false end
    if gstate ~= 4 then S.mapWorld, S.mapSig, S.departing = nil, nil, nil return end
    -- the guest's roads as the host's while its map is open (the widgets' cached answers, reset by the game on changes)
    if S.role == "client" and S.mapTicks % 2 == 0 and not S.mapRestored and Map.visible and playerMenuOpen() then
        local ok, n = pcall(Map.applyEdges)
        if ok and M.guestMap then M.guestMap.edges = M.guestMap.edges + n end
    end
    local backup = chan .. "/map-backup.tsv"
    -- the host's departure marks its first leg visited while still in the garage: such a map left the guest no
    -- leg to drive out to (startflow FAIL) -> no exports once the host departs, no applies while the guest goes
    if S.role == "host" and peer and not S.departing then
        local first = S.mapWorld ~= world or not S.mapPeer -- a new garage visit, or a (new) peer since
        S.mapPeer = true
        if S.mapTicks % MAP_EVERY ~= 0 and not first then return end
        S.mapWorld = world
        local t = os.clock()
        local ok, n = Hitch.timed("map export", Map.export, Link.docPath(chan, "outbox", "host-map.tsv"), first)
        if ok and n then M.mapSent = (M.mapSent or 0) + 1 S.note = string.format("map sent (%d rows, %.0f ms)", n, (os.clock() - t) * 1000)
        elseif not ok then S.note = "map export: " .. tostring(n) end
    elseif S.role == "client" then
        if S.mapTicks % MAP_EVERY ~= 0 or S.go or S.state == "joining" then return end
        local data = readFile(Link.docPath(chan, "inbox", "host-map.tsv"))
        if not data then return end
        local sig = #data .. ":" .. data:sub(1, 200) .. data:sub(-200)
        if sig == S.mapSig and S.mapWorld == world then return end
        local ok, r, e = Hitch.timed("map apply", Map.apply, Link.docPath(chan, "inbox", "host-map.tsv"), backup)
        S.mapSig, S.mapWorld, S.mapRestored = sig, world, false
        S.note = ok and tostring(r or e) or ("map apply: " .. tostring(r))
        if ok and r then
            M.mapApplied = (M.mapApplied or 0) + 1
            if playerMenuOpen() then
                local pm = FindFirstOf("BP_ProgressionManager_C")
                pcall(function() pm:CloseMapUI() end)
                After(300, function() pcall(function() local p = FindFirstOf("BP_ProgressionManager_C") p["Open Map UI"](p) end) end)
            end
        end
    elseif not S.role and not S.mapRestored and Map.hasBackup(backup) then
        local ok, r, e = pcall(Map.restore, backup)
        S.mapRestored, S.mapSig = true, nil
        S.note = ok and tostring(r or e) or ("map restore: " .. tostring(r))
        if ok and r then M.mapRestores = (M.mapRestores or 0) + 1 end
    end
end
M.mapTick = mapTick

-- The guest's map, look only (owner, alpha 18: both could still pick a junction, the guest's pick opened the gates):
-- the click went through the planner node's OnPlannerInteractionClicked delegate, not only the hover test above.
-- While a guest in the garage, its nodes' click bindings are taken off (kept by path) and put back afterwards.
-- (Hooks run after the function's body: a click cannot be stopped there - NOTES "UE4SS pre-hook = after body".)
local plannerParked = {} -- widget path -> { function names }
local function plannerClicks(block)
    S.plannerTicks = (S.plannerTicks or 0) + 1
    if block then
        if S.plannerTicks % 4 ~= 0 then return end -- (a search over every object: every 2 s, the map UI is rebuilt when opened)
        for _, w in ipairs(FindAllOf("UMG_PlannerInteraction_Base_C") or {}) do
            pcall(function()
                if not (w:IsValid() and w:GetFullName():find("/Engine/Transient", 1, true)) then return end
                local del = w.OnPlannerInteractionClicked
                for _, b in ipairs(del:GetBindings() or {}) do
                    local o, fn = b.Object, b.FunctionName:ToString()
                    if o and o:IsValid() then
                        del:Remove(o, fn)
                        local key = w:GetFullName():gsub("^%S+ ", "")
                        plannerParked[key] = plannerParked[key] or {}
                        table.insert(plannerParked[key], { o = o:GetFullName():gsub("^%S+ ", ""), f = fn })
                        M.plannerUnbound = (M.plannerUnbound or 0) + 1
                    end
                end
            end)
        end
    elseif next(plannerParked) then
        for key, list in pairs(plannerParked) do
            pcall(function()
                local w = SFO(key)
                if not (w and w:IsValid()) then return end
                for _, e in ipairs(list) do
                    local o = SFO(e.o)
                    if o and o:IsValid() then w.OnPlannerInteractionClicked:Add(o, e.f) end
                end
            end)
        end
        plannerParked = {}
    end
end

-- The guest's map in the lobby (owner's alpha 21 test, a new game's guest with an advanced host):
--   * it showed far fewer junctions and roads: the leg data were the host's, but the game hides what the player's own
--     story has not reached (BP_LegStateBase ShouldBeVisibleOnMap / the edge widget's Should Render Line test the
--     global whiteboard's progress). The host sends its answer per leg (mapsync V rows); the guest's answers are
--     replaced by it while its map is the host's (a hook's return value / out-param replaces the function's);
--     the roads (the edge widgets' cached answers) are set to the host's while the map is open (mapsync applyEdges);
--   * hovering a junction and holding the button made the guest's own game depart alone (traced: TravelTo, "on the
--     way" - the click unbinding below misses the hold): the run map's CanTravelHovered answers false for a guest in
--     the garage, and a junction cannot be marked for a scan (CanReveal / CanRevealAndHasCharge false).
local RUNMAP = "/Game/UI/Inventory/PlayerMenu/UMG_PlayerMenu_RunMap.UMG_PlayerMenu_RunMap_C"
local LEGBP = "/Game/Systems/Routes/States/BP_LegStateBase.BP_LegStateBase_C"
local LEGW = "/Game/UI/RunUI/Elements/UMG_RouteShape_Leg.UMG_RouteShape_Leg_C"
-- (not inside the mod's own TravelTo - runsync.travelTo: these hooks' return values broke its return)
local function guestInGarage() return S.role == "client" and not CoopSyncTravelling and gameState() == 4 end
local function mirrorVisible(legState)
    local vis = guestInGarage() and not S.mapRestored and Map and Map.visible
    if not vis then return nil end
    local ok, key = pcall(function() return legState.ShapeLeg:GetFName():ToString() end)
    if not ok or vis[key] == nil then return nil end
    return vis[key]
end
-- (the first callback: UE4SS runs it after the function's body - NOTES "UE4SS pre-hook = after body" - where its
-- return value / out-param replaces the function's; the probes' hooks were these)
local function hookGuestMap()
    M.guestMap = { legs = 0, edges = 0, travel = 0, reveal = 0 }
    local G = M.guestMap
    Hook(LEGBP .. ":ShouldBeVisibleOnMap", function(ctx)
        local v = mirrorVisible(ctx:get())
        if v ~= nil then G.legs = G.legs + 1 return v end
    end)
    Hook(RUNMAP .. ":CanTravelHovered", function(_, canNav)
        if guestInGarage() then pcall(function() canNav:set(false) end) G.travel = G.travel + 1 end
    end)
    for _, fn in ipairs({ "CanReveal", "CanRevealAndHasCharge" }) do
        Hook(LEGW .. ":" .. fn, function(_, can)
            if guestInGarage() then pcall(function() can:set(false) end) G.reveal = G.reveal + 1 end
        end)
    end
end

local function lobbyTick(gstate, world)
    if gstate == 1 then
        if not S.menuLeft then
            if netHead().state == "lobby" then netCmd("leave") S.note = "main menu: lobby left" end
            S.menuLeft = true
        end
    else S.menuLeft = false end
    if gstate == 4 and S.role and netHead().peer == "1" then
        if S.garageWorld ~= world then
            S.garageWorld = world
            local ok, r = pcall(Players.start, Sync, S.role, chan, { garage = true })
            S.note = ok and ("garage: " .. tostring(r)) or ("garage sync failed: " .. tostring(r))
            if ok then pcall(Weather.start, Players, S.role) end
        end
    elseif gstate ~= 4 or not S.role then
        if S.garageWorld and gstate == 4 then pcall(Players.stop) pcall(Weather.release) end -- left the lobby in the garage
        S.garageWorld = nil
    end
    local okM, eM = pcall(mapTick, gstate, world, netHead().peer == "1")
    pcall(gateTick, gstate)
    if not okM then S.note = "map: " .. tostring(eM) end
    if not S.plannerHooked and isFunction(PLANNER) then
        S.plannerHooked = true
        pcall(Hook, PLANNER .. ":IsCursorOverInteraction", function() end, function(_, _, isOver)
            if S.role == "client" then pcall(function() isOver:set(false) end) M.mapClicksBlocked = (M.mapClicksBlocked or 0) + 1 end
        end)
    end
    pcall(plannerClicks, gstate == 4 and S.role == "client")
    if not S.guestMapHooked then S.guestMapHooked = true pcall(hookGuestMap) end
end

-- hooks of the flow: the host's departure from the garage starts the run for the lobby; loading a save or starting a
-- new game leaves it
-- a name for the logs: GetFName on a null object (an unset MapLocation) crashes the game past pcall (an access
-- violation in UE4SS's GetFName - two probes and a nextzone host, 2026-11-09): IsValid first
function CoopSyncObjName(o)
    local ok, s = pcall(function() return (o and o:IsValid()) and o:GetFName():ToString() or "nil" end)
    return ok and s or "?"
end
local function hookFlow()
    pcall(Hook, "/Script/PenDriverPro.BaseRouteState:TravelTo", function(_, dest)
        do local ok, s = pcall(function() local l = dest:get() return CoopSyncObjName(l.ShapeLeg) .. " " .. CoopSyncObjName(l.MapLocation) end) pcall(Hitch.note, "timeline TravelTo: " .. (ok and s or "?")) end
        if S.role == "host" and gameState() == 4 then netCmd("start") S.departing = true S.note = "run started: the lobby comes along" end
        -- a guest's own pick of a junction (the map at the gate, or the map table) still ends on the host's map
        if S.role == "client" and gameState() == 4 then
            -- (the game's own travel, not the mod's: the drive-out waits for it instead of joining - clientTick)
            if not CoopSyncTravelling then S.gameTravelSeen = nowS() pcall(Hitch.note, "timeline the game travels by itself") end
            pcall(function()
                local ml = Run.hostMapLocation(Link.docPath(chan, "inbox", "host-run.txt"))
                if ml then dest:get():OverrideMapLocation(ml) M.guestPicksRedirected = (M.guestPicksRedirected or 0) + 1 end
            end)
        end
        -- a guest's own departure: its own map back (if the lobby's map is still on) and saved by this departure
        if not S.role and gameState() == 4 then
            local backup = chan .. "/map-backup.tsv"
            if Map.hasBackup(backup) then
                if not S.mapRestored then pcall(Map.restore, backup) end
                Map.forget(backup)
                S.mapRestored = false
            end
        end
    end)
    -- (the timeline: a leg's map chosen again by the game - the guest did not get the host's stabilizer zone)
    pcall(Hook, "/Game/Systems/Routes/States/BP_LegStateBase.BP_LegStateBase_C:SelectMapLocation", function() end, function(self)
        local ok, s = pcall(function() local l = self:get() return CoopSyncObjName(l.ShapeLeg) .. " " .. CoopSyncObjName(l.MapLocation) end)
        pcall(Hitch.note, "timeline the game chose a leg's map: " .. (ok and s or "?"))
    end)
    for _, fn in ipairs({ "UserLoadGame", "UserNewGame" }) do
        pcall(Hook, "/Game/Systems/Managers/BP_SaveGameManager.BP_SaveGameManager_C:" .. fn, function()
            -- (not the guest's own load of the host's zone: zonesave.lua)
            if S.role and not (ZoneSave and ZoneSave.selfLoad) then netCmd("leave") S.note = "save loaded: lobby left" end
        end)
    end
end

local TEST_FPS = tonumber(os.getenv("COOPTEST_FPS") or "")
local function KSL() return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
-- A watch on the cars (owner's alpha 17 / 18 tests: the guest had its own car twice, startflow never showed it): in a
-- co-op zone every 10 s the level's BP_PlayerCarNew_C are counted; more than the own car + the other's twins goes to
-- the mod's log with each car (own = the car manager's, twin, or neither), its place and its parts' count, once per
-- change. (FindAllOf walks every object: ~3.5 ms, so not more often.)
M.carsSeen = "-"
local function carWatch(gstate)
    S.carTicks = (S.carTicks or 0) + 1
    if gstate ~= 5 or not S.role or S.carTicks % 20 ~= 0 then return end
    local pawn = FindFirstOf("PlayerController").Pawn
    local lvl = pawn and pawn:IsValid() and pawn:GetFullName():match("^%S+%s+(.-:PersistentLevel)%.")
    if not lvl then return end
    local m = FindFirstOf("BP_CarManager_C")
    local ctx = m and m.NewCarActor
    local twins, list, n = 0, {}, 0
    for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
        -- (a destroyed actor waits for the GC for minutes here and is still IsValid() - to KismetSystemLibrary too;
        -- it has no root component any more: at 0,0,0, no parts. startflow counted a removed twin as a third car)
        -- (its RootComponent field may still read valid: its place is exactly 0,0,0 then)
        local root = c:IsValid() and c.RootComponent
        local at = root and root:IsValid() and c:K2_GetActorLocation()
        if at and (at.X ~= 0 or at.Y ~= 0 or at.Z ~= 0) and c:GetFullName():find(lvl, 1, true) and not c:IsActorBeingDestroyed() then
            n = n + 1
            local tw = (CoopSyncTwins or {})[c:GetAddress()] ~= nil
            if tw then twins = twins + 1 end
            local l = c:K2_GetActorLocation()
            local att = {}
            pcall(function() c:GetAttachedActors(att, true) end)
            list[#list + 1] = string.format("%s%s%s@%.0f,%.0f,%.0f parts=%d", c:GetFName():ToString(), tw and " twin" or "",
                (ctx and ctx:IsValid() and ctx:GetAddress() == c:GetAddress()) and " context" or "", l.X, l.Y, l.Z, #att)
        end
    end
    M.carsSeen = string.format("%d/%d", n, twins)
    local sig = table.concat(list, ";"):gsub("@[^ ]+", "")
    if n > twins + 1 and sig ~= S.carSig then
        print(string.format("[CoopSync] EXTRA CAR: %d cars, %d twins here: %s\n", n, twins, table.concat(list, "; ")))
        M.extraCars = (M.extraCars or 0) + 1
    end
    -- (a second copy of the own car the zone's load built: removed once the zone plays - twincar dropCopies)
    if n > twins + 1 and (S.state == "playing" or S.state == "hosting") then
        local okT, T = pcall(function() return Players.twinModule() end)
        if okT and T and T.dropCopies then
            local okD, r = pcall(T.dropCopies)
            if okD and r and r > 0 then M.copiesDropped = (M.copiesDropped or 0) + r S.carSig = nil return end
            if not okD then print("[CoopSync] dropCopies failed: " .. tostring(r) .. "\n") end
        end
    end
    S.carSig = sig
end

-- The guest's screen dark from driving out until the host's zone is in and synced (owner, alpha 19 item 5: "the
-- guest should never see a random zone" - it stood ~1 min in its own generated zone, then saw the load and the
-- import fill in). The camera's fade, held: the HUD stays on top. Set every frame while on (each level load makes
-- a new camera manager); at most COVER_MAX_S (a sync that never ends must not leave the player blind).
-- (owner, 2026-11-09: "the map opened and closed at once, then the black screen - and the guest could still walk, saw
-- the items' highlights, heard the zone; anomalies attacked it under the black screen; a loading screen instead, the
-- guest's game paused while it loads to the host"): the game's own loading screen (LoadingScreen_C, "on the way...")
-- over everything from the moment the guest drives into an exit (before the game's junction map opens: it opens under
-- it and is closed), and the world paused while nothing of it is needed (coverPause), the input ignored.
local COVER_MAX_S = 240
local LOAD_SCREEN = "/Game/UI/System/LoadingScreen.LoadingScreen_C"
local WRONG_WORLD_S = 10
local function coverWanted(gstate, world)
    if S.role ~= "client" then return false end
    local st = S.state or ""
    local on = st == "joining" or st:find("^zone:") ~= nil
    -- in the garage: once the guest drove into the exit (the junction map opens a moment after - under the screen)
    if gstate == 4 then on = S.joinPending == true or st == "joining" end
    -- a zone that is not the host's (nextzone-test 2026-11-09: the host's junction, but the game loaded the guest's own
    -- zone for it - a stabilizer zone on the host's side): nothing of the host's comes here - not left blind and paused
    local ses = S.lastSession or {}
    local wrong = on and gstate == 5 and st ~= "zone: loading the host's" and st ~= "joining" and ses.world and ses.world ~= "-" and ses.world ~= world
    if wrong then S.wrongSince = S.wrongSince or nowS() else S.wrongSince = nil end
    if S.wrongSince and nowS() - S.wrongSince > WRONG_WORLD_S then
        if not S.wrongNoted then S.wrongNoted = true pcall(Hitch.note, "timeline not the host's zone (" .. tostring(world) .. " / host " .. tostring(ses.world) .. "): screen lifted") end
        M.wrongWorld = (M.wrongWorld or 0) + 1
        on = false
    else S.wrongNoted = nil end
    if not on then S.coverSince = nil return false end
    S.coverSince = S.coverSince or nowS()
    return nowS() - S.coverSince < COVER_MAX_S
end
-- the world paused under the screen where the zone needs no ticking: the guest's own generated zone while the host's
-- comes (it is replaced), the host's zone loaded until the import is in (its actors spawn the same paused), the zone's
-- exit waiting for the host's pick. Not in the garage (the game's own travel runs there), not while a zone the guest
-- keeps generates (no host save: its generator must run), not after the import (the imported actors' first frames,
-- the cleanup, the sync start - a few seconds under the screen).
local function coverPause(gstate)
    if not S.cover or gstate ~= 5 then return false end
    local st = S.state or ""
    if st == "zone: at the exit" or st == "zone: loading the host's" or st == "zone: importing" then return true end
    if st == "joining" or st == "zone: generating" or st == "zone: waiting for the host's list" then
        if S.fromSave then return true end
        local ses = S.lastSession or {}
        local noSave = ses.list and ses.list ~= "-" and not ses.zsave -- (the host published without a zone save)
        return zoneSaveOn() and not S.zoneLoadedSeq and not noSave
    end
    return false
end
local function coverPC()
    local pc = S.coverPC
    if not (pc and pc:IsValid()) then pc = FindFirstOf("PlayerController") S.coverPC = pc end
    return pc
end
local function coverFrame()
    local want = S.cover
    if want == S.coverShown and not want then return end
    local ok = pcall(function()
        local pc = coverPC()
        if want then
            local w = S.coverW
            local shown = false
            pcall(function() shown = w and w:IsValid() and w:IsInViewport() end)
            if not shown then
                -- (a new world drops the viewport's widgets: added again; the camera fade under it as before, the
                -- screen dark even if the widget cannot be made)
                local okW = pcall(function()
                    local c = StaticFindObject(LOAD_SCREEN)
                    if not (c and c:IsValid()) then LoadAsset((LOAD_SCREEN:gsub("%.[^.]+$", ""))) c = StaticFindObject(LOAD_SCREEN) end
                    local WBL = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
                    w = WBL:Create(pc, c, pc)
                    w:AddToViewport(10000)
                    S.coverW = w
                end)
                M.coverScreens = (M.coverScreens or 0) + (okW and 1 or 0)
                pcall(function() pc.PlayerCameraManager:SetManualCameraFade(1.0, { R = 0, G = 0, B = 0, A = 1 }, false) end)
                pcall(function() pc:SetIgnoreMoveInput(true) pc:SetIgnoreLookInput(true) end)
            end
        else
            pcall(function() if S.coverW and S.coverW:IsValid() then S.coverW:RemoveFromParent() end end)
            S.coverW = nil
            pcall(function() pc.PlayerCameraManager:StopCameraFade() end)
            pcall(function() pc:ResetIgnoreInputFlags() end)
        end
    end)
    if ok then S.coverShown = want end
end
-- the world's pause under the screen (every tick: a new world comes unpaused)
local function coverPauseTick(gstate)
    local want = coverPause(gstate)
    local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    pcall(function()
        local pc = FindFirstOf("PlayerController")
        local paused = GS:IsGamePaused(pc)
        if want and not paused then GS:SetGamePaused(pc, true) M.coverPauses = (M.coverPauses or 0) + 1
        elseif not want and paused and S.coverPaused then GS:SetGamePaused(pc, false) end
    end)
    if want ~= (S.coverPaused or false) then pcall(Hitch.note, "timeline " .. (want and "paused" or "unpaused") .. " under the loading screen") end
    S.coverPaused = want
end
-- raised at once (the exit's hooks): the junction map the game opens next is under it
function M.raiseCover()
    if S.role ~= "client" then return end
    S.cover, S.coverSince = true, S.coverSince or nowS()
    coverFrame()
end
M.coverInfo = function() return string.format("cover=%s since=%s paused=%s", tostring(S.cover), tostring(S.coverSince), tostring(S.coverPaused)) end

local function tick()
    readControl()
    pcall(Link.tick)
    readNet()
    keepRunning()
    local gstate, world = gameState(), Sync.worldName()
    -- tests: $COOPTEST_FPS caps the frame rate (a slow PC), set again in every world (-ExecCmds did not hold)
    if TEST_FPS and world ~= S.fpsWorld then
        S.fpsWorld = world
        pcall(function() KSL():ExecuteConsoleCommand(FindFirstOf("PlayerController"), "t.MaxFPS " .. TEST_FPS, nil) end)
    end
    pcall(lobbyTick, gstate, world)
    if ZoneSave then pcall(ZoneSave.tick) end
    if S.role == "host" then hostTick(gstate, world)
    elseif S.role == "client" then clientTick(gstate, world) end
    -- the timeline (owner, 2026-11-09: "the guest's join takes long - check the timings for needless waits"): every
    -- change of the state, the game state or the world into the hitch log, and the last ones for the tests
    local sig = string.format("%s|%s|%s", tostring(S.state), tostring(gstate), tostring(world))
    if sig ~= S.tlSig then
        local t = nowS()
        local line = string.format("%.1f %s g=%s %s", t - (S.tlAt or t), tostring(S.state), tostring(gstate), tostring(world))
        S.tlSig, S.tlAt = sig, t
        pcall(Hitch.note, "timeline +" .. line)
        M.timeline = M.timeline or {}
        M.timeline[#M.timeline + 1] = string.format("%.1f:%s", t, line)
        if #M.timeline > 60 then table.remove(M.timeline, 1) end
    end
    S.cover = coverWanted(gstate, world)
    -- the import / cleanup jobs take a bigger slice of each frame while the guest's screen is covered (its frame rate
    -- unseen): the same work in fewer frames (owner, 2026-11-09: 4.5 s of import spread over 14 s)
    pcall(function() Sync.sliceMs = S.cover and LOAD_SLICE_MS or nil end)
    if S.role == "client" or S.coverPaused then pcall(coverPauseTick, gstate) end
    -- (the controller looked up again every tick: a level load leaves the old one valid-looking for a while)
    if S.cover then M.covered, S.coverPC = (M.covered or 0) + 1, FindFirstOf("PlayerController") end
    pcall(carWatch, gstate)
    -- the co-op checklist in the garage (checklist.lua)
    if CoopSyncChecklist then pcall(CoopSyncChecklist.tick) end
    writeStatus(gstate, world)
end

-- chanDir: the channel directory (nil = $COOPSYNC_CHAN or <Saved>/CoopSync)
function M.start(syncModule, runModule, chanDir)
    Sync, Run = syncModule, runModule
    State, Players, Weather, Map = require("statesync"), require("playersync"), require("weathersync"), require("mapsync")
    ZoneSave = require("zonesave")
    chan = chanDir or os.getenv("COOPSYNC_CHAN")
    if not chan or chan == "" then
        local saved = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):GetProjectSavedDirectory():ToString()
        chan = saved .. "CoopSync"
    end
    chan = chan:gsub("\\", "/"):gsub("/$", "")
    -- the helper normally made them; mkdir (a cmd process) only when a folder is missing
    for _, sub in ipairs({ "outbox", "inbox" }) do
        local probe = io.open(chan .. "/" .. sub .. "/.probe", "wb")
        if probe then probe:close() os.remove(chan .. "/" .. sub .. "/.probe")
        else os.execute('mkdir "' .. (chan .. "/" .. sub):gsub("/", "\\") .. '" 2>nul') end
    end
    local f = io.open(chan .. "/control.txt", "rb")
    if f then ctlOff = f:seek("end") f:close() end -- commands from before this game start are old
    S.pauseHook = hookPause()
    pcall(Hitch.start, chan)
    pcall(hookFlow)
    -- the radio's clock (twincar "Radio music") from the game's start: a track that begins is seen when it begins (a
    -- clock started by the player sync took a track already playing as beginning then)
    local okR, Radio = pcall(dofile, Sync.DIR .. "twincar.lua")
    if okR and Radio then TwinMod = Radio end
    if okR and Radio then
        loop(100, function() pcall(Radio.clockTick, S.role ~= nil) end)
    end
    loop(1, function() if S.cover or S.coverShown then coverFrame() end end) -- (every frame: see coverWanted)
    loop(TICK_MS, function()
        local ok, e = pcall(tick)
        if not ok then S.note = "tick error: " .. tostring(e) end
    end)
    return "session: channel " .. chan
end
-- debug menu actions (alpha): recovery when something broke in a real game
function M.debug(action)
    if action == "resync" then
        if S.role == "host" and S.state == "hosting" then
            -- publish the zone again under a new seq: the guest imports it once more
            State.stopped, Players.stopped = true, true
            S.state, S.readyTicks, S.arrived, S.stoppedAt = "zone: generating", READY_TICKS, 0, nowS()
            return L("sess.zone_resent")
        elseif S.role == "client" and (S.state == "playing" or S.state == "zone: imported") then
            State.stopped, Players.stopped = true, true
            S.importedSeq, S.state = nil, "zone: waiting for the host's list"
            return L("sess.zone_reloading")
        end
        return L("sess.nothing_to_sync", S.state)
    elseif action == "restart" then
        if not (S.state == "hosting" or S.state == "playing") then return L("sess.sync_not_running", S.state) end
        State.stopped, Players.stopped = true, true -- their loops end within a frame or two
        After(1500, function()
            State.start(Sync, S.role, chan, S.role == "host" and (chan .. "/" .. string.format("host-spawnlist-%d.tsv", S.seq)) or S.list)
            Players.start(Sync, S.role, chan, { ownCar = S.role == "client" and S.mode == "car" })
            Weather.start(Players, S.role)
        end)
        return L("sess.sync_restarting")
    elseif action == "teleport" then
        local ok, r = pcall(Players.teleportToOther)
        return ok and tostring(r) or L("sess.teleport_failed", tostring(r))
    elseif action == "restorecar" then
        local ok, r = pcall(Run.restoreCar, Run.insuranceFile())
        return ok and tostring(r) or L("sess.restore_failed", tostring(r))
    elseif action == "leave" then
        State.stopped = true
        Players.stop()
        S.role, S.go, S.state = nil, false, "idle"
        Weather.release()
        return L("sess.left_session")
    end
    return L("sess.unknown_action", tostring(action))
end
function M.state() return S end
function M.channel() return chan end
-- the mod's folder (Mods/CoopSync/), for its tools (report script)
function M.modDir() return (Sync.DIR:gsub("\\", "/"):gsub("Scripts/?$", "")) end

-- The network: in the game (CoopNative, link.lua); the old CoopNet.exe (Steam lobby + P2P in a process next to the
-- game, Mods/CoopSync/net/CoopNet.exe) only with COOPSYNC_NET=exe or without the native half. CoopNet.exe exits by
-- itself with the game; a second start for the same channel exits at once (its lock file).
function M.startNet()
    local r = Link.start(chan)
    if r then return r end
    local exe = M.modDir() .. "net/CoopNet.exe"
    local f = io.open(exe, "rb")
    if not f then return "CoopNet not installed" end
    f:close()
    os.execute(string.format('start "" "%s" --chan "%s"', exe:gsub("/", "\\"), chan:gsub("/", "\\")))
    return "CoopNet started"
end
function M.info() return string.format("role=%s mode=%s state=%s seq=%d note=%s", tostring(S.role), S.mode, S.state, S.seq, S.note) end

return M
