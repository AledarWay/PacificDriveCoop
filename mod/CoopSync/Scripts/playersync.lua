-- Players and the car. Each player owns its own character (client-authoritative avatar); the host owns
-- the car. ~10 transforms per second go over the "fast" channel (relay channel 1):
--   P <time> x y z pitch yaw roll seat       the sender's own character; seat 0 = not in the car, -1 = in the
--                                            car waiting for a seat, 1 driver, 2 front passenger, 3/4 back L/R
--   C <time> x y z pitch yaw roll hs cs      the host's car + seat table (host's seat, client's seat, 0 = none)
--   S <time> x|- y|-                         client -> host: got in, needs a seat (car-local spot it stood at)
--   A <time> seat reason                     host -> client: the seat it got (0 = none free: it gets out again)
--   X <time> remove <seat>                   client -> host: take the device off that seat frame (into the trunk)
--   I <time> throttle brake steer handbrake  client -> host while the client sits on seat 1 (~30 Hz): its
--                                            driver input, applied every frame to the host's car (physics stay there)
-- Every receiver shows the other player as a puppet (SkeletalMeshActor with the player mesh, no
-- collision; idle/walk/run single-node animations, a posed sitting mesh in the car) and the client's
-- car follows the host's car. A seated puppet is attached to the local car at its seat. Positions are smoothed
-- toward the newest sample every APPLY_MS; jumps over SNAP_DIST are teleports.
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
local function loop(ms, fn, label)
    local h
    h = LoopInGameThreadWithDelay(ms, function()
        -- (an error escaping here made UE4SS drop the loop for good: the co-op menu item never came back, alpha 9)
        local t0 = os.clock()
        local ok, r = pcall(fn)
        if CoopSyncHitch then CoopSyncHitch.spent(os.clock() - t0, label or "players") end
        if not ok then
            if CoopSyncHitch then CoopSyncHitch.note("loop error: " .. tostring(r):sub(1, 200)) end
            return
        end
        if r == true and h then CancelDelayedAction(h) end
    end)
    return h
end
local SEND_MS, APPLY_MS = 100, 33
local SMOOTH = 0.6       -- fraction of the remaining distance covered per apply step
local EXTRAPOLATE_MAX = 0.3 -- seconds a sample may be extrapolated along its velocity
local MAX_SPEED = 4000      -- units/s cap for the velocity estimate (~145 km/h, as TD.KIN_MAX_SPEED: the car goes faster than 2000)
local SNAP_DIST = 500
local PLAYER_GONE_MS = 15000 -- no sample from the other player for this long = it left (5 s: a stall of the
                            -- other game made the host drop and respawn the guest's twin - another stall)
local onHostLeaving -- defined in the leaving section, called from applyTick
local pushSample -- defined with the puppet interpolation, called from applyTick
local lastPlayerRecv

local Sync, role, chan
local outFile, inFile
local readOff = 0
local st = { sent = 0, recv = 0, puppetSpawned = 0, errors = {}, delays = {} }
local target = { player = nil, car = nil }
local puppetPath, carPath, meshRel, carPuppeted, posePath, animState, attachedTo, poseArms
local capsulePath, puppetSolid
local footSamples = {}
local animName
local tracing, traceFile

local function err(m) if #st.errors < 10 then st.errors[#st.errors + 1] = m end end

-- per-loop cost (ms per call, max) for M.profile()
local prof = {}
local function timed(name, f)
    if CoopSyncHitch then CoopSyncHitch.crumb("players " .. name) end
    local t0 = os.clock()
    local ok, e = pcall(f)
    local dt = (os.clock() - t0) * 1000
    local p = prof[name] or { ms = 0, n = 0, mx = 0 }
    prof[name] = p
    p.ms, p.n = p.ms + dt, p.n + 1
    if dt > p.mx then p.mx = dt end
    if CoopSyncHitch then CoopSyncHitch.op("players " .. name, dt) end
    return ok, e
end
function M.profile()
    local t = {}
    for k, p in pairs(prof) do t[#t + 1] = string.format("%s=%.2f/max%.0fms x%d", k, p.ms / math.max(p.n, 1), p.mx, p.n) end
    table.sort(t)
    return table.concat(t, " ")
end
function M.profileReset() prof = {} end

-- Wall clock in ms. KismetMathLibrary:Now() comes back as an empty table in UE4SS (FDateTime is not
-- converted), so os.clock() (MSVC: real time since process start) is anchored to the moment os.time()
-- ticks to the next second; ~1 ms precise, the same scale for every process on one PC.
local clockBase
function M.calibrate()
    local t0 = os.time()
    local guard = os.clock() + 1.5
    while os.time() == t0 and os.clock() < guard do end
    clockBase = os.time() * 1000 - os.clock() * 1000
end
-- tests: this side's clock that many ms off (two PCs' clocks differ; on one PC the tests never saw it)
function M.testClockSkew(ms)
    if not clockBase then M.calibrate() end
    clockBase = clockBase + (tonumber(ms) or 0)
    return "clock skewed " .. tostring(ms) .. " ms"
end
function M.nowMs()
    if not clockBase then M.calibrate() end
    return math.floor(os.clock() * 1000 + clockBase)
end

local outStream, inStream -- host.fast / client.fast: through the in-game network (link.lua) or these files
local function append(path, line)
    if path == outFile and Link.send(outStream, line) then return end
    local f = io.open(path, "ab")
    if f then f:write(line .. "\n") f:close() end
end

-- another module's line on this side's fast channel ("<tag>\t<now ms>\t<fields...>"): weathersync.lua
function M.send(tag, fields)
    if not outFile or M.stopped then return false end
    append(outFile, tag .. "\t" .. M.nowMs() .. (fields and fields ~= "" and ("\t" .. fields) or ""))
    return true
end

local function trace(kind, l)
    if tracing then append(traceFile, string.format("%d\t%s\t%.1f\t%.1f\t%.1f", M.nowMs(), kind, l.X, l.Y, l.Z)) end
end

local function localPawn()
    local pc = (CoopSyncFirst or FindFirstOf)("PlayerController")
    local p = pc and pc.Pawn
    if p and Sync.alive(p) then return p end
    return nil
end

-- Own-car mode (opts.ownCar on the client): every player brings its own car. The game has one player car
-- per world, so each side shows the other's car as a TWIN (twincar.lua, owner's choice 2026-10-23: a real
-- BP_PlayerCarNew_C - its parts the game's own from the owner's equipment (EQ lines),
-- a puppet moved by the stream; doors, seats, dash, screens are the game's) or, when a twin cannot be made /
-- opts.ghost, a GHOST (carghost.lua: plain mesh actors with the owner's visible meshes, no game logic). The client
-- shows the host's car (C lines), the host the client's (G lines). The owner describes its car's meshes on Y lines
-- (every LAYOUT_MS, a new seq when they changed). Copies are removed in the travel pre-hooks.
--   Y <time> <seq> <i> <n> <kind|mesh|x|y|z|pitch|yaw|roll|sx|sy|sz>
local ownCar = false
local garage = false -- lobby in the garage: each player in its own garage, only the players' puppets (P lines) and the sky
local ownCarPath   -- client, own-car mode: its own (real) car
local otherCarPath -- host: the copy of the client's car
local otherCarPuppeted, lastOtherRecv
local Ghost, Twin, Native
local useTwin = true
local LAYOUT_MS = 10000
local layoutOut = { seq = 0, sig = nil, lines = {}, sentMs = -1e9 } -- this side's car description
local layoutIn = { seq = -1, n = 0, lines = {}, have = 0, ready = nil, readySeq = -1 } -- the other side's
local ghostSeq = -1 -- the layout seq the current copy was built / styled from
-- the twin doors' / equipment state and helpers (one table: the file's main function is at Lua's 200 locals)
local TD = {}

local function localCar()
    local c = Sync.deref(carPath)
    if c then return c end
    -- client in own-car mode: the host's car is the copy (none until the first C line and the layout)
    if role == "client" and ownCar then return nil end
    -- the own car (never a twin): FindFirstOf can return a non-level instance (archetype)
    local own = Twin and Twin.ownCar()
    if own and Sync.ref(own) ~= otherCarPath then carPath = Sync.ref(own) return own end
    return nil
end

-- A copy of the other player's car at a sample's transform (nil until its layout came): a twin, else a ghost.
local function spawnCarCopy(sample)
    -- a twin carries the owner's equipment (EQ lines; twincar "Equipment": its parts are the game's own, no restyle)
    if useTwin and target.equip then
        local t0 = os.clock()
        local twin, why = Twin.spawn(sample.loc, sample.rot, target.equip)
        if twin and TD.native then pcall(Native.sweep) TD.sweepAt = M.nowMs() end -- (the new car's manager bindings parked)
        if CoopSyncHitch then CoopSyncHitch.op("twin spawn", (os.clock() - t0) * 1000) end
        if twin then
            TD.equipSeqApplied = target.equipSeq
            if role == "client" and ownCar then TD.clearUntil = M.nowMs() + 30000 end -- (TD.clearOwnCar)
            ghostSeq = layoutIn.readySeq
            st.carCopies = (st.carCopies or 0) + 1
            return twin
        end
        st.twinFailed = tostring(why)
    end
    if useTwin and not target.equip and not st.twinFailed then return nil end -- (the owner's EQ comes within 2 s)
    if not layoutIn.ready then return nil end
    local root, n = Ghost.build(layoutIn.ready, sample.loc, sample.rot)
    if root then
        ghostSeq = layoutIn.readySeq
        st.carCopies = (st.carCopies or 0) + 1
        st.ghostMeshes = n
    end
    return root
end
-- the copy follows a new layout: a twin is restyled in place; a ghost is rebuilt (returns false: build it again)
local function restyleCopy(c)
    if Twin.isTwin(c) then
        ghostSeq = layoutIn.readySeq -- (a twin follows the EQ lines, not the layout)
        return true
    end
    return false
end
local function removeCopy(c)
    if not c then return 0 end
    if Twin.isTwin(c) then return Twin.destroy(c) end
    return Ghost.destroy(c)
end

-- Remove the copies this side built (they go with every travel: removed in the travel pre-hooks).
local ghostLeave -- defined with the own-car seats below
local twinControlsRestore -- defined with the wheel below
local function destroyCopies()
    -- a player sitting in a copy gets out first (the copy goes, the player stays)
    local pawn = localPawn()
    if pawn and ghostLeave then pcall(ghostLeave, pawn, "car gone") end
    -- (native cars: the game's one car back on the own car before the other's goes - the manager, the input
    -- controller and the bindings would point at a car that is no more)
    if TD.native and Native and Twin then pcall(function() Native.use(Twin.ownCar()) Native.reset() end) end
    if role == "client" and ownCar and carPath then
        st.copiesRemoved = (st.copiesRemoved or 0) + removeCopy(Sync.deref(carPath))
        carPath, carPuppeted = nil, false
    end
    if otherCarPath then
        st.copiesRemoved = (st.copiesRemoved or 0) + removeCopy(Sync.deref(otherCarPath))
        otherCarPath, otherCarPuppeted = nil, false
    end
end

-- Owner side: send this side's car layout every LAYOUT_MS (new seq when the meshes changed).
-- what the car carries in its slots (~1 ms): the full layout (~0.5 s: every part's meshes and material parameters -
-- the host stalled for half a second every 10 s, owner's "small freezes") is made only when this changed, or every
-- LAYOUT_FULL_MS for slow changes (wear, dirt)
local LAYOUT_FULL_MS = 60000
local SSC_CLASS = StaticFindObject("/Script/PenDriverInventory.SlotSceneComponent")
local function slotSig(car)
    local r = {}
    local comps = car:K2_GetComponentsByClass(SSC_CLASS)
    for i = 1, #comps do
        local c = comps[i]:get()
        local sl = c.ItemSlot
        local a = "-"
        if sl and sl:IsValid() and sl.Items:GetArrayNum() > 0 then
            local okA, arch = pcall(function() return sl:GetCurrentArchetype() end)
            a = (okA and arch and arch:IsValid()) and arch:GetFName():ToString() or "?"
        end
        r[#r + 1] = c:GetFName():ToString() .. "=" .. a
    end
    table.sort(r)
    return table.concat(r, ",")
end
local function sendLayout(car, outPath)
    local now = M.nowMs()
    if now - layoutOut.sentMs < LAYOUT_MS then return end
    layoutOut.sentMs = now
    local okQ, quick = pcall(slotSig, car)
    if okQ and quick == layoutOut.quick and now - (layoutOut.fullMs or -1e9) < LAYOUT_FULL_MS and #layoutOut.lines > 0 then
        -- unchanged: the same lines once more every 2nd time, for a late receiver
        layoutOut.calls = (layoutOut.calls or 0) + 1
        if layoutOut.calls % 2 == 1 then
            for i, l in ipairs(layoutOut.lines) do
                append(outPath, string.format("Y\t%d\t%d\t%d\t%d\t%s", now, layoutOut.seq, i, #layoutOut.lines, l))
            end
        end
        return
    end
    layoutOut.quick, layoutOut.fullMs = okQ and quick or nil, now
    local ok, lines = pcall(Ghost.layout, car)
    if not ok or not lines then return end
    -- a new layout = another set of meshes (a part came off / on); moving parts (wheels, suspension) shift
    -- their transforms all the time and must not rebuild the 100-actor ghost every LAYOUT_MS
    local names = {}
    -- (kind|mesh plus the materials field: a part or paint changed; not the transforms)
    -- (the material table's values - wear, dirt - change slowly and do not rebuild the ghost either)
    -- a slot's "@<id>" counts as its parent material: the ids shift when two looks drift apart (rain wets one
    -- panel), which rebuilt the ghost every 20 s in the rain
    local parentOf = {}
    for _, l in ipairs(lines) do
        local id, parent = l:match("^mat|(%d+)|([^|]+)|")
        if id then parentOf[id] = parent end
    end
    for _, l in ipairs(lines) do
        if l:sub(1, 4) ~= "mat|" then
            local km, mats = l:match("^([^|]+|[^|]+)|"), l:match("|([^|]*)$")
            mats = (mats or ""):gsub("@(%d+)", function(id) return parentOf[id] or id end)
            names[#names + 1] = (km or l) .. "|" .. mats
        end
    end
    table.sort(names)
    local sig = table.concat(names, "\n")
    local changed = sig ~= layoutOut.sig
    if changed then layoutOut.sig, layoutOut.lines, layoutOut.seq = sig, lines, layoutOut.seq + 1 end
    -- the lines (~75 KB with the material table) go when they changed, and every 2nd time for a late receiver
    layoutOut.calls = (layoutOut.calls or 0) + 1
    if not changed and layoutOut.calls % 2 ~= 1 then return end
    for i, l in ipairs(layoutOut.lines) do
        append(outPath, string.format("Y\t%d\t%d\t%d\t%d\t%s", now, layoutOut.seq, i, #layoutOut.lines, l))
    end
    st.layoutsSent = (st.layoutsSent or 0) + 1
end

-- Receiver: collect a layout (all n lines of one seq).
local function takeLayoutLine(t)
    local seq, i, n, line = tonumber(t[3]), tonumber(t[4]), tonumber(t[5]), t[6]
    if not (seq and i and n and line) then return end
    if seq ~= layoutIn.seq then layoutIn.seq, layoutIn.n, layoutIn.lines, layoutIn.have = seq, n, {}, 0 end
    if not layoutIn.lines[i] then layoutIn.lines[i] = line layoutIn.have = layoutIn.have + 1 end
    if layoutIn.have == layoutIn.n and layoutIn.readySeq ~= seq then
        layoutIn.ready, layoutIn.readySeq = layoutIn.lines, seq
        st.layoutsReceived = (st.layoutsReceived or 0) + 1
    end
end
local function xform(a)
    local l, r = a:K2_GetActorLocation(), a:K2_GetActorRotation()
    return string.format("%.2f\t%.2f\t%.2f\t%.3f\t%.3f\t%.3f", l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll)
end

---------------------------------------------------------------------------------------------------
-- send

-- Seats (car-local, X forward, Y right): 1 driver, 2 front passenger, 3 back left, 4 back right.
-- The game seats its player as the driver (observed character 46.2,-45.8,-12.3); the front passenger is
-- that mirrored across the centre line; the back seats sit between the rear doors (X 8) and the rear
-- axle (X -100). BACK_X from the devices the back seats hold (probed 2026-11-14 on the Quick start car: the battery
-- on seat 4 spans X +12..-64, the fuel tank on seat 3 +7..-92 - the back rest at about -64), the hips some 20 in front
-- of it; -60 before (an estimate) sat the player in the back rest: its camera looked through the car's back (owner's
-- two-games test 2026-11-14).
-- A seat is taken by a player or by a device: the front passenger seat holds the ARC device (owner;
-- removable later), the back seats are item slots (frames) that hold the base fuel tank / battery in a
-- new game. The host decides who sits where; a player who gets in picks the free seat nearest to the
-- door it got in at, or is put out of the car when none is free. Driving = sitting on seat 1.
local BACK_X = -45
local SEAT_DOOR = { [1] = { X = 131, Y = -150 }, [2] = { X = 131, Y = 150 }, [3] = { X = 8, Y = -150 }, [4] = { X = 8, Y = 150 } }
local SEAT_NAME = { "driver", "front passenger", "back left", "back right" }
local SEAT_FRAME = { [3] = "SLOT_BackSeatLeft", [4] = "SLOT_BackSeatRight" }
-- The seats are fixed, car-local: every car is one blueprint (BP_PlayerCarNew_C), the twin too. They were measured from
-- the player once a session instead, which took a back seat for the driver's when the first sit of a session was a
-- back one: from then on the driver's door seated the player at the back, in both cars (owner's test 2026-11-14,
-- reproduced with the host: back-left first -> -60,-45.8 measured; driver's door first -> 46.5,-46.0).
-- TempSocket_Seat as the blueprint builds it: the game puts the seated player at the socket + sockDelta.
TD.SOCK_HOME = { X = 27, Y = -46, Z = -16 }
local seats
local sockDelta -- character relative location minus TempSocket_Seat relative location
local function seatRel(n)
    if not seats then
        local d = { X = 46.2, Y = -45.8, Z = -12.3 }
        seats = { [1] = d, [2] = { X = d.X, Y = -d.Y, Z = d.Z }, [3] = { X = BACK_X, Y = d.Y, Z = d.Z }, [4] = { X = BACK_X, Y = -d.Y, Z = d.Z } }
        sockDelta = { X = d.X - TD.SOCK_HOME.X, Y = d.Y - TD.SOCK_HOME.Y, Z = d.Z - TD.SOCK_HOME.Z }
    end
    return seats[n]
end
-- Where the game put the player at the wheel (diagnostics only: selfInfo's driver_seat_measured, seat-measure-test).
-- (the game's own entry - native cars - walks the player in already attached to the car: its first frames are at the
-- door, outside - owner's alpha 21 test. Taken once the player stays still 1 s within the cabin)
local function measureDriverSeat(rel)
    if math.abs(rel.Y) > 80 or math.abs(rel.X) > 250 then TD.seatCand = nil st.seatOutside = (st.seatOutside or 0) + 1 return end
    -- (the wheel is in the front half: a player the mod seated at the back - in at the start of the old shared-car mode,
    -- drive-test - is not at it; the back seats' X is BACK_X)
    if rel.X < 0 then TD.seatCand = nil return end
    local now = M.nowMs()
    if not TD.seatCand or (rel.X - TD.seatCand.X) ^ 2 + (rel.Y - TD.seatCand.Y) ^ 2 + (rel.Z - TD.seatCand.Z) ^ 2 > 4 then
        TD.seatCand = { X = rel.X, Y = rel.Y, Z = rel.Z, at = now }
        return
    end
    if now - TD.seatCand.at < 1000 then return end
    TD.seatCand = nil
    st.seatMeasured = string.format("%.1f,%.1f,%.1f", rel.X, rel.Y, rel.Z)
end

local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local function toCar(car, v) return KML:InverseTransformLocation(car:GetTransform(), v) end
local function toWorld(car, v) return KML:TransformLocation(car:GetTransform(), v) end

-- What device takes a seat (archetype name), or nil when the seat is free of devices.
local function seatDevice(car, n)
    if n == 2 then return "ARC" end
    local frame = SEAT_FRAME[n]
    if not frame then return nil end
    local ok, name = pcall(function()
        local sl = car[frame].ItemSlot
        if sl.Items:GetArrayNum() == 0 then return nil end
        local it = sl.Items[1]
        return (it and it:IsValid() and it.Archetype:IsValid()) and it.Archetype:GetFName():ToString() or "device"
    end)
    return ok and name or nil
end

-- The seats of a car taken by devices ("234", "-" none) for the other player's twin of it (C / G lines; its doors
-- only open there). Once a second.
TD.busyCache = { ms = -1e9, s = "-" }
-- Equipment of the cars (twincar "Equipment"): the owner's car contents on EQ lines (checked every 2 s, sent when
-- changed and every 10 s for a late receiver); what the local player changes on the other's twin goes back as EX.
TD.equipOut = { line = nil, sentMs = -1e9, checkMs = -1e9 }
function TD.sendEquip()
    local now = M.nowMs()
    if now - TD.equipOut.checkMs < 2000 then return end
    TD.equipOut.checkMs = now
    local ok, line = pcall(Twin.equipLine)
    if not (ok and line) then return end
    if line ~= TD.equipOut.line or now - TD.equipOut.sentMs > 10000 then
        TD.equipOut.line, TD.equipOut.sentMs = line, now
        append(outFile, string.format("EQ\t%d\t%s", now, line))
        st.equipSent = (st.equipSent or 0) + 1
    end
end
-- The parts' paint (twincar "Paint"): EP lines like EQ (checked every 3 s, sent when changed or every 15 s).
TD.paintOut = { line = nil, sentMs = -1e9, checkMs = -1e9 }
function TD.sendPaint()
    local now = M.nowMs()
    if now - TD.paintOut.checkMs < 3000 then return end
    TD.paintOut.checkMs = now
    local ok, line = pcall(Twin.paintLine)
    if not (ok and line) then return end
    if line ~= TD.paintOut.line or now - TD.paintOut.sentMs > 15000 then
        TD.paintOut.line, TD.paintOut.sentMs = line, now
        append(outFile, string.format("EP	%d	%s", now, line))
        st.paintSent = (st.paintSent or 0) + 1
    end
end
-- The parts' health / fuel / battery (twincar "Part state"): ES lines like EQ (checked every 1 s); the local
-- player's repairs / refuels on the other's twin go back as EY.
TD.stateOut = { line = nil, sentMs = -1e9, checkMs = -1e9 }
function TD.sendState()
    local now = M.nowMs()
    if now - TD.stateOut.checkMs < 1000 then return end
    TD.stateOut.checkMs = now
    local ok, line = pcall(Twin.stateLine)
    if not (ok and line) then return end
    if line ~= TD.stateOut.line or now - TD.stateOut.sentMs > 10000 then
        TD.stateOut.line, TD.stateOut.sentMs = line, now
        append(outFile, string.format("ES\t%d\t%s", now, line))
        st.stateSent = (st.stateSent or 0) + 1
    end
end
-- The own car's parameters from its parts (tuning.lua: engine, tires, flats, boost as the own car's handling has them -
-- every handling reads the local player's own parts, so the other side's twin of this car gets them from here): TU
-- lines, checked every second, sent when changed or every 10 s.
TD.tuningOut = { line = nil, sentMs = -1e9, checkMs = -1e9 }
function TD.sendTuning()
    local now = M.nowMs()
    if not TD.tuning or now - TD.tuningOut.checkMs < 1000 then return end
    TD.tuningOut.checkMs = now
    local ok, line = pcall(TD.tuning.ownLine)
    if not (ok and line) then return end
    if line ~= TD.tuningOut.line or now - TD.tuningOut.sentMs > 10000 then
        TD.tuningOut.line, TD.tuningOut.sentMs = line, now
        append(outFile, string.format("TU\t%d\t%s", now, line))
        st.tuningSent = (st.tuningSent or 0) + 1
    end
end
-- The car's lights as the owner's game shows them (twincar "Lights"): LI lines, checked 5 times a second, sent when
-- changed or every 5 s.
TD.lightsOut = { line = nil, sentMs = -1e9, checkMs = -1e9 }
function TD.sendLights(car)
    local now = M.nowMs()
    if now - TD.lightsOut.checkMs < 200 then return end
    TD.lightsOut.checkMs = now
    local ok, line = pcall(Twin.lightLine, car)
    local held = Twin.heldLightLine and Twin.heldLightLine() -- (sitting in the other's twin: the own car's as it was)
    if held then ok, line = true, held end
    if not (ok and line) then return end
    if line ~= TD.lightsOut.line or now - TD.lightsOut.sentMs > 5000 then
        TD.lightsOut.line, TD.lightsOut.sentMs = line, now
        append(outFile, string.format("LI\t%d\t%s", now, line))
        st.lightsSent = (st.lightsSent or 0) + 1
    end
end-- this side's copy of the other's car (client: the host's car, host: the guest's)
function TD.copy()
    if role == "client" and ownCar then return Sync.deref(carPath) end
    return Sync.deref(otherCarPath)
end
-- the twin on this side: the owner's newest contents onto it, the local player's changes on it to the owner
-- a part's time since t0 into M.profile
function TD.prof(name, t0) timed(name, function() end) local p = prof[name] p.ms = p.ms + (os.clock() - t0) * 1000 end
function TD.equipTick(c)
    if not Twin.isTwin(c) then return end
    if target.equip and TD.equipSeqApplied ~= target.equipSeq then
        TD.equipSeqApplied = target.equipSeq
        pcall(Twin.applyEquip, c, target.equip)
        pcall(Twin.muteDoorBreak, c) -- (a door spawned onto it now: its break handler off at once)
        TD.sweepAt = M.nowMs() - TD.SWEEP_MS + 1000 -- (parts spawned again bind themselves: parked 1 s later)
    end
    local now = M.nowMs()
    -- (every 0.5 s; the part state every 1 s: a repair is no quick action - 6 ms a check, soak test profile 2026-10-28)
    if now - (TD.equipWatchMs or 0) < 500 then return end
    TD.equipWatchMs = now
    -- (a door put on the twin - by the owner's line or by the local player - binds the game's OnConstraintBroken handler,
    -- which destroys the OWN car's door of that number when the twin's breaks: muted every 0.5 s here, not only with a
    -- full pose once a second. Owner's alpha 20 test: both had just put a driver's door back, the host got into the
    -- guest's car, it jolted, on shutting the driver's doors fell off on both sides - each the other car's.)
    timed("eq_doorbrk", function() Twin.muteDoorBreak(c) end)
    -- (each car drives by a tuning graph of its own: one shared asset made both cars drive by the last writer's parts)
    if TD.tuning then timed("eq_tuning", function() TD.tuning.tick(Twin.ownCar(), c) end) end
    if TD.native then
        -- (native cars: the twin keeps the game's own handlers; the car manager's bindings of the car that is not the
        -- context are parked - parts spawned again bind themselves afresh: a sweep every TD.SWEEP_MS, ~9 ms)
        if now - (TD.sweepAt or 0) > TD.SWEEP_MS then TD.sweepAt = now timed("eq_sweep", function() Native.sweep() end) end
    else
        timed("eq_mute", function() Twin.muteDoors(c) end) -- (a new door actor: the game's own E handlers off again)
        timed("eq_body", function() Twin.muteBody(c, TD.inTwin(c)) end) -- (the dash levers / top light: the game's own only inside)
    end
    if not (CoopSyncCarLightHook and CoopSyncCarLightHook.done and CoopSyncRadioHook and CoopSyncRadioHook.done and CoopSyncRadioHook.seekDone and CoopSyncRadioHook.seek == TD.onRandomSeek and CoopSyncGearHook and CoopSyncGearHook.on == Twin.shifterOf) then pcall(TD.hookCarLights) end
    timed("eq_music", function() TD.musicTick(c) end)
    -- (the paint again when it changed, and every 5 s: a part put on the twin comes in stock colours)
    if target.paint and (TD.paintSeqApplied ~= target.paintSeq or now - (TD.paintAt or 0) > 5000) then
        TD.paintSeqApplied, TD.paintAt = target.paintSeq, now
        timed("eq_paint", function() Twin.applyPaint(c, target.paint) end)
    end
    if target.lights then timed("eq_lights", function() Twin.applyLights(c, target.lights) end) end -- (again every time: the twin's own logic sets them)
    local t0 = os.clock()
    local ok, ch = pcall(Twin.watchEquip, c)
    TD.prof("eq_watch", t0)
    if not ok then return end
    for _, x in ipairs(ch) do
        append(outFile, string.format("EX\t%d\t%s\t%s", now, x.slot, x.want))
        st.equipExSent = (st.equipExSent or 0) + 1
    end
    if target.state and TD.stateSeqApplied ~= target.stateSeq then
        TD.stateSeqApplied = target.stateSeq
        pcall(Twin.applyState, c, target.state)
    end
    if now - (TD.stateWatchMs or 0) < 1000 then return end
    TD.stateWatchMs = now
    t0 = os.clock()
    local okS, sc = pcall(Twin.watchState, c)
    TD.prof("eq_state", t0)
    if not okS then return end
    for _, x in ipairs(sc) do
        append(outFile, string.format("EY\t%d\t%s\t%s\t%.2f", now, x.slot, x.kind, x.delta))
        st.stateEySent = (st.stateEySent or 0) + 1
    end
end
function TD.devicesBusy(car)
    local now = M.nowMs()
    if now - TD.busyCache.ms < 1000 then return TD.busyCache.s end
    local s = ""
    for n = 2, 4 do if seatDevice(car, n) then s = s .. n end end
    TD.busyCache.ms, TD.busyCache.s = now, s ~= "" and s or "-"
    return TD.busyCache.s
end

-- seatOf[who] = seat number; the host's table is the truth, the client mirrors it from C lines.
local seatOf = { host = nil, client = nil }
local myAssigned        -- client: the seat the host gave this character (cleared when it gets out)
local seatPending       -- client: a seat request is on its way
local lastOutside       -- car-local position of the own character when last seen outside the car
local function driverRole()
    if seatOf.host == 1 then return "host" elseif seatOf.client == 1 then return "client" end
    return nil
end
local function mySeat()
    if role == "host" then return seatOf.host end
    return myAssigned
end

-- Host: the free seat nearest to the door the player got in at (no entry point: driver first).
-- exact (getting into the other player's twin through a door): only the seat behind that door - the driver's too while
-- its owner does not sit there (owner, alpha 16: "anyone drives any car", the target design; the alpha 9 "thrown out
-- of the friend's driver seat" that had closed it was the old ghost car's)
local function chooseSeat(car, who, entry, tbl, exact)
    local seatTable = tbl or seatOf
    local order = { 1, 2, 3, 4 }
    if exact then
        local n = entry and (entry.X > 70 and 1 or 3) + (entry.Y > 0 and 1 or 0) or 1
        order = { n }
    elseif entry then
        local function d(n) local p = SEAT_DOOR[n] return (p.X - entry.X) ^ 2 + (p.Y - entry.Y) ^ 2 end
        table.sort(order, function(a, b) return d(a) < d(b) end)
    end
    local why = {}
    for _, n in ipairs(order) do
        local other = who == "host" and "client" or "host"
        local dev = seatDevice(car, n)
        if seatTable[other] == n then why[#why + 1] = n .. ":" .. other
        elseif dev then why[#why + 1] = n .. ":" .. dev
        else return n end
    end
    return nil, table.concat(why, ",")
end

local function exitCar(pawn, reason)
    st.denied = (st.denied or 0) + 1
    st.lastDenied = reason
    pcall(function() pawn["Exit Car"](pawn, false, true) end)
end

---------------------------------------------------------------------------------------------------
-- own-car mode: sitting in the other player's car = in this side's ghost of it
--   SG <time> x|- y|-     host -> client: got into the client's car (ghost) at that car-local spot, needs a seat
--   AG <time> seat reason client -> host: the seat it got in the client's car (0 = none: it gets out again)
--   P lines carry a car tag: H = the host's car, G = the client's (guest's) car, - = none
-- The game has no seat logic for a ghost: the character is attached to the ghost's root at the seat with its
-- movement and collision off; the car's owner hands out the seats (host car: S/A, client car: SG/AG with the
-- client's own table seatOfG). Getting in / out: the game's interact (pre-hook on Command Interact) next to a
-- door of the ghost / while in it - like a real car, no extra key.
local inGhost -- { tag = "H"|"G", seat = n|nil, pending = bool, entry = {X,Y} }
local seatOfG = { host = nil, client = nil } -- client: who sits where in its own car
local function myTag() return role == "host" and "H" or "G" end
local function otherTag() return role == "host" and "G" or "H" end
-- the actor standing for car <tag> on this side (real car, ghost or - guest mode - the client's puppeted copy)
local function carForTag(tag)
    if tag == "H" then return localCar() end
    if tag == "G" then return Sync.deref(role == "client" and ownCarPath or otherCarPath) end
    return nil
end
local function ghostOf(tag)
    if role == "client" and tag == "H" and ownCar then return localCar() end
    if role == "host" and tag == "G" then return Sync.deref(otherCarPath) end
    return nil
end
-- the local player sits in (or is getting into) twin c
function TD.inTwin(c)
    local g = inGhost and inGhost.twin and ghostOf(inGhost.tag)
    return g ~= nil and g:GetAddress() == c:GetAddress()
end

-- Headlights, top light, wipers: like the ignition, ONE state in the car manager for the game (its getters / setters;
-- probe cmds/ctl-probe.lua); the car's ToggleHeadlights / ToggleInteriorLight / ToggleWiperBlades flip it with the
-- lever / switch animation (the state changes within ~1 s). The owner's state rides on its C / G lines as one
-- digit each ("ltw", 0 / 1); sitting in a twin the manager holds the owner's (twinControls), the player's change goes
-- to the owner as K / KG lights|top|wipers|radio <0|1>, and the owner's game flips its real car with the toggle.
TD.LTW = {
    { "lights", "GetCarLightsOn", "AreCarLightsOn", "SetCarLightsOn", "ToggleHeadlights" },
    { "top", "GetCarTopLightVariable", "CarTopLightOnOff", "SetCarTopLightVariable", "ToggleInteriorLight" },
    { "wipers", "GetWipersOnOffVariable", "WipersOn", "SetWipersOnOffVariable", "ToggleWiperBlades" },
    -- the radio too (probe cmds/radio-probe.lua): its on / off is the manager's, the music manager plays it from the
    -- radio part of the manager's car (the twin while the player sits in it); the toggle is the radio part's own
    -- ToggleRadio (its button), the setter skips the radio's quirks
    { "radio", "GetCarRadioOnOffState", "CarState_Radio", function(m, on) m:SetCarRadioOnOffState(on, true) end,
        function(car) local r = Twin.radioOf(car) if r then r:ToggleRadio() end end },
}
TD.LTW_HOLD_MS = 2500 -- (the owner's toggle takes ~1 s, then its C / G lines come)
function TD.readLtw(m)
    local t = {}
    for _, d in ipairs(TD.LTW) do
        local out = {}
        local ok = m and pcall(function() m[d[2]](m, out) end)
        t[d[1]] = (ok and out[d[3]] ~= nil) and (out[d[3]] and 1 or 0) or -1
    end
    return t
end
-- "ltw" on the lines: one digit per TD.LTW entry, in its order (an older line without the radio: radio unknown, -1)
function TD.fmtLtw(t)
    local o = {}
    for _, d in ipairs(TD.LTW) do
        local v = t[d[1]]
        if not v or v < 0 then return "-" end
        o[#o + 1] = tostring(v)
    end
    return table.concat(o)
end
function TD.parseLtw(s)
    s = s or ""
    if not s:match("^[01][01][01][01]?$") then return nil end
    local t = {}
    for i, d in ipairs(TD.LTW) do t[d[1]] = tonumber(s:sub(i, i)) or -1 end
    return t
end
-- this side's own car's, for its C / G line ("-" unknown): the manager's, or what it held before the player sat in
-- the other's twin
function TD.ownLtw()
    local t = inGhost and inGhost.savedCtl and inGhost.savedCtl.ltw
    if not t then
        local now = M.nowMs()
        if not TD.ltwCache or now - TD.ltwCache.ms > 100 then
            TD.ltwCache = { ms = now, v = TD.readLtw((CoopSyncFirst or FindFirstOf)("BP_CarManager_C")) }
        end
        t = TD.ltwCache.v
    end
    return TD.fmtLtw(t)
end
function TD.ltwDef(what) for _, d in ipairs(TD.LTW) do if d[1] == what then return d end end end
-- the manager's state without animation (entering / leaving a twin, following its owner)
function TD.setLtw(m, what, v)
    local d = TD.ltwDef(what)
    return d and pcall(function() if type(d[4]) == "function" then d[4](m, v == 1) else m[d[4]](m, v == 1) end end)
end
-- the owner's real car: the game's own toggle when it differs (the other player worked the lever in its twin)
function TD.toggleLtw(car, what, v)
    local d = TD.ltwDef(what)
    if not d then return false end
    if inGhost and inGhost.savedCtl and inGhost.savedCtl.ltw then
        -- (this side's player sits in the other's twin: the manager holds that car's state - the own car's later)
        inGhost.savedCtl.ltw[what] = v
        return true
    end
    TD.ownCtxFor(car)
    local cur = TD.readLtw((CoopSyncFirst or FindFirstOf)("BP_CarManager_C"))[what]
    if cur == v then return true end
    return pcall(function() if type(d[5]) == "function" then d[5](car) else car[d[5]](car) end end)
end

local function setWalking(pawn, on)
    pcall(function()
        local cm = pawn.CharacterMovement
        if on then cm:SetMovementMode(1, 0) else cm:DisableMovement() end -- 1 = walking
    end)
    pcall(function() pawn:SetActorEnableCollision(on) end)
end

-- The seat behind a door (car-local door position, SEAT_DOOR) is taken by the other player in car <tag>: its P line.
local function seatTakenByOther(tag, n)
    local o = target.player
    return o ~= nil and not st.playerGone and o.tag == tag and o.seat == n
end
local function doorSeat(x, y)
    if x < -100 then return nil end -- the trunk lid
    return (x > 70 and 1 or 3) + (y > 0 and 1 or 0)
end

-- Get into the other player's car (its twin or ghost) at the nearest door within reach; nil when none is near.
local GHOST_DOOR_REACH = 250
-- the other's car (twin / ghost) and its door within reach of the character: g, tag, n
function TD.nearGhostDoor(pawn)
    local tag = otherTag()
    local g = ghostOf(tag)
    if not g then return nil end
    local p = pawn:K2_GetActorLocation()
    local best, bd
    for n, door in pairs(SEAT_DOOR) do
        local w = toWorld(g, { X = door.X, Y = door.Y, Z = 0 })
        local d = math.sqrt((w.X - p.X) ^ 2 + (w.Y - p.Y) ^ 2)
        if d < GHOST_DOOR_REACH and (not bd or d < bd) then best, bd = n, d end
    end
    if not best then return nil end
    return g, tag, best
end

-- The doors of the other's twin work like the own car's (owner's ask): E tapped at a door whose seat is free opens it
-- and the character gets in with the game's entry animation; E held (TD.HOLD_MS, the game's own hold) or tapped at a
-- taken seat - the driver's (never for the other player), the other player's, a device's (the owner's C / G lines
-- say which) - only opens / shuts the door. The door itself is the owner's: DR asks it to move its real door, the
-- pose brings the door back to the twin (the twin is kinematic: its own doors do not move).
--   DR <time> <door 1-5> open|shut|toggle      to the owner of the car
TD.HOLD_MS = 400
TD.ENTRY_STEP_MS, TD.ENTRY_SHUT_MS = 200, 1450 -- the game's: CommandEnterCar 0.2 s after StartEntry, door shut at ~1.45 s
TD.EXIT_SHUT_MS = 1200 -- getting out: the door open this long (the character stands outside it at once)
TD.doorPress = nil -- { tag, n, ms }: E went down at a door of the other's twin
TD.drLog = {} -- the last door lines sent / done: "s|d<ms>:<door>:<op>" (tests)
function TD.logDoor(kind, n, op)
    TD.drLog[#TD.drLog + 1] = string.format("%s%d:%s:%s", kind, M.nowMs() % 100000, tostring(n), tostring(op))
    if #TD.drLog > 40 then table.remove(TD.drLog, 1) end
end
function TD.sendDoor(n, op)
    TD.logDoor("s", n, op)
    if op == "shut" then TD.shutSentMs = TD.shutSentMs or {} TD.shutSentMs[n] = M.nowMs() end
    append(outFile, string.format("DR\t%d\t%d\t%s", M.nowMs(), n, op))
    st.doorsSent = (st.doorsSent or 0) + 1
    st.lastDoorSent = n .. ":" .. op
    if op == "open" then TD.openSentMs[n] = M.nowMs() end
end
TD.openSentMs = {} -- door -> when its last "open" went out
function TD.seatFreeForMe(tag, n)
    -- (the trunk lid: no seat behind it - a tap only opens / shuts it; owner, alpha 16: the guest could not shut the
    -- host's trunk - the tap tried to get in there and failed before the toggle was sent)
    if not SEAT_DOOR[n] then return false, "trunk" end
    if seatTakenByOther(tag, n) then return false, "player" end
    local busy = tag == "H" and target.busyH or target.busyG
    if busy and busy:find(tostring(n), 1, true) then return false, "device" end
    return true
end
-- The car's seat socket moved to seat n before the entry: the game's entry animation ends at the socket
-- (socket = seat - sockDelta; seat 1: the socket at its home)
function TD.aimSeatSocket(g, n)
    local sock = g.TempSocket_Seat
    if not (sock and sock:IsValid()) then return false end
    local want = seatRel(n)
    pcall(function() sock:K2_SetRelativeLocation({ X = want.X - sockDelta.X, Y = want.Y - sockDelta.Y, Z = want.Z - sockDelta.Z }, false, {}, true) end)
    return true
end
-- (no door on that side - taken off: owner's alpha 20 test, the guest could not get onto a back seat then - the
-- player gets in through the empty doorway: the car the game's context, the seat socket at seat n, CommandEnterCar
-- without a door)
-- (a slot's EmptyDoor - the door taken off - is no door: in through the doorway)
function TD.realDoor(car, n)
    local d = car and Twin.door(car, n)
    if d and d:GetClass():GetFName():ToString() == "BP_CarPart_EmptyDoor_C" then return nil end
    return d
end
function TD.twinEnter(pawn, g, tag, n)
    local door = TD.realDoor(g, n)
    TD.aimSeatSocket(g, n)
    if door then
        if not Twin.startEntry(g, door) then return false end
        TD.sendDoor(n, "open")
    else
        if not Twin.startEntry(g, nil) then return false end
        st.doorlessEntries = (st.doorlessEntries or 0) + 1
    end
    local now = M.nowMs()
    -- (no door: the walk in by the slot's EmptyDoor - it has the entry points; CommandEnterCar with no door at all made the
    -- game take the car's driver's door off - the OWN car's, backseat-test 2026-11-11)
    local empty = not door and Twin.door(g, n)
    inGhost = { tag = tag, seat = nil, pending = false, entry = { X = SEAT_DOOR[n].X, Y = SEAT_DOOR[n].Y }, twin = true, since = now,
        aimed = n, door = door and n or nil, doorPath = door and Sync.ref(door) or nil, emptyPath = empty and Sync.ref(empty) or nil,
        enterAt = now + TD.ENTRY_STEP_MS, native = TD.native or nil }
    if tag == "H" then myAssigned, seatPending = nil, false end
    st.ghostBoarded = (st.ghostBoarded or 0) + 1
    return true
end
-- The own car's back seats (owner, alpha 18 item 10: "let the host sit on the passenger seat of its own car"): the game
-- gets in by the driver's door only - a tap at a back door whose seat is free gets the player in there with the game's
-- own entry, the seat socket moved there first (as for the other's car, TD.twinEnter). TD.ownSeat = { n, since }
-- while it sits there: the seat logic seats it there, wheelFrame keeps its pedals / wheel off the car.
TD.ownSeat = nil
function TD.ownEnter(pawn, n)
    local own = Twin.ownCar()
    local door = own and TD.realDoor(own, n)
    local function no(why) st.ownEnter = n .. ":" .. why return false end
    if not own then return no("no_car") end
    if Sync.parentOf(pawn) then return no("in_a_car") end
    if seatTakenByOther(myTag(), n) then return no("player") end
    if seatDevice(own, n) then return no("device") end
    if TD.native then pcall(Native.use, own) end
    TD.aimSeatSocket(own, n)
    -- (no door there: in through the empty doorway - TD.twinEnter)
    if door and not pcall(function() door:StartEntry(true) end) then TD.aimSeatSocket(own, 1) return no("entry_failed") end
    st.ownEnter = n .. (door and ":started" or ":started_doorless")
    local now = M.nowMs()
    local empty = not door and Twin.door(own, n) -- (the doorway's EmptyDoor: the walk in by it - TD.twinEnter)
    TD.ownSeat = { n = n, since = now, door = door and Sync.ref(door) or nil, empty = empty and Sync.ref(empty) or nil, enterAt = now + TD.ENTRY_STEP_MS, shutAt = door and (now + TD.ENTRY_SHUT_MS) or nil }
    st.ownBackEntries = (st.ownBackEntries or 0) + 1
    return true
end
-- the own car's back door the player aims at (3 / 4), else nil
function TD.ownBackDoorAimed()
    local own = Twin.ownCar()
    local hm = own and (CoopSyncFirst or FindFirstOf)("BP_HighlightManager_C")
    local h = hm and hm:IsValid() and hm.CurrentHighlight
    local o = h and h:IsValid() and h:GetOwner()
    if not (o and o:IsValid()) then return nil end
    local car = Native and Native.carOf(o)
    if not (car and car:GetAddress() == own:GetAddress()) then return nil end
    local n = TD.doorOfHighlight(own, h, o)
    return (n == 3 or n == 4) and n or nil
end
function TD.twinDoorTap(pawn, press)
    if press.own then TD.ownEnter(pawn, press.n) return end
    local g = ghostOf(press.tag)
    if not (g and Twin.isTwin(g)) then return end
    local free, why = TD.seatFreeForMe(press.tag, press.n)
    if free and TD.twinEnter(pawn, g, press.tag, press.n) then return end
    if not free then st.ghostDoorTaken = (st.ghostDoorTaken or 0) + 1 st.lastDoorTaken = press.n .. ":" .. why end
    if TD.native then return end -- (the game's own tap moved the door: TD.nativeDoorWatch sends it)
    TD.sendDoor(press.n, "toggle")
end
-- Native cars (owner, after alpha 17: "the game's own interactions, the cars only shared"; nativecar.lua): the game's
-- "one car" (manager, input controller, the manager's delegate bindings, its door flags) is the context car - the car
-- the local player sits in; on foot the car whose part it aims at (switched while it aims, before the E: then the game's
-- own E works there - its door, the walk in, the seat), the own car again once it aims at it or walks away from the
-- other's. Getting into / out of the other's car, its key, levers, horn, pedals: the game's own.
TD.native = false
TD.SWEEP_MS = 10000
TD.NATIVE_LET_GO_MS = 2000
TD.DR_CTX_MS = 2500 -- the own car stays the context this long after the other player worked one of its doors -- the other's car not aimed at this long: the own car is the context again
TD.aimed = nil -- { n = door } of the other's car the player last aimed at (its seat is taken on getting in)
local DOOR_OF_ENUM = { [0] = 1, [1] = 2, [2] = 3, [3] = 4, [5] = 5 } -- the manager's door enum -> door number
-- the other's car's door n the highlight is on (its door actor, the door slot's spot, the body's EnterDoor), else nil
function TD.aimNative(tw, h)
    local o = h:GetOwner()
    local n
    for k = 1, 5 do local d = Twin.door(tw, k) if d and o and d:GetAddress() == o:GetAddress() then n = k end end
    if not n and o and o:GetClass():GetFName():ToString() == "BP_CarPart_Interactive_C" then
        local key = o:GetAddress()
        if TD.catSlot[key] == nil then
            local out, slot = {}, ""
            if pcall(function() o:GetSlotComponent(out) end) then
                local sc = out.SlotSceneComponent
                slot = sc and sc:IsValid() and sc.SlotName.TagName:ToString() or ""
            end
            TD.catSlot[key] = ({ ["Car.Equip.Body.DoorsFL"] = 1, ["Car.Equip.Body.DoorsFR"] = 2, ["Car.Equip.Body.DoorsRL"] = 3, ["Car.Equip.Body.DoorsRR"] = 4, ["Car.Equip.Body.DoorsTrunk"] = 5 })[slot] or false
        end
        n = TD.catSlot[key] or nil
    end
    if not n and h:GetFName():ToString() == "Highlight_EnterDoor" then n = 1 end
    -- (something else of the car lit - its trunk box: no door aimed. The lid tapped before stayed "aimed", and the box's E
    -- changing the manager's trunk flag went to the owner as the player's shut - owner's two-games test 2026-11-11: the
    -- lid shut on the guest at the box's E and kept slamming; trunk-test)
    if not n then TD.aimed = nil return end
    if not (TD.aimed and TD.aimed.n == n) then
        TD.aimed = { n = n }
        -- (the game walks the player to the car's one seat socket: moved to the seat behind this door first)
        if SEAT_DOOR[n] then TD.aimSeatSocket(tw, n) end
    end
end
-- The other's car is the context: the manager's door flags are its. Its doors are its owner's (the pose moves them;
-- its door actors stay off the manager's OnDoorChanged: Native.stayParked) - so
--   * a flag the game changed here (the player opened / shut a door from outside, the entry, the exit) goes to the
--     owner as DR, whose pose brings the door back; that door's flag is left alone TD.DOOR_HOLD_MS meanwhile;
--   * else the flags follow the owner's doors (its pose) - the door spots show / hide by them (a flag left "open"
--     after the owner's door had swung shut hid the driver's door spot for good: no way in, cars-test).
TD.DOOR_HOLD_MS = 1500
TD.DOOR_E_MS = 2500 -- a door flag changed this long after the player's E is the player's
function TD.nativeDoorWatch(tw)
    local m = Native.manager()
    local cur = m and m.NewCarActor
    if not (tw and cur and cur:IsValid() and cur:GetAddress() == tw:GetAddress()) then TD.nativeDoors = nil return end
    local now, t = TD.readDoorStates(m), M.nowMs()
    local ctx = Native.ctx
    if not TD.nativeDoors or TD.nativeDoors.ctx ~= ctx then TD.nativeDoors = { ctx = ctx, s = now, hold = {} } return end
    local base = TD.nativeDoors
    -- (only the player's own doing goes out - an E within TD.DOOR_E_MS (getting in / out too): the flags written to
    -- follow the pose woke the car's own door logic, whose flag changes came back as "the player's" - the guest's game
    -- sent the host DR 1 open / shut while the guest only stood there, and the host drove off with the door open: it
    -- broke off, cars-test)
    local mine = t - (TD.lastInteractMs or -1e9) < TD.DOOR_E_MS
    for k, v in pairs(now) do
        local n = DOOR_OF_ENUM[k]
        -- (a passenger's exit works the driver's door here: the owner's car opens the passenger's)
        -- (and its shut, after the player let go: TD.passengerExit for a few seconds)
        local pn = TD.seatNow and TD.seatNow.n or (TD.passengerExit and t < TD.passengerExit.untilMs and TD.passengerExit.n)
        local raw = n
        if n == 1 and pn and pn ~= 1 and SEAT_DOOR[pn] then n = pn end
        -- (only the door the player works: aimed at, sat behind, got out by - a switch of the context changed other
        -- flags at once, and the host opened its door 3 and trunk as the guest took its wheel; cars-test)
        local focus = raw == (TD.aimed and TD.aimed.n) or raw == 1 and pn or raw == pn
        if n and mine and focus and base.s[k] ~= nil and base.s[k] ~= v then
            TD.sendDoor(n, v and "open" or "shut")
            st.lastNativeDoor = n .. (v and "open" or "shut")
            base.hold[k] = t + TD.DOOR_HOLD_MS
            st.nativeDoorsSent = (st.nativeDoorsSent or 0) + 1
        end
    end
    local ok, pose = pcall(Native.realDoors, tw)
    if ok and pose then
        for k, v in pairs(pose) do
            if now[k] ~= nil and now[k] ~= v and (base.hold[k] or 0) < t then
                if pcall(function() m:SetDoorState(k, v) end) then now[k] = v st.doorFlagsFollowed = (st.doorFlagsFollowed or 0) + 1 end
            end
        end
    end
    base.s = now
end
-- The other's twin's doors the game opened on this side (the entry, the exit, a tap) simulate here: while one does, its
-- owner's pose leaves it alone (Twin.doorLocal); the owner's door shut (its pose) and this one still open for
-- TD.DOOR_LOCAL_MS: the game's own shut here - then the pose has it again. (A door opened here stayed open for good:
-- the pose cannot move a simulating door; cars-test.)
TD.DOOR_LOCAL_MS = 1500 -- (2500 and a game's shut first: the guest saw the host's door it got in by swing and try to
                         -- slam several times before it stood shut, owner's alpha 18 item 17)
-- A door opened here because its owner's was (below) waits only TD.OWNER_SHUT_MS after the owner's pose shows it shut
-- (1.5 s too: the host's trunk shut 0.3 s on the host, 2.4 s later on the guest - owner's alpha 18 item 30, "late");
-- the wait is for a door this side opened itself, whose owner's pose comes later. Either way the door eases shut from
-- where it hangs (Twin.shutEase), no snap.
TD.OWNER_SHUT_MS = 250
TD.doorLocalSince, TD.doorShutTried, TD.openedForOwner = {}, {}, {}
function TD.ownerDoorOpen(n)
    local s = target.pose
    if not s then return false end
    local p, yw = s:match("D" .. n .. "%.MainMesh=[^,]+,[^,]+,[^,]+,([^,]+),([^,]+),") -- (not "s and s:match": one value)
    if not p then return false end
    return math.max(math.abs(tonumber(p) or 0), math.abs(tonumber(yw) or 0)) > 20
end
TD.doorSimPrev, TD.doorShutHere, TD.ownerOpenSince = {}, {}, {}
TD.OWNER_OPEN_MS = 600
TD.EXIT_DOOR_MS = 400
-- (and the hood, door 6: the twin's hood was found simulating with no one at it - fallen off its place, hanging in the air
-- by the car and moving with it on both sides (owner's alpha 19 item 8, alpha 18 item 9: "a hood floats in front of the
-- car"; live pair 2026-11-04: the guest's twin hood 340 in front, the host's 380 behind). It is put back like a door the
-- game opened here; the owner's open hood comes by its pose, so it is never opened here for the owner.)
function TD.twinDoorReconcile(tw)
    local now = M.nowMs()
    for n = 1, 6 do
        local sim = Twin.doorOpen(tw, n)
        if TD.doorSimPrev[n] and not sim then TD.doorShutHere[n] = now end -- (shut here: the owner's shut is on its way)
        TD.doorSimPrev[n] = sim
        -- (the owner's door open and this one not: the game's own open here too - a posed open door is no door for the
        -- game: no highlight, no shut; ghostseat. Not right after it was shut here: the owner's pose lags.)
        -- (the owner's door open for TD.OWNER_OPEN_MS first: a lid swinging on the road read as opened for a frame, the
        -- game opened and shut it here again and again - the guest heard the trunk shut over and over, alpha 18 item 29)
        local ownerOpen = TD.ownerDoorOpen(n)
        if ownerOpen then TD.ownerOpenSince[n] = TD.ownerOpenSince[n] or now else TD.ownerOpenSince[n] = nil end
        ownerOpen = ownerOpen and now - TD.ownerOpenSince[n] >= TD.OWNER_OPEN_MS
        if n < 6 and not sim and ownerOpen and now - (TD.doorShutHere[n] or -1e9) > TD.DOOR_LOCAL_MS then
            local d = Twin.door(tw, n)
            if d then
                -- (the flag first back to shut: it follows the pose, and a door "open" by its flag does not open)
                local m = Native.manager()
                local cur = m and m.NewCarActor
                -- (only while the other's car is the context: the door writes the manager's flag - the own car's else)
                if cur and cur:IsValid() and cur:GetAddress() == tw:GetAddress() then
                    for k, dn in pairs(DOOR_OF_ENUM) do if dn == n then pcall(function() m:SetDoorState(k, false) end) end end
                    pcall(function() d:AttemptOpen() end)
                    TD.openedForOwner[n] = true
                    TD.doorShutHere[n] = now
                    st.twinDoorsOpenedHere = (st.twinDoorsOpenedHere or 0) + 1
                end
            end
        end
        if sim then
            Twin.doorLocal[n] = true
            if TD.ownerDoorOpen(n) then TD.doorLocalSince[n] = nil
            else
                TD.doorLocalSince[n] = TD.doorLocalSince[n] or now
                -- (a passenger's way out: the game's exit opens the driver's door here (its animation's door), the owner
                -- opens the passenger's - both stood open on this side; owner's alpha 19 item 13: the driver's door
                -- back shut TD.EXIT_DOOR_MS after it started opening (shut at once: no walk-out, the player jumped out;
                -- once the game let go of the player: it stood wide open ~1 s; cars-test))
                local pn = TD.seatNow and TD.seatNow.n or (TD.passengerExit and now < TD.passengerExit.untilMs and TD.passengerExit.n)
                local exitDoor = n == 1 and pn and pn ~= 1 and not TD.ownerDoorOpen(1) and now - TD.doorLocalSince[n] >= TD.EXIT_DOOR_MS
                if exitDoor then st.exitDoorsShut = (st.exitDoorsShut or 0) + 1 end
                -- (this side shut it - the entry's shut, the player's E: sent to the owner - and the owner's pose has it shut:
                -- eased shut now, not after TD.DOOR_LOCAL_MS; owner's two-games test 2026-11-11: "the back door does not
                -- shut the first time, it tries, stays open, then shuts")
                local mineShut = now - ((TD.shutSentMs or {})[n] or -1e9) < 4000
                if exitDoor or now - TD.doorLocalSince[n] > ((TD.openedForOwner[n] or mineShut) and TD.OWNER_SHUT_MS or TD.DOOR_LOCAL_MS) then
                    -- (the game's shut first; on the kinematic twin it does not close the door (cars-test: 128 tries, still
                    -- open) - then the door stops simulating and its owner's pose has it again)
                    local d = Twin.door(tw, n)
                    local m = Native.manager()
                    local ctxTw = m and m.NewCarActor and m.NewCarActor:IsValid() and m.NewCarActor:GetAddress() == tw:GetAddress()
                    -- (the game's shut only while the other's car is the context: the door writes the manager's flag)
                    -- (only while this side drives the twin - it simulates then; on the kinematic twin straight to the pose)
                    if d and ctxTw and TD.driving == otherTag() and not TD.doorShutTried[n] then pcall(function() d:AttemptShut() end) TD.doorShutTried[n] = true
                    elseif d then
                        -- (a mesh that simulated is detached from its door: back onto the door's root where it hangs, then
                        -- eased shut - its place there; left alone it hung in the air where it stopped, cars-test)
                        pcall(function()
                            local mesh = d.MainMesh
                            mesh:SetSimulatePhysics(false)
                            mesh:K2_AttachToComponent(d.RootComponent, FName("None"), 1, 1, 1, true)
                        end)
                        Twin.forgetDoorPose(tw, n)
                        pcall(Twin.shutEase, tw, n, mineShut and 1.5 or nil)
                        st.twinDoorsPosed = (st.twinDoorsPosed or 0) + 1
                    end
                    TD.doorLocalSince[n] = now
                    st.twinDoorsShutHere = (st.twinDoorsShutHere or 0) + 1
                end
            end
        else
            Twin.doorLocal[n] = nil
            TD.doorLocalSince[n] = nil
            TD.doorShutTried[n] = nil
            TD.openedForOwner[n] = nil
        end
    end
end
function TD.nativeTick()
    if not TD.native or garage or M.stopped or not Native then return end
    local pawn = localPawn()
    if not pawn then return end
    local own, tw = Twin.ownCar(), ghostOf(otherTag())
    if tw and not Twin.isTwin(tw) then tw = nil end
    local par = Sync.parentOf(pawn)
    local parCar = par and Native.carOf(par)
    local want
    if inGhost then want = tw -- (in the other's car, getting in / out included)
    elseif parCar then want = parCar
    else
        local hm = (CoopSyncFirst or FindFirstOf)("BP_HighlightManager_C")
        local h = hm and hm.CurrentHighlight
        local car = h and h:IsValid() and Native.carOf(h:GetOwner())
        if car then
            want = car
            if tw and car:GetAddress() == tw:GetAddress() then TD.aimNative(tw, h) TD.twinAimMs = M.nowMs() else TD.aimed = nil end
        -- (or a door of it the other player works: DR - not over the player's own aim at the other's car: its E there
        -- needs that car the context; the host's way in at the guest's wheel did nothing, cars 8b)
        elseif own and (M.nowMs() - (TD.twinAimMs or -1e9) > TD.NATIVE_LET_GO_MS or M.nowMs() < (TD.ownCtxUntil or 0)) then
            -- (nothing of the other's car aimed at for a while: the own car again - the other's car as the context shows the
            -- manager's state, the own car's: its wipers stood still while its owner's swept, twin-ctl)
            want = own
            TD.aimed = nil
        end
    end
    if want and Native.use(want) then
        st.ctxSwitches = (st.ctxSwitches or 0) + 1
        if CoopSyncHitch and Native.stats.lastMs > 5 then CoopSyncHitch.op("players ctx_switch", Native.stats.lastMs) end
    end
    TD.nativeDoorWatch(tw)
    pcall(TD.ownDoorFlags, own)
    local now = M.nowMs()
    if tw and now - (TD.reconcileAt or 0) >= 100 then TD.reconcileAt = now pcall(TD.twinDoorReconcile, tw) end
end
-- The way out of a seat (owner, alpha 17: "getting out of the passenger seat must need aiming at the door + E, now E
-- anywhere teleports"): the game's exit is its ExitDoor highlight (UICollision_ExitHandle / 2, by the driver's door) and
-- the exit's points (ExitPoint, ExitCheckPoints with the capsules where the player stands after); the door the exit
-- opens is the one it got in by (the character's CarEntryTransitionPoint). For a player on seat n they are moved to
-- that seat's door (mirrored for the right side: ExitCheckPoints turned round) - looking at the own door + E gets out
-- through it, the game's own animation.
TD.BACK_DOOR_MID = 40 -- a back door's middle this far behind its hinge (its highlight box: -72..8 for the hinge at 8)
TD.EXIT_COMPS = { "UICollision_ExitHandle", "UICollision_ExitHandle2", "ExitPoint", "TempExitLocation", "TempExitLocation_StartTrace" }
TD.exitHome = {} -- car path -> { comp name -> its relative location as built }
TD.exitSeat = {} -- car path -> the seat its exit is placed for
function TD.placeExit(car, n)
    local key = Sync.ref(car)
    if TD.exitSeat[key] == n or not SEAT_DOOR[n] then return end
    local home = TD.exitHome[key]
    if not home then
        home = {}
        for _, name in ipairs(TD.EXIT_COMPS) do
            local c = car[name]
            if c and c:IsValid() then local r = c.RelativeLocation home[name] = { X = r.X, Y = r.Y, Z = r.Z } end
        end
        TD.exitHome[key] = home
    end
    local dx, right = SEAT_DOOR[n].X - SEAT_DOOR[1].X, SEAT_DOOR[n].Y > 0
    -- (the handles - the highlight's boxes - on the back door's middle: moved hinge to hinge they stood at its back edge,
    -- X -96..-34 against the door's -72..8, so only a look straight to the side lit it - owner's two-games test
    -- 2026-11-14, "the back door is lit only looking right at it". The door's own highlight box is centred 40 behind its
    -- hinge; the exit's points keep the hinge-to-hinge move: the player stands out where the driver would)
    local hx = home.UICollision_ExitHandle and home.UICollision_ExitHandle.X
    local hdx = (n >= 3 and hx) and (SEAT_DOOR[n].X - TD.BACK_DOOR_MID - hx) or dx
    for name, r in pairs(home) do
        local c = car[name]
        if c and c:IsValid() then
            local mx = name:find("^UICollision_") and hdx or dx
            pcall(function() c:K2_SetRelativeLocation({ X = r.X + mx, Y = right and -r.Y or r.Y, Z = r.Z }, false, {}, true) end)
        end
    end
    -- (the spot the player is put at: ExitCheckPoints' TempExitLocation (and its trace start) - moved itself, mirrored
    -- for the right side. The check points turned round instead put it right in the world, yet the game took the
    -- spot's own relative place: out by the right back door the player stood on the left - owner's two-games test
    -- 2026-11-11, garage-seat-test. Their parent stays where it was built.)
    local cp = car.ExitCheckPoints
    if cp and cp:IsValid() then
        pcall(function() cp:K2_SetRelativeLocationAndRotation({ X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 }, false, {}, true) end)
    end
    -- (the exit's outline: Highlight_ExitDoor draws its HighlightVisuals - the driver door's DoorInteriorHighlightMesh
    -- - wherever its collision is; a passenger getting out saw the DRIVER's door lit, owner's alpha 18 items 13 / 19:
    -- the seat's own door mesh instead, the car's own back for the driver)
    pcall(function()
        local h = car.Highlight_ExitDoor
        local vis = h.HighlightVisuals
        TD.exitVisHome = TD.exitVisHome or {}
        if not TD.exitVisHome[key] then
            local l = {}
            for i = 1, vis:GetArrayNum() do l[#l + 1] = vis[i] end
            TD.exitVisHome[key] = l
        end
        local want = TD.exitVisHome[key]
        local door = n ~= 1 and Twin.door(car, n)
        if door and door.MainMesh and door.MainMesh:IsValid() then want = { door.MainMesh } end
        vis:Empty()
        for i, v in ipairs(want) do vis[i] = v end
        st.exitOutline = n
    end)
    TD.exitSeat[key] = n
    st.exitPlaced = (st.exitPlaced or 0) + 1
end

-- The driver's side simulates the car (native cars): the local player at the wheel of the other's car drives this side's
-- copy of it with the game's own input and physics (its twin simulates, Twin.setDriven), and its pose goes to the car's
-- owner, whose real car is kinematic meanwhile and follows it; getting off the wheel gives it back at its velocity.
--   DV <time> <tag> 1                         the sender drives car <tag> (H / G) from now on
--   DV <time> <tag> 0 <xform> <vx> <vy> <vz>  ... no more: the car is there at that velocity
--   VD <time> <tag> <xform>                   where the car the sender drives is (V: the pose line)
TD.driving = nil  -- tag of the other's car this side drives
TD.drivenBy = nil -- true: the other player drives this side's own car
function TD.ownCarActor() return (role == "host" and localCar()) or Twin.ownCar() end
function TD.startDriving(tag)
    local g = ghostOf(tag)
    if not (g and Twin.isTwin(g)) then return end
    local tgt = tag == "H" and target.car or target.otherCar
    Twin.setDriven(g, true, tgt and tgt.vel or nil)
    TD.driving = tag
    append(outFile, string.format("DV\t%d\t%s\t1", M.nowMs(), tag))
    st.driveTaken = (st.driveTaken or 0) + 1
end
function TD.stopDriving()
    local tag = TD.driving
    TD.driving = nil
    if not tag then return end
    local g = ghostOf(tag)
    if g and Twin.isTwin(g) then
        local v = g:GetVelocity()
        append(outFile, string.format("DV\t%d\t%s\t0\t%s\t%.1f\t%.1f\t%.1f", M.nowMs(), tag, xform(g), v.X, v.Y, v.Z))
        Twin.setDriven(g, false)
    else
        append(outFile, string.format("DV\t%d\t%s\t0", M.nowMs(), tag))
    end
    -- (the owner's stream again from here: no old samples to interpolate across)
    TD.carHist[tag == "H" and "car" or "otherCar"] = {}
    st.driveGiven = (st.driveGiven or 0) + 1
end
-- a DV line for this side's own car
function TD.onDrive(t)
    if t[3] ~= myTag() then return end
    local own = TD.ownCarActor()
    if not own then return end
    if t[4] == "1" then
        TD.drivenBy = true
        TD.carHist.drv, target.drv = {}, nil
        Twin.setDriven(own, false)
    else
        TD.drivenBy = nil
        local vel
        if t[11] then
            local loc = { X = tonumber(t[5]), Y = tonumber(t[6]), Z = tonumber(t[7]) } -- (xform: parse is declared below)
            local rot = { Pitch = tonumber(t[8]), Yaw = tonumber(t[9]), Roll = tonumber(t[10]) }
            pcall(function() own:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end)
            vel = { X = tonumber(t[11]) or 0, Y = tonumber(t[12]) or 0, Z = tonumber(t[13]) or 0 }
        end
        -- (no parking brake set here: the game does not park a car its driver leaves either - in drive with the engine on
        -- it creeps away, ~2.7 m/s, own car or the other's alike; a driver shifts to park first)
        Twin.setDriven(own, true, vel)
        target.drv = nil
    end
    st.driveLines = (st.driveLines or 0) + 1
end

-- The door the game's exit opens is the one the character got in by (its CarEntryTransitionPoint: that door's
-- EntranceLogicPoint). Put in by a teleport (the arrival, a test) there is none and "Exit Car" looks one up - the
-- other's twin's door (a twin is the newer car); the old mod redirected that (TD.onDoorCall), with the twin's own door
-- handlers live the exit completed twice and the own door broke off (cars-test, native). Seated: the point of the
-- seat's door of the car the player sits in.
TD.entryPoints = {} -- door actor path -> its EntranceLogicPoint component path
local SCENE_CLS
function TD.seatEntryPoint(pawn, car, n)
    local door = Twin.door(car, n)
    if not door then return end
    local dp = Sync.ref(door)
    local ep = TD.entryPoints[dp]
    local comp = ep and Sync.deref(ep)
    if not comp then
        SCENE_CLS = SCENE_CLS or StaticFindObject("/Script/Engine.SceneComponent")
        local comps = door:K2_GetComponentsByClass(SCENE_CLS)
        for i = 1, #comps do
            local c = comps[i]:get()
            if c:IsValid() and c:GetFName():ToString():find("^EntranceLogicPoint") then comp = c break end
        end
        if not comp then return end
        TD.entryPoints[dp] = Sync.ref(comp)
    end
    local cur = pawn.CarEntryTransitionPoint
    if not (cur and cur:IsValid() and cur:GetAddress() == comp:GetAddress()) then
        pawn.CarEntryTransitionPoint = comp
        st.entryPointSet = (st.entryPointSet or 0) + 1
    end
end

-- The car manager finds a car's part by its slot tag (GetItemSlotFromSlotTag: "Exit Car" takes the door to open
-- through GetItemManifestationEquippedInSlot -> here) - and answers the slot of the car spawned last, the other's twin
-- (traced 2026-10-30: the host's exit opened the guest twin's driver door, its own door got the manager's flag and broke
-- off). A hook after it answers the context car's slot of that tag (native cars), as GetGearboxActor's does.
TD.slotOf = {} -- car path .. "|" .. tag -> its SlotSceneComponent path
-- A passenger: the game's exit asks for the driver's door (DoorsFL) - answered with the door of the seat the player sits
-- on in that car (TD.seatNow: sendTick), so the game's exit opens that door (owner, alpha 17 item 12).
local SEAT_SLOT = { "Car.Equip.Body.DoorsFL", "Car.Equip.Body.DoorsFR", "Car.Equip.Body.DoorsRL", "Car.Equip.Body.DoorsRR" }
function TD.contextSlot(tag, cur)
    if not TD.native or M.stopped or not Native then return nil end
    local m = Native.manager()
    local car = m and m.NewCarActor
    if not (car and car:IsValid()) then return nil end
    local sn = TD.seatNow
    -- (tried: the passenger's own door slot - the game's exit through a back door is a jump, its animation only works
    -- by the driver's door; so the exit keeps that door, its points stand at the passenger's door (TD.placeExit), and
    -- the owner gets the passenger's door: TD.nativeDoorWatch)
    if cur and cur:IsValid() and Native.carOf(cur) and Native.carOf(cur):GetAddress() == car:GetAddress() then return nil end
    local key = Sync.ref(car) .. "|" .. tag
    local c = TD.slotOf[key] and Sync.deref(TD.slotOf[key])
    if c then return c end
    local comps = car:K2_GetComponentsByClass(SSC_CLASS)
    for i = 1, #comps do
        local x = comps[i]:get()
        if x:IsValid() and x.SlotName.TagName:ToString() == tag then TD.slotOf[key] = Sync.ref(x) return x end
    end
    return nil
end
function TD.hookSlotLookup()
    CoopSyncSlotHook = CoopSyncSlotHook or { fixed = 0 }
    CoopSyncSlotHook.on = TD.contextSlot
    if CoopSyncSlotHook.done then return end
    local m = (CoopSyncFirst or FindFirstOf)("BP_CarManager_C")
    local cls = m and m:IsValid() and m:GetClass():GetFullName():gsub("^%S+%s+", "")
    if not cls then return end
    CoopSyncSlotHook.done = true
    Hook(cls .. ":GetItemSlotFromSlotTag", function(self, slot, valid, comp)
        local f = CoopSyncSlotHook.on
        if not f then return end
        pcall(function()
            local want = f(slot:get().TagName:ToString(), comp:get())
            if want then comp:set(want) valid:set(true) CoopSyncSlotHook.fixed = CoopSyncSlotHook.fixed + 1 end
        end)
    end)
end

-- the door n of car a highlight belongs to (its door actor, the door slot's spot, the body's EnterDoor), else nil
function TD.doorOfHighlight(car, hc, owner)
    if hc:GetFName():ToString() == "Highlight_EnterDoor" then return 1 end
    for k = 1, 4 do local d = Twin.door(car, k) if d and d:GetAddress() == owner:GetAddress() then return k end end
    if owner:GetClass():GetFName():ToString() == "BP_CarPart_Interactive_C" then
        local key = owner:GetAddress()
        if TD.catSlot[key] == nil then
            local out, slot = {}, ""
            if pcall(function() owner:GetSlotComponent(out) end) then
                local sc = out.SlotSceneComponent
                slot = sc and sc:IsValid() and sc.SlotName.TagName:ToString() or ""
            end
            TD.catSlot[key] = ({ ["Car.Equip.Body.DoorsFL"] = 1, ["Car.Equip.Body.DoorsFR"] = 2, ["Car.Equip.Body.DoorsRL"] = 3, ["Car.Equip.Body.DoorsRR"] = 4, ["Car.Equip.Body.DoorsTrunk"] = 5 })[slot] or false
        end
        return TD.catSlot[key] or nil
    end
    return nil
end
-- A passenger reaches only its own door (owner, 2026-10-30: "the back-seat passenger could work the lever and the
-- front door; the controls are the driver's, the passenger has its own door"). The highlight manager asks
-- "Should Allow Highlight" of every candidate; a hook after it says no, for a player on a seat other than the driver's,
-- to anything of the car it sits in but the ExitDoor spot (moved to its door: TD.placeExit) and that door itself.
local SEAT_DOOR_SLOT = { "Car.Equip.Body.DoorsFL", "Car.Equip.Body.DoorsFR", "Car.Equip.Body.DoorsRL", "Car.Equip.Body.DoorsRR" }
-- The car's controls (key, levers, top light, gear lever, radio, the dash's toys) are the driver's only: on foot from
-- outside the game's E at the other's car's light lever switched the manager's lights - the own car's too (one state
-- for the game; twin-ctl).
local CONTROL_HL = { Highlight_Key = true, Highlight_LeftHandle = true, Highlight_RightHandle = true, Highlight_TopLight = true,
    Highlight_Gearbox = true, Highlight_Handle = true, Highlight_Wiperblades = true }
local CONTROL_CLS = { BP_Carpart_Shifter_Base_C = true, BP_CarPart_Internal_Radio_C = true, BP_Dash_CarFriend_C = true }
function TD.passengerMayReach(hc)
    -- (the garage lobby: no seats kept there - the host's own key / levers / radio were denied, owner's alpha 18 test;
    -- a stopped session: single player again)
    -- (on a back seat of its own car there - the mod's entry, TD.ownEnter - the passenger rules hold: owner's alpha 21
    -- test, the key / levers / the driver's door were all there from the back seat in the garage)
    if M.stopped or not (hc and hc:IsValid()) then return true end
    if garage then
        if not (TD.seatNow and TD.seatNow.n ~= 1) then return true end
    elseif not TD.native then return true end
    local owner = hc:GetOwner()
    local car = owner and Native.carOf(owner)
    if not car then return true end -- (not of a car: the world)
    local sn = TD.seatNow
    local here = sn and Sync.ref(car) == sn.car
    if not (here and sn.n == 1) then
        -- (not at this car's wheel: none of its controls)
        if CONTROL_HL[hc:GetFName():ToString()] or CONTROL_CLS[owner:GetClass():GetFName():ToString()] then return false end
    end
    -- (on foot: no way in by a door whose seat the other player sits on - the game's own entry started and the mod
    -- threw the player out again, contact-test; as the own car's doors do: doorBlocked. The driver's door only: the
    -- game gets in by that one alone - a back / passenger door it just opens, the mod's entry there (TD.ownEnter,
    -- TD.twinEnter) refuses a taken seat; so that door stays to open / shut / take off, owner's alpha 19 item 14)
    if not sn then
        local n = TD.doorOfHighlight(car, hc, owner)
        local tag = Twin.isTwin(car) and otherTag() or myTag()
        -- (the car body's way-in spot only: the door itself stays lit - its E opens / shuts it, TD.takenDoorPress - and
        -- its own E handlers are parked meanwhile, TD.entryPark; owner's two-games test 2026-11-11: "with the other at
        -- the wheel the door is not highlighted, nothing can be done with it")
        if n == 1 and seatTakenByOther(tag, n) and hc:GetFName():ToString() == "Highlight_EnterDoor" then return false end
    end
    if not (here and sn.n ~= 1) then return true end -- (on foot / the driver: the rest is the game's)
    if hc:GetFName():ToString() == "Highlight_ExitDoor" then return true end
    local door = Twin.door(car, sn.n)
    if door and owner:GetAddress() == door:GetAddress() then return true end
    if owner:GetClass():GetFName():ToString() == "BP_CarPart_Interactive_C" then
        local out = {}
        if pcall(function() owner:GetSlotComponent(out) end) then
            local sc = out.SlotSceneComponent
            if sc and sc:IsValid() and sc.SlotName.TagName:ToString() == SEAT_DOOR_SLOT[sn.n] then return true end
        end
    end
    return false
end
function TD.hookPassengerReach()
    CoopSyncReachHook = CoopSyncReachHook or { denied = 0 }
    CoopSyncReachHook.on = TD.passengerMayReach
    if CoopSyncReachHook.done then return end
    local hm = (CoopSyncFirst or FindFirstOf)("BP_HighlightManager_C")
    local cls = hm and hm:IsValid() and hm:GetClass():GetFullName():gsub("^%S+%s+", "")
    if not cls then return end
    CoopSyncReachHook.done = true
    Hook(cls .. ":Should Allow Highlight", function(self, hc, allow, why)
        local f = CoopSyncReachHook.on
        if not f then return end
        pcall(function()
            if allow:get() and not f(hc:get()) then
                allow:set(false)
                CoopSyncReachHook.denied = CoopSyncReachHook.denied + 1

            end
        end)
    end)
end

-- The own car is the context: its door flags follow its doors (open = the door simulates), but not within
-- TD.DOOR_E_MS of the player's E (its own door opening / shutting writes them) - a flag the twin's door wrote while a
-- switch was under way stayed "open" (the dash, the door spots; cars-test: RL "open" after riding in the other's car).
function TD.ownDoorFlags(own)
    if not own or not Native.ctx or Native.ctx ~= Sync.ref(own) then return end
    local now = M.nowMs()
    if now - (TD.ownFlagsAt or 0) < 500 or now - (TD.lastInteractMs or -1e9) < TD.DOOR_E_MS then return end
    TD.ownFlagsAt = now
    local m = Native.manager()
    local cur = TD.readDoorStates(m)
    for k, v in pairs(Native.realDoors(own)) do
        if cur[k] ~= nil and cur[k] ~= v then
            if pcall(function() m:SetDoorState(k, v) end) then st.ownFlagsFixed = (st.ownFlagsFixed or 0) + 1 end
        end
    end
end

-- the game's own exit let go of the other's car
function TD.nativeLeft(pawn)
    TD.twinAimMs = M.nowMs() -- (the other's car stays the context through the rest of the game's exit animation)
    if inGhost.seat and inGhost.seat ~= 1 then TD.passengerExit = { n = inGhost.seat, untilMs = M.nowMs() + 4000 } end
    -- (the owner's door of that seat shut for sure: the context may be the own car again by then - the host's door 3
    -- stayed open, cars-test)
    local en = inGhost.seat or inGhost.door
    if en and SEAT_DOOR[en] then
        -- (and opened for the way out: the watch sends it only if it saw the game's flag change while the other's car
        -- was the context - when the switch came first only the shut went, the host's door 3 never opened; contact /
        -- cars, quick suite 2026-11-10)
        if M.nowMs() - (TD.openSentMs[en] or -1e9) > 2000 then TD.sendDoor(en, "open") st.exitOpenSent = (st.exitOpenSent or 0) + 1 end
        TD.exitShut = { n = en, at = M.nowMs() + TD.EXIT_SHUT_MS }
    end
    pcall(TD.stopDriving)
    pcall(twinControlsRestore)
    local g = ghostOf(inGhost.tag)
    if g then pcall(function() g.FirstPersonCamera:K2_SetRelativeRotation({ Pitch = 0, Yaw = 0, Roll = 0 }, false, {}, true) end) end
    if inGhost.tag == "H" then myAssigned, seatPending = nil, false end
    inGhost = nil
    TD.aimed = nil
    st.ghostLeft = (st.ghostLeft or 0) + 1
    st.lastGhostLeave = "player got out (native)"
end

-- every apply tick: a held E (door only), the entry's second step, the door shut after the entry
TD.SHUT_PRESS_MS = 400
function TD.doorTick()
    local now = M.nowMs()
    local sp = TD.shutPress
    if sp and now >= sp.at then
        TD.shutPress = nil
        if not inGhost and (st.nativeDoorsSent or 0) == sp.sent and TD.ownerDoorOpen(sp.n) then
            TD.sendDoor(sp.n, "shut")
            st.shutPressSent = (st.shutPressSent or 0) + 1
        end
    end
    if TD.doorPress and now - TD.doorPress.ms >= TD.HOLD_MS then
        if not TD.native and not TD.doorPress.own then TD.sendDoor(TD.doorPress.n, "toggle") end -- (native: a hold is the game's own)
        TD.doorPress = nil
    end
    if inGhost and inGhost.enterAt and now >= inGhost.enterAt then
        inGhost.enterAt = nil
        local pawn, door = localPawn(), inGhost.doorPath and Sync.deref(inGhost.doorPath)
        if pawn and door and Twin.finishEntry(pawn, door) then inGhost.shutAt = now + TD.ENTRY_SHUT_MS - TD.ENTRY_STEP_MS
        elseif pawn and not inGhost.doorPath and Twin.finishEntry(pawn, inGhost.emptyPath and Sync.deref(inGhost.emptyPath)) then -- (the doorway: no door to shut)
        elseif pawn then ghostLeave(pawn, "entry failed") end
    end
    -- (the own car's back seat, TD.ownEnter: the game's CommandEnterCar after the door's StartEntry, as for the other's
    -- car; its door shut after the walk in)
    local ownS = TD.ownSeat
    if ownS and ownS.enterAt and now >= ownS.enterAt then
        ownS.enterAt = nil
        local pawn, door = localPawn(), ownS.door and Sync.deref(ownS.door)
        local by = door or (ownS.empty and Sync.deref(ownS.empty))
        if not (pawn and (door or not ownS.door) and by and Twin.finishEntry(pawn, by)) then st.ownEnter = ownS.n .. ":enter_failed" end
    end
    if ownS and ownS.shutAt and now >= ownS.shutAt then
        ownS.shutAt = nil
        local door = Sync.deref(ownS.door)
        if door then pcall(function() door:AttemptShut() end) end
    end
    if inGhost and inGhost.shutAt and now >= inGhost.shutAt then
        inGhost.shutAt = nil
        if inGhost.door then TD.sendDoor(inGhost.door, "shut") end
    end
    if TD.entryShut and now >= TD.entryShut.at then
        TD.sendDoor(TD.entryShut.n, "shut")
        TD.entryShut = nil
    end
    if TD.exitShut and now >= TD.exitShut.at then
        TD.sendDoor(TD.exitShut.n, "shut")
        TD.exitShut = nil
    end
end

-- The game's E at a door of the other's twin (the one the game highlights: Twin.highlightedDoor; the game itself does
-- nothing there, Twin.muteDoors) is this side's TD.doorPress (tap / hold on the release, TD.doorTick). Hooked on
-- BP_HighlightManager_C:HighlightPress (the hook runs after the press, the highlight still on). The twin's EnterDoor
-- spot (its car body, by the driver's door; muted outside, Twin.muteBody) is the driver's door.
-- How far door n of twin g stands open by its owner's pose (degrees, its mesh against the car), 0 when shut.
function TD.twinDoorAngle(g, n)
    local d = Twin.door(g, n)
    if not d then return 0 end
    local ok, a = pcall(function()
        local rel = KML:ComposeTransforms(d.MainMesh:K2_GetComponentToWorld(), KML:InvertTransform(g:GetTransform()))
        local r = KML:Quat_Rotator(rel.Rotation)
        return math.max(math.abs(r.Yaw), math.abs(r.Pitch))
    end)
    return ok and a or 0
end
-- The other's door / trunk lid while it is open: the twin's door is posed (kinematic), the game's highlight trace goes
-- through it to what is behind (owner, alpha 16: "the friend could not shut my trunk"). Looking at it (the camera's line
-- passing its middle, 3 m at most) is pressing it. Returns the twin and the door, else nil.
local DOOR_MID = { [5] = { 0, 0, 50 } } -- (the open lid stands up over its hinge; a side door swings out: its middle)
function TD.lookedAtOpenDoor()
    local g = ghostOf(otherTag())
    if not (g and Twin.isTwin(g)) then return nil end
    local ok, cm = pcall(function() return (CoopSyncFirst or FindFirstOf)("PlayerController").PlayerCameraManager end)
    if not (ok and cm) then return nil end
    local cam, fwd = cm:GetCameraLocation(), KML:GetForwardVector(cm:GetCameraRotation())
    for n = 1, 5 do
        local d = TD.twinDoorAngle(g, n) > 20 and Twin.door(g, n)
        if d then
            local okH, hit = pcall(function()
                local h = d.MainMesh:K2_GetComponentLocation()
                if not DOOR_MID[n] then -- (a side door: 50 out along its open mesh from the hinge)
                    local f = KML:GetForwardVector(d.MainMesh:K2_GetComponentRotation())
                    local side = toCar(g, h).Y > 0 and 1 or -1
                    local r = KML:GetRightVector(d.MainMesh:K2_GetComponentRotation())
                    h = { X = h.X - f.X * 50 + r.X * side * 10, Y = h.Y - f.Y * 50 + r.Y * side * 10, Z = h.Z + 20 }
                else
                    h = { X = h.X, Y = h.Y, Z = h.Z + DOOR_MID[n][3] }
                end
                local v = { X = h.X - cam.X, Y = h.Y - cam.Y, Z = h.Z - cam.Z }
                local along = v.X * fwd.X + v.Y * fwd.Y + v.Z * fwd.Z
                if along < 0 or along > 300 then return false end
                local off2 = v.X * v.X + v.Y * v.Y + v.Z * v.Z - along * along
                return off2 < 110 ^ 2
            end)
            if okH and hit then return g, n end
        end
    end
    return nil
end
-- K2_ShouldHighlight of a slot spot (hooks above): on the other's twin a door slot's spot shows while that door is shut
-- by its owner's pose; anything else: the game's own answer (nil)
TD.catSlot = {} -- spot address -> door number | false
function TD.catShow(cat)
    if M.stopped or not (cat and cat:IsValid()) then return nil end
    local key = cat:GetAddress()
    local n = TD.catSlot[key]
    if n == nil then
        n = false
        local out = {}
        if pcall(function() cat:GetSlotComponent(out) end) then
            local sc = out.SlotSceneComponent
            local slot = sc and sc:IsValid() and sc.SlotName.TagName:ToString() or ""
            n = ({ ["Car.Equip.Body.DoorsFL"] = 1, ["Car.Equip.Body.DoorsFR"] = 2, ["Car.Equip.Body.DoorsRL"] = 3, ["Car.Equip.Body.DoorsRR"] = 4, ["Car.Equip.Body.DoorsTrunk"] = 5 })[slot] or false
        end
        TD.catSlot[key] = n
    end
    if not n then return nil end
    local g, depth = cat, 0
    while depth < 10 do local p = g:GetAttachParentActor() if not (p and p:IsValid()) then break end g, depth = p, depth + 1 end
    if not Twin.isTwin(g) then return nil end
    -- (native cars: not for a seat the other player sits on - its door would get the player in, the game's way)
    -- (the driver's door only: the others the game just opens - owner's alpha 19 item 14)
    if TD.native and n == 1 then TD.entryPark(g, seatTakenByOther(otherTag(), n)) end -- (its E parked, not hidden: doorBlocked)
    -- (shown always: hidden while the owner's door stood open, an open door's seat could not be taken - ghostseat;
    -- its open door is also pressed by looking at it, TD.lookedAtOpenDoor)
    return true
end
-- E at the driver's door while the other player sits behind it (its E handlers parked: TD.entryPark): the door opens /
-- shuts - the own car's here, the other's by its owner (DR toggle). True when it was that.
function TD.takenDoorPress()
    local hm = (CoopSyncFirst or FindFirstOf)("BP_HighlightManager_C")
    local h = hm and hm.CurrentHighlight
    local o = h and h:IsValid() and h:GetOwner()
    local car = o and o:IsValid() and Native and Native.carOf(o)
    if not car then return false end
    local d1 = Twin.door(car, 1)
    -- (the door actor or its slot's spot - lit while the door is shut; not the body's way-in spot)
    if not d1 or h:GetFName():ToString() == "Highlight_EnterDoor" or TD.doorOfHighlight(car, h, o) ~= 1 then return false end
    local twin = Twin.isTwin(car)
    if not seatTakenByOther(twin and otherTag() or myTag(), 1) then return false end
    if twin then TD.sendDoor(1, "toggle")
    else
        pcall(Native.use, car) -- (the door goes by the context car's flag: DR)
        local open = Twin.doorOpen(car, 1)
        pcall(function() if open then d1:AttemptShut() else d1:AttemptOpen() end end)
    end
    st.takenDoorPresses = (st.takenDoorPresses or 0) + 1
    return true
end
-- A back seat's empty doorway the player looks at (owner's two-games test 2026-11-11: "no door on the back seat: no
-- way to sit there"): the slot holds the game's BP_CarPart_EmptyDoor_C, which the game never lights (no highlight
-- trace hits it). The camera's line passing within 70 of the doorway's middle (the seat's side, mid height), 3.3 m at
-- most: the own car's -> { own = true, n }, the other's twin's -> { tag, n }. backseat-test.
-- (car-relative: the back doors hang at X 8, Y +-94, Z 19 and reach back ~90 - probed on the guest's car 2026-11-11)
TD.DOORWAY_MID = { [3] = { X = -40, Y = -94, Z = 0 }, [4] = { X = -40, Y = 94, Z = 0 } }
function TD.lookedAtDoorway()
    local ok, cm = pcall(function() return (CoopSyncFirst or FindFirstOf)("PlayerController").PlayerCameraManager end)
    if not (ok and cm) then return nil end
    local cam, fwd = cm:GetCameraLocation(), KML:GetForwardVector(cm:GetCameraRotation())
    local cars = {}
    local own = Twin.ownCar()
    if own then cars[#cars + 1] = { car = own, own = true, tag = myTag() } end
    local tw = ghostOf(otherTag())
    if tw and Twin.isTwin(tw) then cars[#cars + 1] = { car = tw, tag = otherTag() } end
    for _, c in ipairs(cars) do
        for n, mid in pairs(TD.DOORWAY_MID) do
            local d = Twin.door(c.car, n)
            if d and not TD.realDoor(c.car, n) then
                local h = KML:TransformLocation(c.car:GetTransform(), mid)
                local v = { X = h.X - cam.X, Y = h.Y - cam.Y, Z = h.Z - cam.Z }
                local along = v.X * fwd.X + v.Y * fwd.Y + v.Z * fwd.Z
                local off = math.sqrt(math.max(0, v.X * v.X + v.Y * v.Y + v.Z * v.Z - along * along))
                TD.doorwaySeen = string.format("%s%d:along=%.0f,off=%.0f", c.own and "own" or c.tag, n, along, off)
                if along > 0 and along < 330 and off < 70 then
                    return { own = c.own, tag = c.tag, n = n }
                end
            end
        end
    end
    return nil
end
function TD.onHighlightPress(isPress)
    st.highlightPresses = (st.highlightPresses or 0) + 1
    if M.stopped or isPress ~= true or inGhost then return end
    -- (an empty back doorway: a tap there gets in - TD.ownEnter / TD.twinEnter, through the doorway)
    if not TD.seatNow and not Sync.parentOf(localPawn()) then
        local dw = TD.lookedAtDoorway()
        if dw then
            TD.doorPress = { own = dw.own, tag = dw.tag, n = dw.n, ms = M.nowMs() }
            st.doorwayPresses = (st.doorwayPresses or 0) + 1
            return
        end
    end
    if not garage and TD.native and TD.seatNow == nil and TD.takenDoorPress() then return end
    -- (the garage lobby: the guest's start there is not native - its back doors only opened, owner's alpha 21 test: "the
    -- friend could not get onto his own back seat in the garage"; the own car's back seat for both there)
    if garage and not TD.native then
        local on = TD.ownBackDoorAimed()
        if on then TD.doorPress = { own = true, tag = myTag(), n = on, ms = M.nowMs() } end
        return
    end
    if TD.native then
        -- (native cars: the game gets in by the driver's door only - a back door it just opens. A tap at a back door of the
        -- other's car whose seat is free gets the player in there with the game's own entry, TD.twinEnter)
        -- (the door the player aims at: TD.aimNative, from the highlight - a door actor, the door slot's spot)
        -- (a back door of the own car: its seat, TD.ownEnter)
        local on = TD.ownBackDoorAimed()
        if on then TD.doorPress = { own = true, tag = myTag(), n = on, ms = M.nowMs() } return end
        local tn = TD.aimed and TD.aimed.n
        -- (the aim now: the other's car lit, or its open door looked at - a stale aim sent the guest's E at its own empty
        -- doorway to the host's back door, which opened; backseat-test 2026-11-11)
        if tn then
            local hm = (CoopSyncFirst or FindFirstOf)("BP_HighlightManager_C")
            local h = hm and hm.CurrentHighlight
            local hc = h and h:IsValid() and h:GetOwner() and Native.carOf(h:GetOwner())
            local tw0 = ghostOf(otherTag())
            local litTwin = hc and tw0 and hc:GetAddress() == tw0:GetAddress()
            local _, on = TD.lookedAtOpenDoor()
            if not (litTwin or on == tn) then tn = nil st.staleAims = (st.staleAims or 0) + 1 end
        end
        if tn and tn >= 2 and tn <= 4 then TD.doorPress = { tag = otherTag(), n = tn, ms = M.nowMs() } end
        -- (E at an open door / lid of the other's car: the game's own shut does not close a door of the kinematic twin
        -- (TD.twinDoorReconcile) - the lid stayed open in 4 of 6 cars-test runs, owner's alpha 18 item 24. When the game
        -- sent nothing for it by then, the shut goes to the owner: its real door shuts, the pose brings the twin's)
        local tw = ghostOf(otherTag())
        if tn and tw and Twin.isTwin(tw) and (Twin.doorOpen(tw, tn) or TD.ownerDoorOpen(tn)) then
            TD.shutPress = { n = tn, at = M.nowMs() + TD.SHUT_PRESS_MS, sent = st.nativeDoorsSent or 0 }
        end
        return
    end
    local tw, tn = Twin.highlightedDoor()
    if not tw then
        local bw, name = Twin.highlightedBody()
        if name == "EnterDoor" then tw, tn = bw, 1 end
    end
    if not tw then tw, tn = TD.lookedAtOpenDoor() end
    if not tw then return end
    local tag = otherTag()
    local g = ghostOf(tag)
    if not (g and g:GetAddress() == tw:GetAddress()) then return end
    TD.doorPress = { tag = tag, n = tn, ms = M.nowMs() }
    st.twinDoorE = (st.twinDoorE or 0) + 1
end
-- the twin's body lights: the owner's values after the car's own per-frame update (twincar "Lights")
-- The horn (probe cmds/horn-probe.lua): the player's horn key goes to the car manager (StartHornHonk / EndHornHonk
-- by instigator name), whose UpdateHornState calls ToggleCarHorn(Active, Pitch) on the manager's car - the car the
-- player sits in (the twin too: the game makes it the manager's car). Hook on the car's ToggleCarHorn (after its body):
--   * on the twin the local player sits in: its own honk there - "HR <0|1>" to the owner, whose manager honks its
--     real car (instigator CoopSync);
--   * on the own car: "HN <0|1> <pitch>" - the other side's twin of it honks with the game's ToggleCarHorn.
TD.horn = { sent = nil, twin = nil, guard = false }
function TD.setTwinHorn(on, pitch)
    local c = TD.copy()
    if not (c and Twin.isTwin(c)) or TD.horn.twin == on then return end
    TD.horn.twin = on
    TD.horn.guard = true
    pcall(function() c:ToggleCarHorn(on, pitch or 1) end)
    TD.horn.guard = false
end
function TD.onCarHorn(a, on, pitch)
    if TD.horn.guard then return end
    if Twin.isTwin(a) then
        if not TD.inTwin(a) then return end
        TD.horn.twin = on
        if TD.horn.asked ~= on then
            TD.horn.asked = on
            append(outFile, string.format("HR\t%d\t%d", M.nowMs(), on and 1 or 0))
            st.hornAsked = (st.hornAsked or 0) + 1
        end
        return
    end
    local own = Twin.ownCar()
    if not (own and own:GetAddress() == a:GetAddress()) or TD.horn.sent == on then return end
    TD.horn.sent = on
    append(outFile, string.format("HN\t%d\t%d\t%.3f", M.nowMs(), on and 1 or 0, pitch or 1))
    st.hornSent = (st.hornSent or 0) + 1
end
-- the other player, in its twin of this side's car, pressed / let go its horn key: this side's manager honks
function TD.askedHorn(on)
    local m = (CoopSyncFirst or FindFirstOf)("BP_CarManager_C")
    if not (m and m:IsValid()) then return false end
    local name = FName("CoopSync")
    return pcall(function() if on then m:StartHornHonk(name) else m:EndHornHonk(name) end end)
end
function TD.hookHorn()
    CoopSyncHornHook = CoopSyncHornHook or {}
    CoopSyncHornHook.on = TD.onCarHorn
    if CoopSyncHornHook.done then return end
    local car = FindFirstOf("BP_PlayerCarNew_C")
    local cls = car and car:IsValid() and car:GetClass():GetFullName():gsub("^%S+%s+", "")
    if not cls then return end
    CoopSyncHornHook.done = true
    Hook(cls .. ":ToggleCarHorn", function(self, active, pitch)
        local f = CoopSyncHornHook.on
        if f then pcall(function() f(self:get(), active:get(), pitch:get()) end) end
    end)
end
-- Radio music (twincar "Radio music"): "RT <track> <ms>" = what this side's own radio plays and how far (checked every
-- 250 ms, sent when changed / seeked or every 5 s); "RN <track>" = the owner's next track, picked here ~4 s before the
-- end and queued on both sides (the game's own picks are random: the two radios went apart at every track's end).
-- Following the owner (in the other's twin with the radio on; in the garage the guest always follows the host - the
-- garage stereo plays the same music): its track, then in step (seek when > 700 ms off). The channel button there
-- (BP_RadioComponent ChangeChannel, hooked: after its body, the local radio has skipped already) -> "RK <dir>": the
-- owner's real radio changes channel, its new track comes back on RT (held 2 s meanwhile). The game's own random seek
-- (BP_MusicManager RandomSeekMusic, when a radio turns on) is replaced by a known one (the clock stays right).
-- "RI <sequence>" = a radio DJ break began on the owner's side: the follower plays the same one, its own held off.
-- Car storages (twincar carstore.lua): the own car's trunk / storage contents to the other side ("CS", checked every
-- second, sent when changed and every 10 s); in the other's twin, what the local player changed there goes to the
-- owner ("CX", checked every 500 ms before the owner's latest CS is filled in); the owner answers a put that did not
-- fit ("CN": back to the player) and a take it no longer had ("CT": the player's copy removed).
TD.store = { checkMs = -1e9, sent = nil, sentMs = -1e9, tickMs = -1e9 }
function TD.sendStore()
    local now = M.nowMs()
    if now - TD.store.checkMs < 1000 then return end
    TD.store.checkMs = now
    local ok, line = pcall(Twin.Store.ownLine)
    if not (ok and line) then return end
    if line ~= TD.store.sent or now - TD.store.sentMs > 10000 then
        TD.store.sent, TD.store.sentMs = line, now
        append(outFile, string.format("CS\t%d\t%s", now, line))
        st.storeSent = (st.storeSent or 0) + 1
    end
end
function TD.storeTick(twin)
    local now = M.nowMs()
    if now - TD.store.tickMs < 500 then return end
    TD.store.tickMs = now
    -- the local player's changes in the twin's storages: only near it or in it (its storages are reached from there;
    -- 9 ms a check, soak test profile 2026-10-28), every 1 s; farther every 5 s (a change made from farther - a bot,
    -- an inventory screen kept open - else waited for the next approach: 5 min out of step in a soak run)
    local pawn = localPawn()
    local near = TD.inTwin(twin)
    if not near and pawn then
        local a, b = pawn:K2_GetActorLocation(), twin:K2_GetActorLocation()
        near = (a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 < 1500 ^ 2
    end
    local ok, changes = true, nil
    if now - (TD.store.changesMs or 0) >= (near and 1000 or 5000) then
        TD.store.changesMs = now
        local t0 = os.clock()
        ok, changes = pcall(Twin.Store.changes, twin)
        TD.prof("st_changes", t0)
    end
    if ok and changes then
        for _, c in ipairs(changes) do
            append(outFile, string.format("CX\t%d\t%s", now, c))
            st.storeAsked = (st.storeAsked or 0) + 1
        end
    end
    if target.store then
        local t0 = os.clock()
        local okA, done = pcall(Twin.Store.apply, twin, target.store)
        TD.prof("st_apply", t0)
        if okA and done then target.store = nil end
    end
end
-- A hit between the own car and the other's twin (twincar bumpTick, seen here): "BI <nx> <ny> <vc>" - the other side
-- sets the shared speed on its car too (twincar bumpGot). Either way this side's twin of the other car moves on at
-- that speed at once (TD.kick).
function TD.bump(twin, vel)
    local ok, nx, ny, vc = pcall(Twin.bumpTick, twin, vel)
    if ok and nx then
        append(outFile, string.format("BI\t%d\t%.4f\t%.4f\t%.0f", M.nowMs(), nx, ny, vc))
        st.bumpSent = (st.bumpSent or 0) + 1
        TD.kickTwin(twin, nx, ny, vc)
    end
end
-- The guest, for 30 s after the host's car's twin is here: its own car standing inside that twin (both flew apart -
-- owner's two-games test 2026-11-14) goes to a free spot beside it (runsync.clearOfTwin), once a second.
function TD.clearOwnCar(twin)
    local now = M.nowMs()
    if not (TD.clearUntil and now < TD.clearUntil) or now - (TD.clearAt or 0) < 1000 then return end
    TD.clearAt = now
    local own = Twin.ownCar()
    if not (own and own:IsValid() and own:GetAddress() ~= twin:GetAddress()) then return end
    TD.Run = TD.Run or CoopSyncRunMod or dofile(Sync.DIR .. "runsync.lua")
    local ok, r = pcall(TD.Run.clearOfTwin, own, twin)
    if ok and r then
        st.carCleared = (st.carCleared or 0) + 1
        st.lastCleared = r
        if CoopSyncHitch then pcall(CoopSyncHitch.note, "own car out of the host's twin: " .. r) end
    elseif not ok then err("clear own car: " .. tostring(r)) end
end
function TD.kickTwin(twin, nx, ny, vc)
    local l = twin:K2_GetActorLocation()
    TD.kick = { at = M.nowMs(), path = Sync.ref(twin), x = l.X, y = l.Y, nx = nx, ny = ny, v = vc }
end
-- The twin of the other car after a hit: along the line between the cars it moves at the shared speed (TD.kick,
-- ~0.5 s) - the stream still had it where it was (the car hit: it shows that car pushed a round trip later) or ahead
-- by its prediction (the striker: it drove into the car hit again, 28 m/s). Across that line the stream's spot stays.
-- goal: follow's spot, changed.
TD.KICK_MS = 500
function TD.kicked(actor, goal)
    local k = TD.kick
    local age = M.nowMs() - k.at
    if age > TD.KICK_MS then TD.kick = nil return goal end
    if Sync.ref(actor) ~= k.path then return goal end
    local s = age / 1000
    local kx, ky = k.x + k.nx * k.v * s, k.y + k.ny * k.v * s
    local off = (kx - goal.X) * k.nx + (ky - goal.Y) * k.ny
    goal.X, goal.Y = goal.X + k.nx * off, goal.Y + k.ny * off
    return goal, true
end
TD.music = { sent = nil, sentMs = -1e9, sentStart = 0, checkMs = -1e9, holdMs = -1e9, tryMs = -1e9, seekMs = -1e9, followMs = -1e9 }
function TD.sendTrack()
    local now = M.nowMs()
    if now - TD.music.checkMs < 250 then return end
    TD.music.checkMs = now
    if role ~= "host" and garage then return end -- (the garage: the host's music)
    local m = (CoopSyncFirst or FindFirstOf)("BP_CarManager_C")
    local c = m and m.NewCarActor
    -- (in the zone only the station's track goes out: TD.isStation)
    if not garage then TD.sendRadioOn() if not TD.isStation() then return end end
    pcall(Twin.queueTick)
    local ok, dj = pcall(Twin.djStarted)
    if ok and dj then
        append(outFile, string.format("RI\t%d\t%s", now, dj))
        st.djSent = (st.djSent or 0) + 1
    end
    local okE, ended = pcall(Twin.djEnded)
    if okE and ended then append(outFile, string.format("RI\t%d\t-", now)) st.djEndSent = (st.djEndSent or 0) + 1 end
    local id, pos, len = Twin.trackPos()
    if not id then return end
    local start = now - pos
    if id ~= TD.music.sent or math.abs(start - TD.music.sentStart) > 300 or now - TD.music.sentMs > 5000 then
        TD.music.sent, TD.music.sentMs, TD.music.sentStart = id, now, start
        append(outFile, string.format("RT\t%d\t%s\t%d", now, id, math.floor(pos)))
        st.trackSent = (st.trackSent or 0) + 1
    end
    if len and len > 0 and pos > len - 4000 and TD.music.nextFor ~= id then
        TD.music.nextFor = id
        local nx = Twin.pickNext(id)
        if nx and Twin.queueTrack(nx) then
            append(outFile, string.format("RN\t%d\t%s", now, nx))
            st.nextSent = (st.nextSent or 0) + 1
        end
    end
end
-- where the owner's track is now (ms), from its last RT
function TD.ownerPos()
    if not target.trackPos then return nil end
    return target.trackPos + (M.nowMs() - target.trackAt)
end
-- One station for both in the zone (owner's two-games test 2026-11-11: "radio on in both, each in the other's car: the
-- tracks differed, skipping did not sync - we do not sync tracks between different cars?"): each car followed its
-- owner's radio, and an owner sitting in the other's car sent nothing - two radios, two tracks. Now the radio that is
-- on plays one station: the host's when its radio is on, else the guest's. The station sends its track (RT / RN / RI),
-- every other radio that is on follows it, a channel change there goes to the station (RK).
--   RS <time> <0|1>     this side's radio on / off (on a change, else every 5 s)
function TD.radioOnHere()
    local r = {}
    pcall(function() (CoopSyncFirst or FindFirstOf)("BP_CarManager_C"):GetCarRadioOnOffState(r) end)
    return r.CarState_Radio == true
end
function TD.otherRadioOn() return target.radioOn == true and M.nowMs() - (target.radioAt or -1e9) < 12000 end
function TD.isStation()
    if garage then return role == "host" end
    return TD.radioOnHere() and (role == "host" or not TD.otherRadioOn())
end
function TD.sendRadioOn()
    local on, now = TD.radioOnHere(), M.nowMs()
    if on ~= TD.music.radioSent or now - (TD.music.radioSentMs or -1e9) > 5000 then
        TD.music.radioSent, TD.music.radioSentMs = on, now
        append(outFile, string.format("RS\t%d\t%d", now, on and 1 or 0))
        st.radioStateSent = (st.radioStateSent or 0) + 1
    end
end
-- does this side's radio follow the other's? (c: unused - any car's radio follows the station)
function TD.following(c)
    if garage then return role ~= "host" end
    return TD.radioOnHere() and not TD.isStation() and TD.otherRadioOn()
end
function TD.musicTick(c)
    pcall(Twin.queueTick)
    local want = target.track
    if not (want and TD.following(c)) then pcall(Twin.djRelease) return end
    pcall(Twin.djFollow)
    local now = M.nowMs()
    TD.music.followMs = now
    if now < TD.music.holdMs then return end
    local cur, pos = Twin.trackPos()
    if not cur then return end
    if cur ~= want then
        -- already on the owner's announced next track (this side's ended first): the owner gets there in a moment
        if cur == target.nextTrack and now - (target.nextAt or 0) < 15000 then return end
        if now - TD.music.tryMs < 1000 then return end
        TD.music.tryMs = now
        local ok, played = pcall(Twin.playTrack, want, TD.ownerPos)
        st.trackPlayed = (st.trackPlayed or 0) + ((ok and played) and 1 or 0)
        st.lastTrack = (ok and played) and want or ("miss:" .. want)
        return
    end
    local at = TD.ownerPos()
    if at then
        local d = pos - at
        st.trackDrift = math.floor(d)
        if math.abs(d) > 700 and now - TD.music.seekMs > 3000 then
            TD.music.seekMs = now
            local ok, done = pcall(Twin.seekTrack, at)
            if ok and done then st.trackSeeks = (st.trackSeeks or 0) + 1 end
        end
    end
    -- the owner's next track queued here too: both radios change to it at the same moment
    if target.nextTrack and target.nextTrack ~= want and Twin.queuedTrack() ~= target.nextTrack then
        if Twin.queueTrack(target.nextTrack) then st.nextQueued = (st.nextQueued or 0) + 1 end
    end
end
function TD.onChannel(comp, dir)
    local part = comp:GetOwner()
    if garage then
        if role == "host" then return end
    else
        -- (a radio following the station: its channel change is the station's - not the follower's own track change)
        if not TD.following(nil) or M.nowMs() - TD.music.tryMs < 2500 then return end
    end
    TD.music.holdMs = M.nowMs() + 2000
    append(outFile, string.format("RK\t%d\t%d", M.nowMs(), dir))
    st.channelAsked = (st.channelAsked or 0) + 1
end
-- after the game's random seek of the radio track: following -> where the owner is, else a random place this side knows
function TD.onRandomSeek()
    local id, _, len = Twin.trackPos()
    if not id then return end
    local follow = M.nowMs() - TD.music.followMs < 1000 and id == target.track
    local ms = follow and TD.ownerPos() or math.random(0, math.floor(math.max(0, (len or 0) * 0.8)))
    local ok, done = pcall(Twin.seekTrack, ms)
    st.randomSeeks = (st.randomSeeks or 0) + ((ok and done) and 1 or 0)
end
function TD.hookRadio()
    CoopSyncRadioHook = CoopSyncRadioHook or {}
    CoopSyncRadioHook.on = TD.onChannel
    CoopSyncRadioHook.seek = TD.onRandomSeek
    if not CoopSyncRadioHook.seekDone then
        local mm = FindFirstOf("BP_MusicManager_C")
        local mcls = mm and mm:IsValid() and mm:GetClass():GetFullName():gsub("^%S+%s+", "")
        if mcls then
            CoopSyncRadioHook.seekDone = true
            Hook(mcls .. ":RandomSeekMusic", function()
                local f = CoopSyncRadioHook.seek
                if f then pcall(f) end
            end)
        end
    end
    if CoopSyncRadioHook.done then return end
    local rc = FindFirstOf("BP_RadioComponent_C")
    local cls = rc and rc:IsValid() and rc:GetClass():GetFullName():gsub("^%S+%s+", "")
    if not cls then return end
    CoopSyncRadioHook.done = true
    Hook(cls .. ":ChangeChannel", function(self, dir)
        local f = CoopSyncRadioHook.on
        if f then pcall(function() f(self:get(), dir:get()) end) end
    end)
end
-- The car's GetGearboxActor answers the twin's lever for both cars (twincar shifterOf): its result set to the lever
-- of the car asked (the hook runs after the body; the game's own calls see it - the own lever moves again).
function TD.hookGearbox()
    CoopSyncGearHook = CoopSyncGearHook or { fixed = 0 }
    CoopSyncGearHook.on = Twin.shifterOf
    if CoopSyncGearHook.done then return end
    local car = FindFirstOf("BP_PlayerCarNew_C")
    local cls = car and car:IsValid() and car:GetClass():GetFullName():gsub("^%S+%s+", "")
    if not cls then return end
    CoopSyncGearHook.done = true
    Hook(cls .. ":GetGearboxActor", function(self, actor, valid)
        local f = CoopSyncGearHook.on
        if not f then return end
        pcall(function()
            local want = f(self:get())
            local cur = actor:get()
            if want and not (cur and cur:IsValid() and cur:GetAddress() == want:GetAddress()) then
                actor:set(want) valid:set(true)
                CoopSyncGearHook.fixed = CoopSyncGearHook.fixed + 1
            end
        end)
    end)
end
function TD.hookCarLights()
    pcall(TD.hookHorn)
    pcall(TD.hookRadio)
    pcall(TD.hookGearbox)
    CoopSyncCarLightHook = CoopSyncCarLightHook or {}
    CoopSyncCarLightHook.on = function(a) if Twin.isTwin(a) then Twin.applyBodyLights(a) else Twin.applyHeldLights(a) end end
    if CoopSyncCarLightHook.done then return end
    local car = FindFirstOf("BP_PlayerCarNew_C")
    local cls = car and car:IsValid() and car:GetClass():GetFullName():gsub("^%S+%s+", "")
    if not cls then return end -- (no car yet: again from TD.equipTick)
    CoopSyncCarLightHook.done = true
    Hook(cls .. ":ElectronicUpdate_All", function(self)
        local f = CoopSyncCarLightHook.on
        if f then pcall(f, self:get()) end
    end)
end
function TD.hookHighlight()
    CoopSyncHighlightHook = CoopSyncHighlightHook or {}
    CoopSyncHighlightHook.on = TD.onHighlightPress
    if CoopSyncHighlightHook.done then return end
    local hm = FindFirstOf("BP_HighlightManager_C")
    local cls = hm and hm:GetClass():GetFullName():gsub("^%S+%s+", "")
    if not cls then return end
    CoopSyncHighlightHook.done = true
    pcall(Hook, cls .. ":HighlightPress", function(_, isPress)
        local ok, v = pcall(function() return isPress:get() end)
        local f = CoopSyncHighlightHook.on
        if f and ok then pcall(f, v) end
    end)
end

local function ghostBoard(pawn)
    local g, tag, best = TD.nearGhostDoor(pawn)
    if not g then return nil end
    local twin = Twin.isTwin(g)
    -- a twin's doors only through the game's highlight (above): standing near one without looking at it is nothing
    if twin then return nil end
    -- the other player sits there: no getting in at this door (like the real car's doors)
    if seatTakenByOther(tag, best) then st.ghostDoorTaken = (st.ghostDoorTaken or 0) + 1 return nil end
    do
        setWalking(pawn, false)
        pcall(function() pawn:K2_AttachToActor(g, FName("None"), 1, 1, 1, false) end)
        local r = seatRel(best)
        pcall(function() pawn:K2_SetActorRelativeLocation({ X = r.X, Y = r.Y, Z = r.Z + 90 }, false, {}, true) end)
    end
    inGhost = { tag = tag, seat = nil, pending = false, entry = { X = SEAT_DOOR[best].X, Y = SEAT_DOOR[best].Y }, twin = twin, since = M.nowMs() }
    if tag == "H" then myAssigned, seatPending = nil, false end
    st.ghostBoarded = (st.ghostBoarded or 0) + 1
    return best
end

-- Get out of the other's car: detached, standing outside the door of the seat, walking again.
ghostLeave = function(pawn, reason)
    if not inGhost then return end
    local g = ghostOf(inGhost.tag)
    local door = SEAT_DOOR[inGhost.seat or 0] or inGhost.entry or SEAT_DOOR[1]
    if inGhost.twin then
        -- the door opens for the way out and shuts behind (owner: getting in showed the door, getting out not)
        local n = inGhost.seat or inGhost.door
        if n and reason ~= "car gone" and reason ~= "owner left" then
            TD.sendDoor(n, "open")
            TD.exitShut = { n = n, at = M.nowMs() + TD.EXIT_SHUT_MS }
        end
        pcall(twinControlsRestore)
        if g then pcall(function() g.FirstPersonCamera:K2_SetRelativeRotation({ Pitch = 0, Yaw = 0, Roll = 0 }, false, {}, true) end) end
        Twin.leave(pawn, true) -- the game's exit, the manager back to the own car
        pcall(TD.restoreDoorStates)
    end
    pcall(function() pawn:K2_DetachFromActor(1, 1, 1) end)
    if g then
        local w = toWorld(g, { X = door.X, Y = door.Y * 1.5, Z = 0 })
        pcall(function() pawn:K2_SetActorLocation({ X = w.X, Y = w.Y, Z = w.Z + 120 }, false, {}, true) end)
    end
    setWalking(pawn, true)
    if inGhost.tag == "H" then myAssigned, seatPending = nil, false end
    inGhost = nil
    st.ghostLeft = (st.ghostLeft or 0) + 1
    st.lastGhostLeave = reason
end
-- Driving a ghost: the game's car input does not reach it (the player is attached to plain mesh actors, not in
-- a car), but the character's own input events still fire every frame: Command Move Forward/Backward (W/S),
-- Command Move Left/Right (A/D), Command Jump (space). Pre-hooks keep their newest values; the driver's
-- input for the owner = throttle (W), brake (S while moving) or reverse (S at a stop: negative throttle, what the
-- game's pedal handling makes of it), steer (A/D), handbrake (space held).
local ghostAxes = { fwd = 0, right = 0, hb = 0, ms = -1e9, fwdMs = -1e9, rightMs = -1e9 }
local REVERSE_BELOW = 150 -- units/s: S below this speed backs up
-- an axis = its newest non-zero value while that is under AXIS_HOLD_MS old: several callers may report the
-- axis in one frame (observed: the game's own 0 every frame next to a test's 1.0); a released key reads 0
-- again after AXIS_HOLD_MS
local AXIS_HOLD_MS = 60
local function axis(what)
    return (M.nowMs() - ghostAxes[what .. "Ms"] <= AXIS_HOLD_MS) and ghostAxes[what] or 0
end
local function ghostInput(sample)
    if M.nowMs() - ghostAxes.ms > 250 then return { 0, 0, 0, 0 } end
    local speed = 0
    if sample and sample.vel then speed = math.sqrt(sample.vel.X ^ 2 + sample.vel.Y ^ 2) end
    local f, th, br = axis("fwd"), 0, 0
    if f >= 0 then th = f elseif speed < REVERSE_BELOW then th = f else br = -f end
    return { th, br, axis("right"), ghostAxes.hb }
end
-- In a twin the game's in-car input still goes to the own car (its input graph): looking around (LookLeftRight /
-- LookUpDown: ~1 degree per axis unit, measured) turns the twin's FirstPersonCamera here, within the car's own
-- limits; E (Interact) looks at what the player faces: the key -> the owner's ignition on / off, the drive lever ->
-- drive / park (K to the host, KG to the client; the key and lever move on the twin with the owner's pose), else
-- getting out.
--   KG <time> ign|gear|lights|top|wipers <value>     host -> client: the host turned the key / moved the lever / a
--                                                    switch of the client's car (K: client -> host)
local INTERACT_COS = math.cos(math.rad(14))
local lastTwinInteract = -1e9
local function twinLook(dx, dy)
    local g = inGhost and ghostOf(inGhost.tag)
    if not g then return end
    inGhost.yaw, inGhost.pitch = (inGhost.yaw or 0) + dx, (inGhost.pitch or 0) - dy
    pcall(function()
        local ym, pm = g.CameraYawMinMaxAngles, g.CameraPitchMinMaxAngles
        inGhost.yaw = math.max(ym.X, math.min(ym.Y, inGhost.yaw))
        inGhost.pitch = math.max(pm.X, math.min(pm.Y, inGhost.pitch))
    end)
    pcall(function() g.FirstPersonCamera:K2_SetRelativeRotation({ Pitch = inGhost.pitch, Yaw = inGhost.yaw, Roll = 0 }, false, {}, true) end)
end
local function twinInteract(pawn)
    local now = M.nowMs()
    if now - lastTwinInteract < 400 then return end -- the character's and the car's interact both report one press
    lastTwinInteract = now
    local g = ghostOf(inGhost.tag)
    if not g then return end
    local pc = (CoopSyncFirst or FindFirstOf)("PlayerController")
    local cam, fwd
    pcall(function()
        local cm = pc.PlayerCameraManager
        cam = cm:GetCameraLocation()
        fwd = KML:GetForwardVector(cm:GetCameraRotation())
    end)
    local function facing(path)
        local c = path and Sync.deref(path)
        if not (c and cam and fwd) then return false end
        local p = c:K2_GetComponentLocation()
        local d = { X = p.X - cam.X, Y = p.Y - cam.Y, Z = p.Z - cam.Z }
        local l = math.sqrt(d.X * d.X + d.Y * d.Y + d.Z * d.Z)
        return l > 1 and l < 200 and (d.X * fwd.X + d.Y * fwd.Y + d.Z * fwd.Z) / l > INTERACT_COS
    end
    -- the twin's dash levers / top light / radio: the game's own (Twin.muteBody gives them back inside), not getting out
    local _, hl = Twin.highlightedBody()
    if hl == "TopLight" or hl == "LeftHandle" or hl == "RightHandle" or Twin.highlightedRadio() then return end
    local comps = Twin.poseParts(g)
    local what
    if facing(comps.KeyCylinder_Temp) then what = "ign" elseif facing(comps["SH.MainMesh"]) then what = "gear" end
    if what and inGhost.seat ~= 1 then what = nil end
    -- the lever: the game itself acts (its highlight works in the twin) on the car manager, which holds the owner's
    -- state while the player sits here - twinControls sends the change to the owner
    if what == "gear" then return end
    -- the key: the game's own key does nothing in a twin (held 2 s, graphics: the manager stays 0 - its start check
    -- finds no battery / fuel of its own: the twin's parts are unbound) -> the owner's ignition toggled from here
    if what == "ign" then
        local ctlNow = inGhost.tag == "H" and target.hostCtl or target.guestCtl
        local cur = ctlNow and ctlNow.ign
        if cur == nil or cur < 0 then return end
        local v = (cur == 0) and 2 or 0
        append(outFile, string.format("%s\t%d\tign\t%d", inGhost.tag == "H" and "K" or "KG", now, v))
        st.twinCtlSent = (st.twinCtlSent or 0) + 1
        if inGhost.expect then inGhost.expect.ign, inGhost.ctlHold = v, now + 1500 end -- (CTL_HOLD_MS, declared below)
        pcall(function() (CoopSyncFirst or FindFirstOf)("BP_CarManager_C").CarIgnitionState = v end) -- (else twinControls took the old value for a change)
        return
    end
    TD.twinExit(pawn)
end
-- Out of a twin the game's way (owner, alpha 16: "I got out of the friend's car with no animation, a teleport"): the
-- game's animated exit ("Exit Car"(false, false): probed on a twin - the character goes out through the side over ~1.1 s,
-- then lets go of the car), the manager kept on the twin until then - switched to the own car at once, the game's exit
-- ended at the OWN car's exit point, 7 m away. The door opens for it (DR to the owner) and shuts behind.
TD.EXIT_ANIM_MS = 4000
function TD.twinExit(pawn)
    if not inGhost or inGhost.exitAt then return end
    local n = inGhost.seat or inGhost.door
    if n then
        TD.sendDoor(n, "open")
        TD.exitShut = { n = n, at = M.nowMs() + TD.EXIT_SHUT_MS }
    end
    pcall(twinControlsRestore)
    inGhost.exitAt = M.nowMs()
    if not pcall(function() pawn["Exit Car"](pawn, false, false) end) then ghostLeave(pawn, "player got out") end
    st.twinExits = (st.twinExits or 0) + 1
end
-- The car manager's door states are the own car's (its doors, the dash's door arrows, which door spots show); the twin's
-- doors, worked by the game while the player sits there (its exit), wrote theirs into them (cars-test: the guest's own
-- hood "open" after getting out of the host's car). Read on getting in, put back after getting out.
function TD.readDoorStates(m)
    local s = {}
    pcall(function() m.DoorStates:ForEach(function(k, v) s[k:get()] = v:get() end) end)
    return s
end
function TD.restoreDoorStates()
    -- (again for 3 s: the twin's door shuts after the exit and writes its state once more)
    local snap = TD.doorSnap
    if not TD.doorSnapUntil then TD.doorSnapUntil = M.nowMs() + 3000 end
    if M.nowMs() > TD.doorSnapUntil then TD.doorSnap, TD.doorSnapUntil = nil, nil return end
    local m = (CoopSyncFirst or FindFirstOf)("BP_CarManager_C")
    if not (snap and m and m:IsValid()) then return end
    -- (the doors' and the trunk's flags from the own car's real doors - open = its mesh simulates: the snapshot was taken
    -- in the twin, after the twin's door had opened for the player and written that (cars-test: the guest's own RL door
    -- "open" for good); the hood, no door actor, from the snapshot)
    local want = {}
    for k, v in pairs(snap) do want[k] = v end
    local own = Twin.ownCar()
    for k, n in pairs({ [0] = 1, [1] = 2, [2] = 3, [3] = 4, [5] = 5 }) do
        if own and Twin.door(own, n) then want[k] = Twin.doorOpen(own, n) end
    end
    local cur = TD.readDoorStates(m)
    for k, v in pairs(want) do
        if cur[k] ~= nil and cur[k] ~= v then pcall(function() m:SetDoorState(k, v) end) st.doorStatesBack = (st.doorStatesBack or 0) + 1 end
    end
end
function M.doorLog() return table.concat(TD.drLog, " ") end
function M.dbgDoor(n)
    local tw = ghostOf(otherTag())
    local m = Native.manager()
    return string.format("owner_open=%s sim=%s shut_here=%s ctx_twin=%s now=%d pose=%s", tostring(TD.ownerDoorOpen(n)), tostring(Twin.doorOpen(tw, n)),
        tostring(TD.doorShutHere[n]), tostring(m.NewCarActor:GetAddress() == tw:GetAddress()), M.nowMs(), tostring(target.pose and target.pose:match("D" .. n .. "%.MainMesh=[^;]+")))
end
-- (tests / probes: one native tick and the door reconcile now, their errors returned)
function M.nativeTickNow()
    local ok, e = pcall(TD.nativeTick)
    local tw = ghostOf(otherTag())
    local ok2, e2 = pcall(TD.twinDoorReconcile, tw)
    local ok3, e3 = pcall(TD.nativeDoorWatch, tw)
    return string.format("tick=%s %s | reconcile=%s %s | watch=%s %s", tostring(ok), tostring(e), tostring(ok2), tostring(e2), tostring(ok3), tostring(e3))
end
function M.ownDoorFlags()
    local own = Twin.ownCar()
    local m = (CoopSyncFirst or FindFirstOf)("BP_CarManager_C")
    local s
    if TD.native and own and Native.ctx and Native.ctx ~= Sync.ref(own) then
        s = {}
        for k, v in pairs(Native.doors[Sync.ref(own)] or {}) do s[k] = v end
        for k, v in pairs(Native.realDoors(own)) do s[k] = v end
    else s = TD.readDoorStates(m) end
    local o = {}
    for k, v in pairs(s) do if v then o[#o + 1] = tostring(k) end end
    table.sort(o)
    return #o == 0 and "none" or table.concat(o, ",")
end
function M.nativeInfo()
    if not Native then return "-" end
    local loc = {}
    for n in pairs(Twin.doorLocal or {}) do loc[#loc + 1] = n end
    return Native.info() .. " aimed=" .. tostring(TD.aimed and TD.aimed.n) .. " ctx_switches=" .. (st.ctxSwitches or 0) ..
        " native_doors_sent=" .. (st.nativeDoorsSent or 0) .. " last_native_door=" .. tostring(st.lastNativeDoor) ..
        " doors_local=" .. table.concat(loc, ",") .. " shut_here=" .. (st.twinDoorsShutHere or 0) .. " opened_here=" .. (st.twinDoorsOpenedHere or 0) .. " posed_again=" .. (st.twinDoorsPosed or 0) .. " shut_press=" .. (st.shutPressSent or 0) .. " flags_followed=" .. (st.doorFlagsFollowed or 0) .. " exit_doors_shut=" .. (st.exitDoorsShut or 0) ..
        " driving=" .. tostring(TD.driving) .. " driven_by=" .. tostring(TD.drivenBy) .. " lost_list=" .. table.concat(Native.lostList or {}, ";") .. " slots_fixed=" .. tostring(CoopSyncSlotHook and CoopSyncSlotHook.fixed) .. " reach_denied=" .. tostring(CoopSyncReachHook and CoopSyncReachHook.denied)
end
function M.doorSnapInfo() return string.format("snap=%s until=%s back=%d", tostring(TD.doorSnap ~= nil), tostring(TD.doorSnapUntil), st.doorStatesBack or 0) end
-- (sendTick: the character let go of the twin in its exit - the manager back to the own car, the rest as a leave)
function TD.twinExitDone(pawn)
    local g = ghostOf(inGhost.tag)
    if g then pcall(function() g.FirstPersonCamera:K2_SetRelativeRotation({ Pitch = 0, Yaw = 0, Roll = 0 }, false, {}, true) end) end
    Twin.managerToOwn()
    TD.restoreDoorStates()
    if inGhost.tag == "H" then myAssigned, seatPending = nil, false end
    inGhost = nil
    st.ghostLeft = (st.ghostLeft or 0) + 1
    st.lastGhostLeave = "player got out (animated)"
end

-- Tests: turn the look in the twin onto one of its pose components (KeyCylinder_Temp, SH.MainMesh, ...).
function M.botTwinLookAt(name)
    local g = inGhost and inGhost.twin and ghostOf(inGhost.tag)
    if not g then return "not in a twin" end
    local c = Sync.deref(Twin.poseParts(g)[name])
    if not c then return "no " .. name end
    local cam = (CoopSyncFirst or FindFirstOf)("PlayerController").PlayerCameraManager:GetCameraLocation()
    local p = c:K2_GetComponentLocation()
    local d = KML:InverseTransformDirection(g:GetTransform(), { X = p.X - cam.X, Y = p.Y - cam.Y, Z = p.Z - cam.Z })
    local yaw = math.deg(math.atan(d.Y, d.X))
    local pitch = math.deg(math.atan(d.Z, math.sqrt(d.X * d.X + d.Y * d.Y)))
    twinLook(yaw - (inGhost.yaw or 0), -(pitch - (inGhost.pitch or 0)))
    return string.format("looking at %s: yaw %.1f pitch %.1f", name, inGhost.yaw, inGhost.pitch)
end
-- (tests / probes: the twin module)
function M.twinModule() return Twin end
-- the own car's back door aimed at (3 / 4) or nil (cars-test)
function M.ownBackDoorAimed() return TD.ownBackDoorAimed() end
-- (tests: the seat this side's player sits on now, and whether it may reach a highlight of its own car by name)
function M.seatNowN() return TD.seatNow and TD.seatNow.n or 0 end
-- (tests: the other's trunk box opened here - the menu pointed at its container)
function M.trunkInfo() return string.format("trunk_menu=%d last_menu=%s trunk_refresh=%d", st.trunkMenuPointed or 0, tostring(st.lastTrunkMenu), st.trunkRefreshBack or 0) end
-- (tests: the empty doorways - where the camera's line passes them, and the E presses)
function M.doorwayInfo()
    local dw = TD.lookedAtDoorway()
    return string.format("looked=%s seen=%s presses=%d doorway_presses=%d aimed=%s doorless=%d own_enter=%s", dw and ((dw.own and "own" or dw.tag) .. dw.n) or "none", tostring(TD.doorwaySeen), st.highlightPresses or 0, st.doorwayPresses or 0, tostring(TD.aimed and TD.aimed.n), st.doorlessEntries or 0, tostring(st.ownEnter))
end
function M.ownSeatDevice(n) local own = Twin.ownCar() return tostring(own and seatDevice(own, n)) end
function M.mayReachOwn(name)
    local own = Twin.ownCar()
    local hc = own and own[name]
    if not (hc and hc:IsValid()) then return "no " .. name end
    return tostring(TD.passengerMayReach(hc))
end
function M.twinCtlInfo()
    local function ltw(c) local t = c and c.ltw return t and TD.fmtLtw(t) or "-" end
    return string.format("twin_ctl_sent=%d ctl_applied=%d host_ctl=%s guest_ctl=%s host_ltw=%s guest_ltw=%s own_ltw=%s last_ltw_sent=%s last_ltw_done=%s",
        st.twinCtlSent or 0, st.ctlApplied or 0,
        target.hostCtl and (tostring(target.hostCtl.ign) .. "/" .. tostring(target.hostCtl.gear)) or "-",
        target.guestCtl and (tostring(target.guestCtl.ign) .. "/" .. tostring(target.guestCtl.gear)) or "-",
        ltw(target.hostCtl), ltw(target.guestCtl), TD.ownLtw(), tostring(st.lastLtwSent), tostring(st.lastLtwDone))
end

local function onPawnInput(what, v)
    if M.stopped then return end
    -- (native cars: every E is the game's own - into / out of either car, its key, levers, doors; but a tap at a back
    -- door of the other's car: the mod starts the game's entry there)
    if TD.native and (what == "interact" or what == "carInteract") then
        if v == true then TD.lastInteractMs = M.nowMs() end
        if what == "interact" and v ~= true and TD.doorPress then
            local press, pawn = TD.doorPress, localPawn()
            TD.doorPress = nil
            if pawn and not inGhost and M.nowMs() - press.ms < TD.HOLD_MS then TD.twinDoorTap(pawn, press) end
        end
        return
    end
    if what == "interact" or what == "carInteract" then
        local pawn = localPawn()
        if v ~= true then
            -- E released before the hold: a tap at the twin's door
            local press = TD.doorPress
            TD.doorPress = nil
            if what == "interact" and press and pawn and M.nowMs() - press.ms < TD.HOLD_MS then TD.twinDoorTap(pawn, press) end
            return
        end
        if not pawn then return end
        -- (the other's open trunk lid with nothing highlighted on it: TD.lookedAtOpenLid)
        if what == "interact" and not inGhost and not TD.doorPress then
            local lw, ln = TD.lookedAtOpenDoor()
            if lw then TD.doorPress = { tag = otherTag(), n = ln, ms = M.nowMs() } return end
        end
        if inGhost and inGhost.twin then twinInteract(pawn)
        elseif what == "carInteract" then return -- (the own car's own business)
        elseif inGhost then ghostLeave(pawn, "player got out")
        elseif not Sync.parentOf(pawn) then ghostBoard(pawn) end
    elseif (what == "carLookX" or what == "carLookY") and inGhost and inGhost.twin then
        local x = tonumber(v) or 0
        if what == "carLookX" then twinLook(x, 0) else twinLook(0, x) end
    elseif what == "fwd" or what == "right" then
        local x, now = tonumber(v) or 0, M.nowMs()
        ghostAxes.ms = now
        if x ~= 0 then ghostAxes[what], ghostAxes[what .. "Ms"] = x, now end
    elseif what == "jump" then ghostAxes.hb = (tonumber(v) == 0) and 1 or 0 -- InputPressRelease: 0 pressed, 1 released
    elseif (what == "carFwd" or what == "carRight" or what == "carHb") and inGhost and inGhost.twin then
        -- in a twin the game sends the pedals / wheel to the own car (its input binding): the axes of these calls
        -- are this driver's input for the twin's owner
        local x, now = tonumber(v) or 0, M.nowMs()
        ghostAxes.ms = now
        if what == "carHb" then ghostAxes.hb = x > 0.5 and 1 or 0
        else
            local k = what == "carFwd" and "fwd" or "right"
            if x ~= 0 then ghostAxes[k], ghostAxes[k .. "Ms"] = x, now end
        end
    end
end
-- pre-hooks on the local character's input functions (once per Lua state; they call the current module)
local function hookPawn()
    CoopSyncPawnHooks = CoopSyncPawnHooks or { done = {} }
    CoopSyncPawnHooks.on = onPawnInput
    local pawn = localPawn()
    if not pawn then return end
    local cls = pawn:GetClass():GetFullName():gsub("^%S+%s+", "")
    local fns = { ["Command Interact"] = "interact", ["Command Move Forward/Backward"] = "fwd",
        ["Command Move Left/Right"] = "right", ["Command Jump"] = "jump" }
    -- the car interface the game calls with the driver's axes (on the own car - see onPawnInput)
    local car = Twin and Twin.ownCar()
    local carCls = car and car:GetClass():GetFullName():gsub("^%S+%s+", "")
    local list = {}
    for fn, what in pairs(fns) do list[#list + 1] = { cls .. ":" .. fn, what } end
    if carCls then
        for fn, what in pairs({ AccelerateBrake = "carFwd", SteerLeftRight = "carRight", HANDBRAKE = "carHb",
            LookLeftRight = "carLookX", LookUpDown = "carLookY", Interact = "carInteract" }) do list[#list + 1] = { carCls .. ":" .. fn, what } end
    end
    for _, e in ipairs(list) do
        local path, what = e[1], e[2]
        if not CoopSyncPawnHooks.done[path] and isFunction(path) then
            CoopSyncPawnHooks.done[path] = true
            pcall(Hook, path, function(_, p1)
                local ok, v = pcall(function() return p1:get() end)
                if CoopSyncPawnHooks.on then pcall(CoopSyncPawnHooks.on, what, ok and v or nil) end
            end)
        end
    end
end

-- No "get in" at a door whose seat the other player sits on (owner): the game's door asks K2_ShouldHighlight before
-- showing its prompt and taking the interact; the hook returns false for such a door of this side's real car
-- (UE4SS: a hook's return value replaces the function's). Probed: the prompt is gone and E does not get in.
-- the driver's door's E handlers (open / get in) parked while the other player sits at that wheel (twincar parkEntry);
-- looked at again at most once a second per car and state (the game asks K2_ShouldHighlight every frame it is aimed at)
TD.parkSt = {}
function TD.entryPark(car, park)
    if not (car and car:IsValid()) then return end
    local key, now = car:GetAddress(), M.nowMs()
    local p = TD.parkSt[key]
    if p and p.on == park and now - p.at < 1000 then return end
    TD.parkSt[key] = { on = park, at = now }
    pcall(Twin.parkEntry, car, 1, park)
end
local function doorBlocked(door)
    if M.stopped or not door then return false end
    local par = door:GetAttachParentActor()
    -- the own real car's doors; native cars: the other's twin's too (the game's own E there gets in)
    local own = Twin and Twin.ownCar()
    if not (par and par:IsValid()) then return false end
    local realTag
    if own and par:GetAddress() == own:GetAddress() then realTag = (role == "client" and ownCar) and "G" or "H"
    elseif TD.native and Twin.isTwin(par) then realTag = otherTag()
    else return false end
    local l = toCar(par, door:K2_GetActorLocation())
    local n = doorSeat(l.X, l.Y)
    -- (the driver's door only: a back / passenger door the game just opens, its seat the mod's entry - which refuses a
    -- taken one; that door stays to open / shut / take off, owner's alpha 19 item 14)
    -- (not hidden any more: its E handlers are parked while the seat is taken - TD.entryPark; owner's alpha 20 test: a
    -- hidden door could not be taken off or put on while the other player sat at the wheel)
    if n == 1 then TD.entryPark(par, seatTakenByOther(realTag, n)) end
    return false
end
-- Getting out of the own car with a twin around (owner, alpha 16: "no door animation, I walked out through it"): the
-- car's ExitDoor handler finds "the driver's door" by a lookup of its own that answers the twin's (traced: AttemptOpen /
-- AttemptDoorExit on the TWIN's door, then AttemptShut 1.1 s later; the same kind as GetGearboxActor - the twin, spawned
-- later, wins). The hooks run after the twin door's body: the own car's door of that number does it too, the twin's
-- goes back (its doors are the owner's pose), and the shut that follows is redirected the same way.
local function carOfPart(a)
    local car, g = a, 0
    while g < 10 do
        local p = car:GetAttachParentActor()
        if not (p and p:IsValid()) then break end
        car, g = p, g + 1
    end
    return car
end
-- Out of the own car's back seat (owner's two-games test 2026-11-11: "out of the back seat by the back door the driver's
-- door opened, I went through the back door"): the game's exit works the driver's door only (its animation's door; a
-- back door's slot made the exit a jump - TD.contextSlot). On the own car that door really swung open (on the other's
-- twin it is kinematic - TD.twinDoorReconcile shuts it there). So right after its AttemptDoorExit (the hook runs after
-- the body) the driver's door is hidden while it swings and the seat's own door opens, shut again TD.EXIT_SHUT_MS
-- later as the game shuts the driver's. backseat-test.
function TD.backSeatExit(own, n)
    local d1, dn = Twin.door(own, 1), TD.realDoor(own, n)
    TD.doorGuard = true
    -- (the driver's door swings unseen: shut at once the game's exit waited for it and never let go of the player -
    -- backseat-test; on the twin it stays open TD.EXIT_DOOR_MS for that)
    pcall(function() d1.MainMesh:SetVisibility(false, true) end)
    if dn then pcall(function() dn:AttemptOpen() end) end
    TD.doorGuard = false
    local dp, d1p = dn and Sync.ref(dn), Sync.ref(d1)
    CoopSyncAfter(TD.EXIT_SHUT_MS, function()
        local d2 = dp and Sync.deref(dp)
        if d2 then TD.doorGuard = true pcall(function() d2:AttemptShut() end) TD.doorGuard = false end
    end)
    -- (seen again once the game's own shut has it home)
    CoopSyncAfter(TD.EXIT_SHUT_MS + 1500, function()
        local d = Sync.deref(d1p)
        if d then pcall(function() d.MainMesh:SetVisibility(true, true) end) end
    end)
    st.backSeatExits = (st.backSeatExits or 0) + 1
end
function TD.onDoorCall(door, what)
    if what == "exit" and not (M.stopped or TD.doorGuard) and door and door:IsValid() and TD.ownSeat and TD.ownSeat.n ~= 1 then
        local own = Twin.ownCar()
        local d1 = own and Twin.door(own, 1)
        if d1 and d1:GetAddress() == door:GetAddress() then TD.backSeatExit(own, TD.ownSeat.n) return end
    end
    -- (native: the game's own shut of a door of the other's twin - its entry's shut, the player's E - swung it into its
    -- frame and it bounced open again on the kinematic car, then shut a second time (owner's two-games test 2026-11-11:
    -- "the back door tries to shut, stays open, then shuts"; backseat-test: 55 -> 4 -> 40 -> 0 deg): the door is taken
    -- off its physics at once and eased shut, the owner's late open poses held off meanwhile.)
    if what == "shut" and TD.native and not (M.stopped or TD.doorGuard) and door and door:IsValid() then
        local tw = carOfPart(door)
        if tw and Twin.isTwin(tw) then
            for k = 1, 5 do
                local d = Twin.door(tw, k)
                if d and d:GetAddress() == door:GetAddress() and Twin.doorOpen(tw, k) then
                    pcall(function()
                        local mesh = d.MainMesh
                        mesh:SetSimulatePhysics(false)
                        mesh:K2_AttachToComponent(d.RootComponent, FName("None"), 1, 1, 1, true)
                    end)
                    Twin.forgetDoorPose(tw, k)
                    pcall(Twin.shutEase, tw, k, 1.5)
                    TD.doorShutHere[k] = M.nowMs()
                    st.twinShutsEased = (st.twinShutsEased or 0) + 1
                end
            end
        end
    end
    if M.stopped or TD.doorGuard or TD.native or not (door and door:IsValid()) then return end -- (native: TD.seatEntryPoint)
    local twin = carOfPart(door)
    if not Twin.isTwin(twin) then return end
    local n
    for k = 1, 5 do
        local d = Twin.door(twin, k)
        if d and d:GetAddress() == door:GetAddress() then n = k end
    end
    if not n then return end
    local pawn, own = localPawn(), Twin.ownCar()
    local now = M.nowMs()
    local redirect = false
    if what == "exit" then
        -- (the local player leaves its own car: not in a twin)
        local par = pawn and Sync.parentOf(pawn)
        redirect = not inGhost and own and par and par:GetAddress() == own:GetAddress()
    end
    -- (the shut that follows is not redirected: shuts on a twin's door also come from its pose, earlier or later than
    -- the game's - under load one shut the own door 0.8 s into the exit, half open. The own door is shut 1.2 s after,
    -- when the game's own exit shuts it.)
    if not redirect then return end
    TD.doorGuard = true
    local od = own and Twin.door(own, n)
    pcall(function()
        -- (the game's own exit opens the door first: AttemptOpen, then AttemptDoorExit - the exit alone opened it part way)
        if od then od:AttemptOpen() od:AttemptDoorExit() end
        door:AttemptShut() -- (the twin's door back: the owner's pose shows it)
    end)
    TD.doorGuard = false
    local odPath = od and Sync.ref(od)
    if odPath then
        CoopSyncAfter(TD.EXIT_SHUT_MS, function()
            local d2 = Sync.deref(odPath)
            if d2 then TD.doorGuard = true pcall(function() d2:AttemptShut() end) TD.doorGuard = false end
        end)
    end
    st.exitDoorRedirected = (st.exitDoorRedirected or 0) + 1
end
local function hookDoors()
    CoopSyncDoorHooks = CoopSyncDoorHooks or {}
    CoopSyncDoorHooks.blocked = doorBlocked
    CoopSyncDoorHooks.call = TD.onDoorCall
    CoopSyncDoorHooks.catShow = TD.catShow
    CoopSyncDoorHooks.trunkRefreshed = TD.trunkRefreshed
    CoopSyncDoorHooks.trunkOpened = TD.trunkOpened
    if CoopSyncDoorHooks.done then return end
    local d = FindFirstOf("BP_CarPart_Door_Base_C")
    local cls = d and d:GetClass():GetFullName():gsub("^%S+%s+", "")
    if not cls then return end
    CoopSyncDoorHooks.done = true
    -- the twin's door spots (slot interactive parts): shown by the game while the LOCAL player's own door of that slot
    -- is shut (the car manager's door states): with its own door open, the player could not take the other's car's
    -- door at all (cars-test). On a twin: shown while the owner's door is shut (the pose), its open door is pressed by
    -- looking at it (TD.lookedAtOpenDoor).
    local ci = FindFirstOf("BP_CarPart_Interactive_C")
    local ccls = ci and ci:GetClass():GetFullName():gsub("^%S+%s+", "")
    if ccls then
        pcall(Hook, ccls .. ":K2_ShouldHighlight", function(self)
            local f = CoopSyncDoorHooks.catShow
            if not f then return end
            local ok, show = pcall(f, self:get())
            if ok and show ~= nil then return show end
        end)
    end
    for fn, what in pairs({ AttemptDoorExit = "exit", AttemptShut = "shut" }) do
        pcall(Hook, cls .. ":" .. fn, function(self)
            local f = CoopSyncDoorHooks.call
            if f then pcall(f, self:get(), what) end
        end)
    end
    -- the trunk storage's RefreshTrunkInventory (the game calls it on the trunk's changes) points the storage at the
    -- inventory manager's trunk = the LOCAL player's own: on a twin that showed the player's own loot in the other's
    -- trunk box (owner, alpha 16; cmds/store-point.lua). Pointed back at once (a pre-hook runs after the body).
    pcall(Hook, "/Game/Gameplay/Inventory/Items/Car/Storage/BP_Storage_Trunk_Base.BP_Storage_Trunk_Base_C:RefreshTrunkInventory", function(self)
        local f = CoopSyncDoorHooks.trunkRefreshed
        if f then pcall(f, self:get()) end
    end)
    -- opening a trunk storage (its E) opens the inventory manager's trunk - the LOCAL player's own - whatever car it is
    -- in (OpenCarInventories -> OpenInventoryContainer(Inventory_Trunk); owner 2026-11-09: "I open the friend's trunk
    -- and see my own things"): the menu is pointed at the twin's own container after (the hook runs after the body)
    pcall(Hook, "/Game/Gameplay/Inventory/Items/Car/Storage/BP_Storage_Trunk_Base.BP_Storage_Trunk_Base_C:BndEvt__Highlight_K2Node_ComponentBoundEvent_0_OnHighlightInteract__DelegateSignature", function(self)
        local f = CoopSyncDoorHooks.trunkOpened
        if f then pcall(f, self:get()) end
    end)
    pcall(Hook, cls .. ":K2_ShouldHighlight", function(self)
        local f = CoopSyncDoorHooks.blocked
        if not f then return end
        local ok, blocked = pcall(function() return f(self:get()) end)
        if ok and blocked then
            CoopSyncDoorHooks.hidden = (CoopSyncDoorHooks.hidden or 0) + 1
            return false
        end
    end)
end

---------------------------------------------------------------------------------------------------
-- kicking the other player (owner): the game's own kick (BP_MainCharacterManager_C:PlayerKick, the kick key) next to
-- the other player's puppet -> KK to it, its character is knocked back (LaunchCharacter).
--   KK <time> dx dy      the kick's direction (unit, world XY)
local KICK_REACH, KICK_COS = 170, math.cos(math.rad(55)) -- in front of the kicker, within this distance / cone
local KICK_SPEED, KICK_UP = 550, 250
TD.KICK_DMG = 0.01 -- of the kicked player's max health (owner's alpha 19 item 17)
local KICK_COOLDOWN_MS = 600
local lastKickMs = -1e9
local function kickCheck()
    if M.stopped or not outFile then return end
    local pawn, p = localPawn(), Sync.deref(puppetPath)
    if not (pawn and p) or st.playerGone or Sync.parentOf(pawn) then return end
    if not (target.player and (target.player.seat or 0) == 0) then return end -- a seated player is not kicked
    local now = M.nowMs()
    if now - lastKickMs < KICK_COOLDOWN_MS then return end
    local me = pawn:K2_GetActorLocation()
    local it = p:K2_GetActorLocation()
    local zOff = meshRel and meshRel.loc.Z or 0
    local dx, dy, dz = it.X - me.X, it.Y - me.Y, (it.Z - zOff) - me.Z
    local d = math.sqrt(dx * dx + dy * dy)
    st.kickTries = (st.kickTries or 0) + 1
    if d > KICK_REACH or math.abs(dz) > 120 or d < 1 then return end
    local yaw = math.rad((CoopSyncFirst or FindFirstOf)("PlayerController"):GetControlRotation().Yaw)
    local fx, fy = math.cos(yaw), math.sin(yaw)
    if (dx * fx + dy * fy) / d < KICK_COS then return end
    lastKickMs = now
    append(outFile, string.format("KK\t%d\t%.3f\t%.3f", now, dx / d, dy / d))
    st.kicksSent = (st.kicksSent or 0) + 1
end
-- the other player kicked this one
local function kicked(dx, dy)
    local pawn = localPawn()
    if not pawn or Sync.parentOf(pawn) or inGhost then return end
    -- (the movement mode and speed limit at the kick, the way it went: a kick moved the host 53-72 instead of ~290 now
    -- and then, quick suite 2026-11-10)
    pcall(function()
        local cm = pawn.CharacterMovement
        st.kickAt = string.format("mode=%s max=%.0f dir=%.2f,%.2f", tostring(cm.MovementMode), cm.MaxWalkSpeed, dx, dy)
    end)
    pcall(function() pawn:LaunchCharacter({ X = dx * KICK_SPEED, Y = dy * KICK_SPEED, Z = KICK_UP }, true, true) end)
    st.kicksTaken = (st.kicksTaken or 0) + 1
    -- and TD.KICK_DMG of the player's health (owner's alpha 19 item 17): the game's resource straight - exactly that
    -- share (a damage message goes through the game's multipliers, and did nothing at all while the health helper's
    -- playerProtected was on - for 10+ minutes in a probe, cause unknown; probed 2026-11-03)
    pcall(function()
        local h = (CoopSyncFirst or FindFirstOf)("BP_ResourceManager_C").PlayerHealth
        h:Adjust(pawn, -h.Maximum * TD.KICK_DMG)
        st.kickHealth = h.Current
    end)
end
local function hookKick()
    CoopSyncKickHooks = CoopSyncKickHooks or {}
    CoopSyncKickHooks.on = function() pcall(kickCheck) end
    if CoopSyncKickHooks.done then return end
    local mgr = FindFirstOf("BP_MainCharacterManager_C")
    local cls = mgr and mgr:GetClass():GetFullName():gsub("^%S+%s+", "")
    if not cls then return end
    CoopSyncKickHooks.done = true
    pcall(Hook, cls .. ":PlayerKick", function() if CoopSyncKickHooks.on then CoopSyncKickHooks.on() end end)
end
-- Run over by the other player's car (owner, alpha 18 item 22: "a car drives through the other player: must collide,
-- damage and push, as with the own car"). The other's car here is its twin - kinematic, moved by its owner's poses - and
-- the other player there is a puppet whose capsule blocks pawns only (one that blocked cars flipped the host's car), so
-- neither game sees the hit. Each side watches its own player on foot: the twin's footprint (its local frame, a car's
-- box) coming over the player faster than RUN.SPEED knocks the player along the car's way (LaunchCharacter) and hurts it
-- by the game's own impact message (MSG_Damage_Physical_Impact through the message system: the player's health helper
-- takes it - probed 2026-11-02; MSG_Damage_Physical itself it ignores). The other side sees it through the player's
-- own moves.
TD.RUN = { SPEED = 300, HALF_L = 250, HALF_W = 105, RADIUS = 40, HIGH = 250, COOL_MS = 1500, LEAD_S = 0.12,
    PUSH = 0.8, PUSH_MAX = 1500, SIDE = 350, UP = 400, FREE_MS = 800, DMG_PER_MS = 0.012, DMG_MAX = 40 }
TD.RUN.last, TD.RUN.prev = -1e9, {}
function TD.RUN.damage(pawn, dmg, v)
    local RUN = TD.RUN
    local path = "/Game/Systems/Messages/MSG_Damage_Physical_Impact.MSG_Damage_Physical_Impact_C"
    local c = SFO(path)
    if not (c and c:IsValid()) then pcall(function() LoadAsset((path:gsub("_C$", ""))) end) c = SFO(path) end
    local ms = (CoopSyncFirst or FindFirstOf)("MessageSystem")
    if not (c and c:IsValid() and ms and ms:IsValid()) then return false end
    local msg = StaticConstructObject(c, ms)
    msg.Damage = dmg
    msg["Normalized Intensity"] = math.min(1, dmg / RUN.DMG_MAX)
    msg.Impulse = v
    msg.HitLocation = pawn:K2_GetActorLocation()
    msg:Initialize()
    ms:DispatchMessage(msg, pawn)
    return true
end
function TD.RUN.check()
    local RUN = TD.RUN
    if M.stopped or garage then return end
    local pawn = localPawn()
    if not pawn or inGhost or Sync.parentOf(pawn) then RUN.prev = {} return end
    local now = M.nowMs()
    local me = pawn:K2_GetActorLocation()
    for _, car in ipairs({ localCar(), Sync.deref(otherCarPath) }) do
        if car and car:IsValid() and Twin.isTwin(car) then
            local k = car:GetAddress()
            local l, r = car:K2_GetActorLocation(), car:K2_GetActorRotation()
            -- (its speed over the last 0.15 s or more: the twin follows its owner's poses in steps, frame to frame
            -- it read twice the car's speed)
            local h = RUN.prev[k] or {}
            RUN.prev[k] = h
            h[#h + 1] = { l = l, t = now }
            while #h > 2 and now - h[2].t >= 150 do table.remove(h, 1) end
            local p = h[1]
            local dt = (now - p.t) / 1000
            if dt >= 0.1 and dt < 0.6 and now - RUN.last > RUN.COOL_MS then
                local v = { X = (l.X - p.l.X) / dt, Y = (l.Y - p.l.Y) / dt, Z = (l.Z - p.l.Z) / dt }
                local speed = math.sqrt(v.X * v.X + v.Y * v.Y)
                if speed > RUN.SPEED then
                    -- the player in the car's frame: ahead (x) / aside (y)
                    local yaw = math.rad(r.Yaw)
                    local dx, dy = me.X - l.X, me.Y - l.Y
                    local x = dx * math.cos(yaw) + dy * math.sin(yaw)
                    local y = -dx * math.sin(yaw) + dy * math.cos(yaw)
                    local closing = dx * v.X + dy * v.Y > 0 -- (the car comes at the player, not away)
                    -- (caught a moment early, LEAD_S of its way ahead: once the kinematic twin is over the capsule the
                    -- character is stuck in it and a launch does not move it - probed 2026-11-02)
                    local lead = speed * RUN.LEAD_S
                    local miss = math.abs(x) + math.abs(y)
                    if not RUN.near or miss < RUN.near.miss or now - RUN.near.t > 5000 then
                        RUN.near = { miss = miss, t = now, s = string.format("x=%.0f_y=%.0f_dz=%.0f_v=%.0f", x, y, me.Z - l.Z, speed) }
                    end
                    if closing and math.abs(x) < RUN.HALF_L + RUN.RADIUS + lead and math.abs(y) < RUN.HALF_W + RUN.RADIUS and math.abs(me.Z - l.Z) < RUN.HIGH then
                        RUN.last = now
                        -- along the car's way a bit faster than it, off its line, up; the capsule passes through
                        -- that car for a moment
                        local side = (y >= 0 and 1 or -1) * RUN.SIDE
                        local ux, uy = v.X / speed, v.Y / speed
                        local along = math.min(speed, RUN.PUSH_MAX) * RUN.PUSH
                        local push = { X = ux * along - uy * side, Y = uy * along + ux * side, Z = RUN.UP }
                        pcall(function()
                            local cap = pawn.CapsuleComponent
                            cap:IgnoreActorWhenMoving(car, true)
                            local path = Sync.ref(car)
                            CoopSyncAfter(RUN.FREE_MS, function()
                                local c2 = Sync.deref(path)
                                local p2 = localPawn()
                                if c2 and p2 then pcall(function() p2.CapsuleComponent:IgnoreActorWhenMoving(c2, false) end) end
                            end)
                        end)
                        pcall(function() pawn:LaunchCharacter(push, true, true) end)
                        local dmg = math.min(RUN.DMG_MAX, speed * RUN.DMG_PER_MS)
                        local okD = pcall(RUN.damage, pawn, dmg, push)
                        st.runOver = (st.runOver or 0) + 1
                        st.lastRunOver = string.format("%.0f_cm/s_%.1f_dmg_%s", speed, dmg, okD and "ok" or "failed")
                        return
                    end
                end
            end
        end
    end
end
-- The driver's side (owner's alpha 19 item 18: "a car still drives through the player"). The walker's side sees the
-- car late (the twin follows its owner's poses) and its knock comes back in the walker's own moves later still: on the
-- driver's screen the car had passed through the other's puppet before it flew (~0.3-0.4 s, 4-5 m at 13 m/s). So the
-- side whose player sits in a car that simulates here (the one it drives) watches the other's puppet on foot as well:
-- a hit knocks the puppet here at once (RUN.knock: puppetFrame plays it, then eases back to the stream), takes a little
-- of the car's speed (CAR_KEEP) and sends RO with the push and damage; the walker takes it as its hit (TD.RUN.hit) -
-- its own watch stays for a lost line, one cool-down for both.
TD.RUN.CAR_KEEP, TD.RUN.KNOCK_S, TD.RUN.BLEND_S, TD.RUN.G = 0.9, 0.8, 0.4, 980
TD.RUN.drvLast, TD.RUN.drvPrev = -1e9, {}
function TD.RUN.drive()
    local RUN = TD.RUN
    if M.stopped or garage then return end
    local pawn = localPawn()
    local tp = target.player
    if not (pawn and tp and (tp.seat or 0) == 0 and Sync.parentOf(pawn) and Sync.deref(puppetPath)) then return end
    local now = M.nowMs()
    if now - RUN.drvLast < RUN.COOL_MS then return end
    local me = pawn:K2_GetActorLocation()
    -- (the own car by Twin.ownCar: the guest's localCar() is the host's car in own-car mode)
    for _, car in ipairs({ Twin.ownCar(), localCar(), Sync.deref(otherCarPath) }) do
        local okS, sim = pcall(function() return car.RootComponent:IsSimulatingPhysics(FName("None")) end)
        local l = okS and sim and car:K2_GetActorLocation()
        if l and (me.X - l.X) ^ 2 + (me.Y - l.Y) ^ 2 < 400 * 400 then
            local v = car:GetVelocity()
            local speed = math.sqrt(v.X * v.X + v.Y * v.Y)
            local at = M.interpolated() -- (the puppet as drawn: its capsule centre)
            if speed > RUN.SPEED and at then
                local yaw = math.rad(car:K2_GetActorRotation().Yaw)
                local dx, dy = at.X - l.X, at.Y - l.Y
                local x = dx * math.cos(yaw) + dy * math.sin(yaw)
                local y = -dx * math.sin(yaw) + dy * math.cos(yaw)
                local lead = speed * RUN.LEAD_S
                if dx * v.X + dy * v.Y > 0 and math.abs(x) < RUN.HALF_L + RUN.RADIUS + lead and math.abs(y) < RUN.HALF_W + RUN.RADIUS
                    and math.abs(at.Z - l.Z) < RUN.HIGH then
                    RUN.drvLast = now
                    local side = (y >= 0 and 1 or -1) * RUN.SIDE
                    local ux, uy = v.X / speed, v.Y / speed
                    local along = math.min(speed, RUN.PUSH_MAX) * RUN.PUSH
                    local push = { X = ux * along - uy * side, Y = uy * along + ux * side, Z = RUN.UP }
                    local dmg = math.min(RUN.DMG_MAX, speed * RUN.DMG_PER_MS)
                    append(outFile, string.format("RO\t%d\t%.0f\t%.0f\t%.0f\t%.1f\t%.0f", now, push.X, push.Y, push.Z, dmg, speed))
                    RUN.knock = { t0 = os.clock(), p0 = { X = at.X, Y = at.Y, Z = at.Z }, v = push }
                    pcall(function() car.RootComponent:SetPhysicsLinearVelocity({ X = v.X * RUN.CAR_KEEP, Y = v.Y * RUN.CAR_KEEP, Z = v.Z }, false, FName("None")) end)
                    st.runOverDriven = (st.runOverDriven or 0) + 1
                    st.lastRunOverDriven = string.format("%.0f_cm/s_%.1f_dmg", speed, dmg)
                    return
                end
            end
        end
    end
end
-- The puppet's place while the knock plays (a throw along the push, landing at its height), then eased back to the
-- stream (which shows the walker's own launch by then); nil when none plays
function TD.RUN.knockAt(loc)
    local k = TD.RUN.knock
    if not k then return loc end
    local t = os.clock() - k.t0
    local RUN = TD.RUN
    if t > RUN.KNOCK_S + RUN.BLEND_S then RUN.knock = nil return loc end
    local tt = math.min(t, RUN.KNOCK_S)
    local p = { X = k.p0.X + k.v.X * tt, Y = k.p0.Y + k.v.Y * tt, Z = math.max(k.p0.Z, k.p0.Z + k.v.Z * tt - RUN.G / 2 * tt * tt) }
    if t <= RUN.KNOCK_S then return p end
    local f = (t - RUN.KNOCK_S) / RUN.BLEND_S
    return { X = p.X + (loc.X - p.X) * f, Y = p.Y + (loc.Y - p.Y) * f, Z = p.Z + (loc.Z - p.Z) * f }
end
-- RO: the other's car hit this side's player (its driver saw it first)
function TD.RUN.hit(px, py, pz, dmg, speed)
    local RUN = TD.RUN
    local pawn = localPawn()
    if not pawn or Sync.parentOf(pawn) then return end
    local now = M.nowMs()
    if now - RUN.last <= RUN.COOL_MS then st.runOverLate = (st.runOverLate or 0) + 1 return end
    RUN.last = now
    local push = { X = px, Y = py, Z = pz }
    pcall(function()
        local cap = pawn.CapsuleComponent
        local paths = {}
        for _, car in ipairs({ localCar(), Sync.deref(otherCarPath) }) do
            if car and car:IsValid() then cap:IgnoreActorWhenMoving(car, true) paths[#paths + 1] = Sync.ref(car) end
        end
        CoopSyncAfter(RUN.FREE_MS, function()
            local p2 = localPawn()
            for _, path in ipairs(paths) do
                local c2 = Sync.deref(path)
                if c2 and p2 then pcall(function() p2.CapsuleComponent:IgnoreActorWhenMoving(c2, false) end) end
            end
        end)
    end)
    pcall(function() pawn:LaunchCharacter(push, true, true) end)
    local okD = pcall(RUN.damage, pawn, dmg, push)
    st.runOver = (st.runOver or 0) + 1
    st.runOverByDriver = (st.runOverByDriver or 0) + 1
    st.lastRunOver = string.format("%.0f_cm/s_%.1f_dmg_%s_driver", speed, dmg, okD and "ok" or "failed")
end
-- The other player's trunk lid shutting on this side's player (owner, alpha 18 item 24: "it does no damage hitting the
-- own head"). The game hurts a player under a lid by the lid mesh's hit (its MainMesh ComponentHit handler); the twin's
-- lid is posed, kinematic, and hits nothing. While it is on its way shut (Twin.doorClosing) and the player's head is
-- in its bounds: the impact message (RUN.damage) and a small push back from the car.
TD.LID = { DMG = 8, PUSH = 250, COOL_MS = 3000, PAD = 30, last = -1e9 } -- (PAD: a head, not a point - 10 missed a head 20 off the lid's box, runover-test)
function TD.LID.check()
    local L = TD.LID
    if M.stopped or garage then return end
    local pawn = localPawn()
    if not pawn or inGhost or Sync.parentOf(pawn) then return end
    local now = M.nowMs()
    if now - L.last < L.COOL_MS then return end
    for _, car in ipairs({ localCar(), Sync.deref(otherCarPath) }) do
        if car and car:IsValid() and Twin.isTwin(car) then
            local lid, how = Twin.doorClosing(car, 5)
            if lid then
                local o, e = {}, {}
                local okB = pcall(function() L.KSL = L.KSL or SFO("/Script/Engine.Default__KismetSystemLibrary") L.KSL:GetComponentBounds(lid, o, e, {}) end)
                local head = pawn:K2_GetActorLocation()
                head = { X = head.X, Y = head.Y, Z = head.Z + 60 }
                if okB and o.X then L.near = string.format("d=%.0f,%.0f,%.0f_e=%.0f,%.0f,%.0f_%s_%s", head.X - o.X, head.Y - o.Y, head.Z - o.Z, e.X, e.Y, e.Z, car == localCar() and "own" or "other", tostring(how)) end
                if okB and o.X and e.X and math.abs(head.X - o.X) < e.X + L.PAD and math.abs(head.Y - o.Y) < e.Y + L.PAD and math.abs(head.Z - o.Z) < e.Z + L.PAD then
                    L.last = now
                    local c = car:K2_GetActorLocation()
                    local dx, dy = head.X - c.X, head.Y - c.Y
                    local d = math.max(1, math.sqrt(dx * dx + dy * dy))
                    local push = { X = dx / d * L.PUSH, Y = dy / d * L.PUSH, Z = 0 }
                    pcall(function() pawn:LaunchCharacter(push, true, false) end)
                    local okD = pcall(TD.RUN.damage, pawn, L.DMG, { X = 0, Y = 0, Z = -L.PUSH })
                    st.lidHits = (st.lidHits or 0) + 1
                    st.lastLidHit = (okD and "ok" or "failed") .. "_" .. tostring(how) .. "_at" .. now
                    return
                end
            end
        end
    end
end
-- (tests: a door's entry of the other's newest car pose, its age in ms)
function M.poseDoor(n) return string.format("%s@%d/sent%d", tostring(target.pose and target.pose:match("D" .. n .. "%.MainMesh=([^;]+)")), M.nowMs() - (st.poseAt or 0), M.nowMs() - (st.poseSentAt or 0)) end
function M.runOverInfo()
    return string.format("run_over=%d last_run_over=%s nearest=%s lid_hits=%d last_lid_hit=%s lid_near=%s drove_over=%d last_drove_over=%s by_driver=%d late=%d",
        st.runOver or 0, tostring(st.lastRunOver), TD.RUN.near and TD.RUN.near.s or "-", st.lidHits or 0, tostring(st.lastLidHit),
        tostring(TD.LID.near), st.runOverDriven or 0, tostring(st.lastRunOverDriven), st.runOverByDriver or 0, st.runOverLate or 0)
end

-- The other player's character (capsule centre) as this side knows it: its newest sample (for the tests).
function M.otherPawnAt() return target.player and target.player.loc or nil end
-- Kick like the player's kick key: the controller's Kick input action event (for the tests).
function M.botKick()
    local pc = (CoopSyncFirst or FindFirstOf)("PlayerController")
    local n = st.kickTries or 0
    local ok, e = pcall(function() pc:InpActEvt_Kick_K2Node_InputActionEvent_31({ KeyName = FName("F") }) end)
    return string.format("kick input: %s %s, hook fired: %s", tostring(ok), tostring(e or ""), tostring((st.kickTries or 0) > n))
end
function M.kickInfo()
    return string.format("kick_tries=%d kicks_sent=%d kicks_taken=%d kick_at=%s kick_health=%s hooked=%s doors_hidden=%d ghost_door_taken=%d", st.kickTries or 0, st.kicksSent or 0, st.kicksTaken or 0, (tostring(st.kickAt):gsub(" ", "_")), tostring(st.kickHealth),
        tostring(CoopSyncKickHooks and CoopSyncKickHooks.done == true), CoopSyncDoorHooks and CoopSyncDoorHooks.hidden or 0, st.ghostDoorTaken or 0)
end

-- The character input the ghost driver has (for the tests).
function M.ghostAxesInfo()
    local v = ghostInput(role == "client" and target.car or target.otherCar)
    return string.format("axes fwd=%.2f right=%.2f hb=%d age_ms=%d -> input=%.2f,%.2f,%.2f,%.2f in_sent=%d in_recv=%d in_applied=%d hooks=%s",
        ghostAxes.fwd, ghostAxes.right, ghostAxes.hb, M.nowMs() - ghostAxes.ms, v[1], v[2], v[3], v[4],
        st.inSent or 0, st.inRecv or 0, st.inApplied or 0, tostring(CoopSyncPawnHooks and CoopSyncPawnHooks.done and next(CoopSyncPawnHooks.done) ~= nil))
end

-- Where to stand to get into the other player's car at door n (just outside it; for the tests).
function M.ghostDoor(n)
    local g = ghostOf(otherTag())
    if not g or not SEAT_DOOR[n] then return "none" end
    local w = toWorld(g, { X = SEAT_DOOR[n].X, Y = SEAT_DOOR[n].Y * 1.3, Z = 0 })
    return string.format("%.1f,%.1f,%.1f", w.X, w.Y, w.Z)
end

M.ghostInfo = function()
    return string.format("in_ghost=%s seat=%s boarded=%d left=%d last_leave=%s seatG_host=%s seatG_client=%s",
        inGhost and inGhost.tag or "-", inGhost and tostring(inGhost.seat) or "-", st.ghostBoarded or 0, st.ghostLeft or 0,
        tostring(st.lastGhostLeave):gsub(" ", "_"), tostring(seatOfG.host), tostring(seatOfG.client)) .. " " .. (Ghost and Ghost.statsInfo() or "") .. " " .. (Twin and Twin.info() or "") .. " style=" .. tostring(st.twinStyle):gsub(" ", "_") .. " twin_failed=" .. tostring(st.twinFailed):gsub(" ", "_")
        .. " " .. (Twin and Twin.equipInfo(TD.copy and TD.copy()) or "") .. string.format(" eq_sent=%d eq_recv=%d ex_sent=%d ex_done=%d last_ex=%s",
            st.equipSent or 0, st.equipRecv or 0, st.equipExSent or 0, st.equipExDone or 0, (tostring(st.lastEx):gsub(" ", "_")))
        .. " " .. (Twin and Twin.stateInfo() or "") .. string.format(" es_sent=%d es_recv=%d ey_sent=%d ey_done=%d last_ey=%s li_sent=%d li_recv=%d",
            st.stateSent or 0, st.stateRecv or 0, st.stateEySent or 0, st.stateEyDone or 0, (tostring(st.lastEy):gsub(" ", "_")), st.lightsSent or 0, st.lightsRecv or 0)
        .. string.format(" horn_sent=%d horn_recv=%d horn_asked=%d last_horn_done=%s twin_horn=%s", st.hornSent or 0, st.hornRecv or 0,
            st.hornAsked or 0, tostring(st.lastHornDone), tostring(TD.horn.twin))
        .. string.format(" rt_sent=%d rt_recv=%d rt_played=%d last_track=%s rk_sent=%d last_rk_done=%s", st.trackSent or 0, st.trackRecv or 0,
            st.trackPlayed or 0, (tostring(st.lastTrack):gsub("%s", "_")), st.channelAsked or 0, tostring(st.lastChannelDone))
        .. " gear_fixed=" .. tostring(CoopSyncGearHook and CoopSyncGearHook.fixed or 0)
        .. string.format(" track_drift=%s track_seeks=%d rn_sent=%d rn_recv=%d rn_queued=%d random_seeks=%d", tostring(st.trackDrift),
            st.trackSeeks or 0, st.nextSent or 0, st.nextRecv or 0, st.nextQueued or 0, st.randomSeeks or 0)
        .. string.format(" dj_sent=%d dj_recv=%d dj_played=%d dj_stopped=%d", st.djSent or 0, st.djRecv or 0, st.djPlayed or 0,
            Twin.stats.djStopped or 0)
        .. string.format(" bi_sent=%d bi_got=%d bumps=%d last_bump=%s", st.bumpSent or 0, st.bumpGot or 0, Twin.stats.bumps or 0,
            (tostring(Twin.stats.lastBump):gsub("%s", "_")))
        .. string.format(" strike_max=%d kin_jumps=%d", math.floor(Twin.stats.strikeMax or 0), st.kinJumps or 0)
        .. string.format(" cs_sent=%d cs_recv=%d cx_sent=%d cx_done=%d ", st.storeSent or 0, st.storeRecv or 0, st.storeAsked or 0, st.storeDone or 0)
        .. (Twin.Store and Twin.Store.info() or "")
        -- (the wall clock ms when the local track last changed: both sides' changes at a track's natural end compared)
        .. " track_changed=" .. (Twin.clock.changedAt and string.format("%d", M.nowMs() - (os.clock() * 1000 - Twin.clock.changedAt)) or "-")
end

-- Driver input lives in the car BP's raw input fields (the game's input events fill them, the BP
-- pipeline interpolates them into the vehicle controller). Probed: writing them every frame drives
-- the car with all game logic; the game does not reset them, so a released input must be written as 0.
local INPUT_FIELDS = { "UserThrottleInput", "UserBrakeInput", "UserSteerInput", "UserHandBrakeInput" }
local INPUT_SEND_MS, INPUT_STALE_MS = 33, 500
local wheelIn -- host: newest client input { v = {4 numbers}, recvMs }
local wheelInG -- client, own-car mode: newest host input for the client's own car (the host drives it)

-- Ignition and the drive/park lever live in BP_CarManager_C (CarIgnitionState 0 off / 1 starting / 2 running,
-- MyCarGearBox 0 drive / 1 park; reverse = holding the brake after a stop, the handbrake an input axis - both
-- already in the I stream). The car's ToggleIgnitionState / ToggleGearBoxState change them with key turn /
-- lever animation and sound. The client driver's changes go to the host as K lines; the host's state rides
-- on every C line and the client's copy follows it.
local carManagerPath
local function readControls()
    local m = Sync.deref(carManagerPath)
    if not m then
        m = (CoopSyncFirst or FindFirstOf)("BP_CarManager_C")
        if not (m and m:IsValid()) then return nil end
        carManagerPath = Sync.ref(m)
    end
    local ok, ign, gear = pcall(function() return m.CarIgnitionState, m.MyCarGearBox end)
    if not ok then return nil end
    return tonumber(ign), tonumber(gear)
end
-- ToggleIgnitionState(v) sets v. ToggleGearBoxState(s, false) (with the lever animation) flips the lever only
-- when it stands on s (observed: s = the other state does nothing), so it is called with the current state.
-- The own car's key / lever as its owner's lines tell them: while this player sits in the other's twin the manager
-- holds THAT car's, the own car's are kept in inGhost.savedCtl (owner's two-games test 2026-11-11: each in the other's
-- car, the lever "lags and jumps back for a while" - the owner's lines carried the other car's lever, the driver's twin
-- followed them back).
function TD.ownControls()
    local sc = inGhost and inGhost.savedCtl
    if sc then return sc.ign, sc.gear end
    return readControls()
end
-- the other player's key / lever / lights for the own car: in the own car's context (on foot the context may be the
-- other's twin - the toggle then read and wrote that car's state), held TD.DR_CTX_MS; while this player sits in the
-- other's twin, into the kept state (savedCtl) - back in the manager when it gets out
function TD.ownCtxFor(car)
    if car and TD.native and Native and not inGhost and not Sync.parentOf(localPawn()) then
        pcall(Native.use, car)
        TD.ownCtxUntil = M.nowMs() + TD.DR_CTX_MS
    end
end
local function setControl(car, what, v)
    local sc = inGhost and inGhost.savedCtl
    if sc then sc[what] = v st.ctlKept = (st.ctlKept or 0) + 1 return end
    TD.ownCtxFor(car)
    if what == "ign" then pcall(function() car:ToggleIgnitionState(v) end) return end
    local _, gear = readControls()
    if gear and gear ~= v then pcall(function() car:ToggleGearBoxState(gear, false) end) end
end
local ctl = { ign = nil, gear = nil } -- client: the values this side last saw / set (changes beyond = the player's)
local ctlHoldUntil = 0 -- client: ignore the host's state until then (its C lines predate our K)
local CTL_HOLD_MS = 1500
local ctlFollowUntil = 0 -- client: following the host (lever animating) - local changes are not the player's
local CTL_FOLLOW_MS = 2000
local function readInput(car)
    local v = {}
    -- (a ghost has no such fields: 0)
    for i, f in ipairs(INPUT_FIELDS) do
        local ok, x = pcall(function() return car[f] end)
        v[i] = (ok and type(x) == "number") and x or 0
    end
    return v
end
-- The pedals' own stage (raw axis -> ThrottleTarget / ThrottleCurrent, BrakeTarget / BrakeCurrent -> the User*
-- fields) runs where the game takes input (with sound - a real game; reference-save tests 2026-11-14): it rewrote
-- UserThrottleInput from its own 0 every frame and the written throttle never reached the car (moved 0). Written into
-- that stage too, it carries the value through; where the stage does not run the User* fields alone drive the car.
local function writeInput(car, v)
    for i, f in ipairs(INPUT_FIELDS) do car[f] = v[i] or 0 end
    pcall(function()
        local t, b = v[1] or 0, v[2] or 0
        car.RawThrottle, car.ThrottleTarget, car.ThrottleCurrent = t, t, t
        car.BrakeTarget, car.BrakeCurrent = b, b
    end)
end
local ZERO = { 0, 0, 0, 0 }

-- Put the own seated character on its seat: the game's seat logic snaps the character back every frame,
-- but it follows the car's TempSocket_Seat component, so move that socket (socket = seat - sockDelta).
local function placeOnSeat(car, rel, seat)
    local want = seatRel(seat)
    if (rel.X - want.X) ^ 2 + (rel.Y - want.Y) ^ 2 + (rel.Z - want.Z) ^ 2 <= 4 then return end
    local sock = car.TempSocket_Seat
    if not (sock and sock:IsValid() and sockDelta) then return end
    local to = { X = want.X - sockDelta.X, Y = want.Y - sockDelta.Y, Z = want.Z - sockDelta.Z }
    local r = sock.RelativeLocation
    if (r.X - to.X) ^ 2 + (r.Y - to.Y) ^ 2 + (r.Z - to.Z) ^ 2 > 1 then
        pcall(function() sock:K2_SetRelativeLocation(to, false, {}, true) end)
        st.seatMoves = (st.seatMoves or 0) + 1
    end
end

-- Owner side, own-car mode: the moving visuals of this side's car for the other's twin of it (twincar pose):
--   V <time> <name=x,y,z,pitch,yaw,roll;...>
local function sendPose(car)
    local ok, s = pcall(Twin.pose, car)
    if ok and s ~= "" then
        append(outFile, "V\t" .. M.nowMs() .. "\t" .. s)
        st.posesSent = (st.posesSent or 0) + 1
    end
end

-- the own car's lines for the other side's twin, each timed (M.profile: s_*)
local OWN_SENDS = { { "s_layout", function(car) sendLayout(car, outFile) end }, { "s_pose", function(car) sendPose(car) end },
    { "s_equip", function() TD.sendEquip() end }, { "s_state", function() TD.sendState() end }, { "s_paint", function() TD.sendPaint() end },
    { "s_lights", function(car) TD.sendLights(car) end }, { "s_track", function() TD.sendTrack() end },
    { "s_store", function() TD.sendStore() end }, { "s_tuning", function() TD.sendTuning() end } }
function TD.sendOwn(car)
    for _, x in ipairs(OWN_SENDS) do
        local ok, e = timed(x[1], function() x[2](car) end)
        if not ok then err(x[1] .. ": " .. tostring(e)) end
    end
end
-- The own car's back seat in the garage (owner's alpha 21 test: from the back seat there every control was the
-- driver's, the way out was the driver's door, and the next time at the wheel put the player on that back seat again -
-- the seat bookkeeping below ran in the zone only): seated there, the passenger rules, its exit at its door and the
-- pedals off (wheelFrame); out again, the seat socket and the exit back at the wheel.
function TD.garageSeat(pawn, par)
    local own = Twin.ownCar()
    local inOwn = par and own and par:GetAddress() == own:GetAddress()
    if inOwn and TD.ownSeat then
        TD.ownSeat.seated = true
        local n = TD.ownSeat.n
        pcall(TD.placeExit, own, n)
        -- (and the door the exit takes the player to: out by the right back door it stood on the left side, as the
        -- zone's native path sets it - owner's two-games test 2026-11-11, garage-seat-test)
        pcall(TD.seatEntryPoint, pawn, own, n)
        TD.seatNow = { car = Sync.ref(own), n = n }
    elseif inOwn then
        if TD.seatNow and TD.seatNow.n ~= 1 then pcall(TD.placeExit, own, 1) end
        TD.seatNow = { car = Sync.ref(own), n = 1 }
    else
        if TD.ownSeat and (TD.ownSeat.seated or M.nowMs() - TD.ownSeat.since > 4000) then
            -- (the exit's spot back at the wheel a moment later: the game puts the player at that spot after it let go -
            -- moved back at once, out by the right back door stood on the left; garage-seat-test)
            if own then
                pcall(TD.aimSeatSocket, own, 1)
                CoopSyncAfter(1500, function() local o = Twin.ownCar() if o and not TD.ownSeat then pcall(TD.placeExit, o, 1) end end)
            end
            TD.ownSeat = nil
            st.garageSeatBack = (st.garageSeatBack or 0) + 1
        end
        TD.seatNow = nil
    end
end
local function sendTick()
    local pawn = localPawn()
    if garage then
        if pawn then
            -- sitting in its own car (owner: the puppet stood at the seat, legs through the car's floor): seat 1, no
            -- car tag - the other side has no copy of this car in its garage, the puppet sits where the seat is
            local par = Sync.parentOf(pawn)
            local sits = par and Sync.clsName(par):find("^BP_PlayerCar") ~= nil
            append(outFile, string.format("P\t%d\t%s\t%d\t-", M.nowMs(), xform(pawn), sits and 1 or 0))
            st.sent = st.sent + 1
            pcall(TD.garageSeat, pawn, sits and par or nil)
        end
        -- the music: the host's radio / garage stereo for both
        if not (CoopSyncRadioHook and CoopSyncRadioHook.done and CoopSyncRadioHook.seekDone and CoopSyncRadioHook.seek == TD.onRandomSeek) then pcall(TD.hookRadio) end
        if role == "host" then TD.sendTrack() else pcall(TD.musicTick, nil) end
        return
    end
    local car = localCar()
    if pawn then
        local seat, tag = 0, "-"
        -- in this car = attached to this car (own-car mode: a player in its own car is not in the host's)
        local par = Sync.parentOf(pawn)
        -- (native cars: the game's own entry put the player in the other's car - its seat is asked for as before)
        if TD.native and not inGhost and par then
            local og = ghostOf(otherTag())
            if og and Twin.isTwin(og) and par:GetAddress() == og:GetAddress() then
                local n = (TD.aimed and SEAT_DOOR[TD.aimed.n]) and TD.aimed.n or 1
                inGhost = { tag = otherTag(), seat = nil, pending = false, entry = { X = SEAT_DOOR[n].X, Y = SEAT_DOOR[n].Y },
                    twin = true, since = M.nowMs(), aimed = n, door = n, native = true }
                -- (the owner's door it came in by shut for sure: the shut's flag change was missed now and then - the host
                -- drove off with its driver's door open)
                TD.entryShut = { n = n, at = M.nowMs() + TD.ENTRY_SHUT_MS }
                if inGhost.tag == "H" then myAssigned, seatPending = nil, false end
                st.ghostBoarded = (st.ghostBoarded or 0) + 1
            end
        end
        local g = inGhost and ghostOf(inGhost.tag) or nil
        -- (a twin: the game's CommandEnterCar attaches the player a moment later)
        local entering = inGhost and inGhost.twin and g and M.nowMs() - inGhost.since < 3000
        local exiting = inGhost and inGhost.exitAt
        local inG = g and par and par:GetFullName() == g:GetFullName()
        if inGhost and inGhost.native then
            -- (the game's own entry / exit: out once it was in; an entry that never got in within 4 s is dropped)
            if inG then inGhost.wasIn = true
            elseif inGhost.wasIn or M.nowMs() - inGhost.since > 4000 then
                TD.nativeLeft(pawn)
                par = Sync.parentOf(pawn)
            end
        elseif exiting and g and not (par and par:GetFullName() == g:GetFullName()) then
            -- (the game's exit let go of the twin: done - 0.4 s more for its last placement, which needs the manager there)
            inGhost.freeAt = inGhost.freeAt or M.nowMs()
            if M.nowMs() - inGhost.freeAt >= 400 then TD.twinExitDone(pawn) end
            par = Sync.parentOf(pawn)
        elseif exiting and M.nowMs() - inGhost.exitAt > TD.EXIT_ANIM_MS then
            ghostLeave(pawn, "exit stuck") -- (the animation did not let go: out the old way)
            par = Sync.parentOf(pawn)
        elseif inGhost and not exiting and not entering and not (g and par and par:GetFullName() == g:GetFullName()) then
            ghostLeave(pawn, g and "detached" or "car gone")
            par = Sync.parentOf(pawn)
        end
        if inGhost then
            -- in the other player's car (this side's ghost of it): the owner hands out the seat
            local e = inGhost.entry
            local ex, ey = e and string.format("%.1f", e.X) or "-", e and string.format("%.1f", e.Y) or "-"
            if inGhost.tag == "H" then
                if not myAssigned and not seatPending then
                    seatPending = true
                    append(outFile, string.format("S\t%d\t%s\t%s\t%s", M.nowMs(), ex, ey, inGhost.aimed and "x" or "-"))
                    st.seatRequests = (st.seatRequests or 0) + 1
                end
                inGhost.seat = myAssigned
            elseif not inGhost.seat and not inGhost.pending then
                inGhost.pending = true
                append(outFile, string.format("SG\t%d\t%s\t%s\t%s", M.nowMs(), ex, ey, inGhost.aimed and "x" or "-"))
                st.seatRequests = (st.seatRequests or 0) + 1
            end
            local inside = par and g and par:GetFullName() == g:GetFullName()
            if inGhost.twin and inside and not st.seatMeasured and not inGhost.seat and not inGhost.aimed then
                measureDriverSeat(pawn.RootComponent.RelativeLocation) -- (diagnostics: where the game seated the player)
            end
            if inGhost.seat and inside then
                local want, rel = seatRel(inGhost.seat), pawn.RootComponent.RelativeLocation
                if inGhost.twin then placeOnSeat(g, rel, inGhost.seat) -- the game's seat follows the car's seat socket
                elseif (rel.X - want.X) ^ 2 + (rel.Y - want.Y) ^ 2 + (rel.Z - want.Z) ^ 2 > 4 then
                    pcall(function() pawn:K2_SetActorRelativeLocation({ X = want.X, Y = want.Y, Z = want.Z }, false, {}, true) end)
                end
            end
            seat, tag = inGhost.seat or -1, inGhost.tag
        elseif role == "client" and ownCar and par and Sync.deref(ownCarPath) and par:GetFullName() == Sync.deref(ownCarPath):GetFullName() then
            -- own-car mode: the client in its own car (the game always seats its player as the driver; a back seat by
            -- its back door, TD.ownEnter)
            seat, tag = TD.ownSeat and TD.ownSeat.n or 1, "G"
            if TD.ownSeat then TD.ownSeat.seated = true end
        elseif par and car and par:GetFullName() == car:GetFullName() then
            tag = "H"
            local rel = pawn.RootComponent.RelativeLocation
            if not st.seatMeasured and not TD.ownSeat then measureDriverSeat(rel) end -- (diagnostics, at the wheel only)
            local entry = (lastOutside and M.nowMs() - lastOutside.ms < 5000) and lastOutside or nil
            -- (own-car mode - the guest's G lines come - the host in its own car is its driver, as the game seats it,
            -- unless the guest has the wheel: by the door it came in at it had taken the back seat it got out at,
            -- and the guest's "free" back seat was then the host's)
            if role == "host" and lastOtherRecv and seatOf.client ~= 1 then entry = nil end
            -- (in by a back door of its own car: that seat, TD.ownEnter)
            local ob = TD.ownSeat and SEAT_DOOR[TD.ownSeat.n]
            if ob then entry = { X = ob.X, Y = ob.Y } TD.ownSeat.seated = true end
            if role == "host" then
                if not seatOf.host then
                    local n, why = chooseSeat(car, "host", entry)
                    if n then seatOf.host = n st.seated = (st.seated or 0) + 1 else exitCar(pawn, "no free seat (" .. why .. ")") end
                end
            elseif not myAssigned and not seatPending then
                seatPending = true
                append(outFile, string.format("S\t%d\t%s\t%s", M.nowMs(), entry and string.format("%.1f", entry.X) or "-", entry and string.format("%.1f", entry.Y) or "-"))
                st.seatRequests = (st.seatRequests or 0) + 1
            end
            local s = mySeat()
            if s then placeOnSeat(car, rel, s) seat = s else seat = -1 end -- -1: in the car, waiting for a seat
        else
            if role == "host" then seatOf.host = nil else myAssigned = nil end
            -- (out of the own car's back seat - or an entry there that never got in: the seat socket back at the wheel)
            if TD.ownSeat and (TD.ownSeat.seated or M.nowMs() - TD.ownSeat.since > 4000) then
                local own = Twin.ownCar()
                if own then pcall(TD.aimSeatSocket, own, 1) end
                TD.ownSeat = nil
            end
            if car then
                local l = toCar(car, pawn:K2_GetActorLocation())
                lastOutside = { X = l.X, Y = l.Y, ms = M.nowMs() }
            end
        end
        if TD.native and seat > 0 then
            local pc = Sync.parentOf(pawn)
            local carNow = pc and Native.carOf(pc)
            if carNow then
                pcall(TD.placeExit, carNow, seat) pcall(TD.seatEntryPoint, pawn, carNow, seat)
                TD.seatNow = { car = Sync.ref(carNow), n = seat }
            end
        elseif TD.native then
            TD.seatNow = nil
        end
        if TD.native then
            local atWheel = inGhost and inGhost.native and inGhost.wasIn and inGhost.seat == 1
            if atWheel and not TD.driving then pcall(TD.startDriving, inGhost.tag)
            elseif not atWheel and TD.driving then pcall(TD.stopDriving) end
            local dg = TD.driving and ghostOf(TD.driving)
            if dg then
                append(outFile, string.format("VD\t%d\t%s\t%s", M.nowMs(), TD.driving, xform(dg)))
                -- (the twin's own vehicle controller kept on: the old puppet code switches it off again)
                pcall(Twin.keepDriven, dg)
            end
        end
        append(outFile, string.format("P\t%d\t%s\t%d\t%s", M.nowMs(), xform(pawn), seat, seat ~= 0 and tag or "-"))
        st.sent = st.sent + 1
        trace("self", pawn:K2_GetActorLocation())
    end
    if role == "host" and car then
        local ign, gear = TD.ownControls()
        append(outFile, string.format("C\t%d\t%s\t%d\t%d\t%d\t%d\t%s\t%s", M.nowMs(), xform(car), seatOf.host or 0, seatOf.client or 0, ign or -1, gear or -1, TD.devicesBusy(car), TD.ownLtw()))
        trace("car", car:K2_GetActorLocation())
    end
    -- own-car mode: the client's own car for the host's copy
    local mine = role == "client" and ownCar and Sync.deref(ownCarPath) or nil
    if mine then
        local ign, gear = TD.ownControls()
        append(outFile, string.format("G\t%d\t%s\t%d\t%d\t%s\t%s", M.nowMs(), xform(mine), ign or -1, gear or -1, TD.devicesBusy(mine), TD.ownLtw()))
        TD.sendOwn(mine)
    end
    -- host: the client brought its own car (G lines come in) -> it needs this car's layout for its ghost
    if role == "host" and car and lastOtherRecv then TD.sendOwn(car) end
end

-- Host: take the device off a seat frame into the car trunk (the car loses it until it is put back).
-- The client asks the host (X line). Returns the device moved, or an error.
-- own = true (own-car mode, the client): its own car's seat, its own inventory.
function M.removeSeatDevice(n, own)
    if role ~= "host" and not own then
        append(outFile, string.format("X\t%d\tremove\t%d", M.nowMs(), n))
        return "asked the host to take the device off seat " .. n
    end
    local car = (own and role ~= "host") and Sync.deref(ownCarPath) or localCar()
    if not car then return "ERR no car" end
    local frame = SEAT_FRAME[n]
    if not frame then return "ERR seat " .. n .. " has no removable device (" .. tostring(seatDevice(car, n)) .. ")" end
    local im = (CoopSyncFirst or FindFirstOf)("BP_InventoryManager_C")
    local sl = car[frame].ItemSlot
    if sl.Items:GetArrayNum() == 0 then return "seat " .. n .. " frame already empty" end
    local inst = sl.Items[1]
    local name = inst.Archetype:GetFName():ToString()
    local eqOut = {}
    im:GetCarEquippedContainer(eqOut)
    eqOut.Inventory_CarEquipped:RemoveItemFromSlot(sl.SlotName, inst)
    im.Inventory_Trunk:AddItem(inst, true)
    st.devicesRemoved = (st.devicesRemoved or 0) + 1
    return string.format("took %s off seat %d into the trunk", name, n)
end

---------------------------------------------------------------------------------------------------
-- receive + apply

local function readLines()
    local got = Link.recv(inStream)
    if got then return got end
    local f = io.open(inFile, "rb")
    if not f then return {} end
    f:seek("set", readOff)
    local data = f:read("*a") or ""
    f:close()
    local out, used = {}, 0
    for line in data:gmatch("([^\n]*)\n") do used = used + #line + 1 out[#out + 1] = line end
    readOff = readOff + used
    return out
end

local function parse(t, i)
    return { X = tonumber(t[i]), Y = tonumber(t[i + 1]), Z = tonumber(t[i + 2]) },
           { Pitch = tonumber(t[i + 3]), Yaw = tonumber(t[i + 4]), Roll = tonumber(t[i + 5]) }
end

local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local ANIM = {
    idle = "/Game/AdvancedLocomotionV3/Characters/Mannequin/Animations/Idles/ALS_N_Idle_Pose.ALS_N_Idle_Pose",
    walk = "/Game/AdvancedLocomotionV3/Characters/Mannequin/Animations/Locomotion/ALS_N_Walk_F.ALS_N_Walk_F",
    run  = "/Game/AdvancedLocomotionV3/Characters/Mannequin/Animations/Locomotion/ALS_N_Run_F.ALS_N_Run_F",
}
local WALK_SPEED, RUN_SPEED = 15, 300 -- units/s thresholds for the puppet's locomotion clip
local IDLE_HOLD_MS = 150
local speedEma, lowSince

-- Seated pose (found by probing, see NOTES): thighs yaw -90 and calves yaw +90 in component space
-- put the knees forward at hip height and the feet under the knees.
-- Arms (owner: in the A-pose they stuck out through the door): two-bone IK in component space (mesh forward = +Y,
-- up = +Z) - "wheel" = hands on the steering wheel in front of the chest (driver), "lap" = hands on the knees.
local SIT_BONES = { "thigh_l", "thigh_r", "calf_l", "calf_r", "upperarm_l", "upperarm_r", "lowerarm_l", "lowerarm_r", "hand_l", "hand_r" }
local function vsub(a, b) return { X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z } end
local function vadd(a, b, k) k = k or 1 return { X = a.X + b.X * k, Y = a.Y + b.Y * k, Z = a.Z + b.Z * k } end
local function vlen(a) return math.sqrt(a.X * a.X + a.Y * a.Y + a.Z * a.Z) end
local function vnorm(a) local l = vlen(a) if l < 1e-6 then return { X = 0, Y = 0, Z = 0 } end return { X = a.X / l, Y = a.Y / l, Z = a.Z / l } end
local function vdot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
local function vcross(a, b) return { X = a.Y * b.Z - a.Z * b.Y, Y = a.Z * b.X - a.X * b.Z, Z = a.X * b.Y - a.Y * b.X } end
M.armTargets = { -- offsets from the shoulder (lateral = toward the body's middle, + forward, + up), cm
    wheel = { fwd = 42, up = -24, inward = 0.55 }, -- inward: fraction of the shoulder's distance from the middle
    lap = { knee = true, back = 6, up = 9 },
}
M.legPose = { kneeUp = 20, calfFwd = 45, toeDrop = 4 } -- degrees above the hip / forward of straight down; cm
function M.sitPose(pose, arms)
    local function F(n) return FName(n) end
    for _, b in ipairs(SIT_BONES) do pcall(function() pose:ResetBoneTransformByName(F(b)) end) end
    local function bend(bone, yaw)
        local r = pose:GetBoneRotationByName(F(bone), 1)
        pose:SetBoneRotationByName(F(bone), KML:ComposeRotators({ Pitch = 0, Yaw = yaw, Roll = 0 }, r), 1)
    end
    bend("thigh_l", -90) bend("thigh_r", -90)
    bend("calf_l", 90) bend("calf_r", 90)
    local function at(b) return pose:GetBoneLocationByName(F(b), 1) end
    -- turn a bone (component space) so its child moves from where it is toward the goal
    local function aim(bone, child, goal)
        local p = at(bone)
        local c, e = vnorm(vsub(at(child), p)), vnorm(vsub(goal, p))
        local d = math.max(-1, math.min(1, vdot(c, e)))
        local axis = vcross(c, e)
        if vlen(axis) < 1e-5 then return end
        local delta = KML:RotatorFromAxisAndAngle(vnorm(axis), math.deg(math.acos(d)))
        pose:SetBoneRotationByName(F(bone), KML:ComposeRotators(pose:GetBoneRotationByName(F(bone), 1), delta), 1)
    end
    -- Legs (owner: the feet stuck out under the car): the car's floor is ~27 cm below the pelvis (car space: pelvis
    -- -8, interior floor -35, underside -51), the hanging calves put the toes at -59. Knees a little above the hips,
    -- calves forward-down (M.legPose degrees), feet flat: toes ~-32 at both seats.
    local lp = M.legPose
    for _, s in ipairs({ "l", "r" }) do
        local h = at("thigh_" .. s)
        local tl, cl = vlen(vsub(at("calf_" .. s), h)), vlen(vsub(at("foot_" .. s), at("calf_" .. s)))
        local ku, ca = math.rad(lp.kneeUp), math.rad(lp.calfFwd)
        local knee = { X = h.X, Y = h.Y + tl * math.cos(ku), Z = h.Z + tl * math.sin(ku) }
        aim("thigh_" .. s, "calf_" .. s, knee)
        local k = at("calf_" .. s)
        aim("calf_" .. s, "foot_" .. s, { X = k.X, Y = k.Y + cl * math.sin(ca), Z = k.Z - cl * math.cos(ca) })
        local f = at("foot_" .. s)
        aim("foot_" .. s, "ball_" .. s, { X = f.X, Y = f.Y + 15, Z = f.Z - lp.toeDrop })
    end
    if not arms then return end
    local pelvis = at("pelvis")
    for _, s in ipairs({ "l", "r" }) do
        local S, E0, H0 = at("upperarm_" .. s), at("lowerarm_" .. s), at("hand_" .. s)
        local L1, L2 = vlen(vsub(E0, S)), vlen(vsub(H0, E0))
        local side = (S.X - pelvis.X) >= 0 and 1 or -1 -- the shoulder's side of the body's middle (X)
        local T
        local tg = M.armTargets[arms]
        if tg.knee then
            local k = at("calf_" .. s)
            T = { X = k.X, Y = k.Y - tg.back, Z = k.Z + tg.up }
        else
            T = { X = pelvis.X + (S.X - pelvis.X) * (1 - tg.inward), Y = S.Y + tg.fwd, Z = S.Z + tg.up }
        end
        local dv = vsub(T, S)
        local d = math.min(vlen(dv), L1 + L2 - 0.5)
        local u = vnorm(dv)
        -- the elbow bends down and out
        local pole = { X = side * 0.6, Y = -0.2, Z = -1 }
        local pn = vnorm(vsub(pole, { X = u.X * vdot(pole, u), Y = u.Y * vdot(pole, u), Z = u.Z * vdot(pole, u) }))
        local a = (L1 * L1 - L2 * L2 + d * d) / (2 * d)
        local h = math.sqrt(math.max(L1 * L1 - a * a, 0))
        local E = vadd(vadd(S, u, a), pn, h)
        aim("upperarm_" .. s, "lowerarm_" .. s, E)
        aim("lowerarm_" .. s, "hand_" .. s, vadd(S, u, d))
    end
end

local function loadAnim(path)
    local a = SFO(path)
    if not (a and a:IsValid()) then pcall(function() LoadAsset(path:gsub("%.[^.]+$", "")) end) a = SFO(path) end
    return a
end

local function setAnimState(puppet, state)
    if state == animState then return end
    local sk = puppet.SkeletalMeshComponent
    local pose = Sync.deref(posePath)
    if state == "sit" then
        animName = "sit_pose"
        sk:SetVisibility(false, false)
        if pose then pose:SetVisibility(true, false) end
    else
        if pose then pose:SetVisibility(false, false) end
        sk:SetVisibility(true, false)
        local anim = loadAnim(ANIM[state])
        if anim then sk:PlayAnimation(anim, true) animName = anim:GetFName():ToString() else err("anim missing: " .. state) end
    end
    animState = state
    footSamples = {}
    st.animChanges = (st.animChanges or 0) + 1
end

-- the puppet's capsule: blocks while it walks, off while it sits in a car or the other player is gone
local function setPuppetSolid(on)
    if puppetSolid == on then return end
    local cap = Sync.deref(capsulePath)
    if cap then pcall(function() cap:SetCollisionEnabled(on and 3 or 0) end) end -- 3 QueryAndPhysics
    puppetSolid = on
end

local function ensurePuppet(loc)
    local p = Sync.deref(puppetPath)
    if p then return p end
    local pawn = localPawn()
    if not pawn then return nil end
    local mesh = pawn.Mesh
    meshRel = { loc = mesh.RelativeLocation, rot = mesh.RelativeRotation }
    local cls = StaticFindObject("/Script/Engine.SkeletalMeshActor")
    local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local xf = { Translation = loc, Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local a = GS:BeginDeferredActorSpawnFromClass((CoopSyncFirst or FindFirstOf)("PlayerController"), cls, xf, 1, nil)
    a = GS:FinishSpawningActor(a, xf)
    if not (a and a:IsValid()) then err("puppet spawn failed") return nil end
    local comp = a.SkeletalMeshComponent
    comp:SetSkeletalMesh(mesh.SkeletalMesh, true)
    -- headless / off-screen meshes must still evaluate their animation
    pcall(function() comp.VisibilityBasedAnimTickOption = 0 end) -- AlwaysTickPoseAndRefreshBones
    -- copy the player's mesh scale: a puppet at scale 1 next to a scaled character looks absent
    pcall(function() a:SetActorScale3D(pawn:GetActorScale3D()) end)
    -- solid (owner): the meshes have no collision, a capsule like the character's blocks the local player (and is
    -- off while the puppet sits in a car - puppetSolid)
    pcall(function() comp:SetCollisionEnabled(0) end)
    local okc, cap = pcall(function()
        return a:AddComponentByClass(StaticFindObject("/Script/Engine.CapsuleComponent"), false,
            { Translation = { X = 0, Y = 0, Z = -meshRel.loc.Z }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false)
    end)
    if okc and cap and cap:IsValid() then
        pcall(function()
            local pc = pawn.CapsuleComponent
            cap:SetCapsuleSize(pc.CapsuleRadius, pc.CapsuleHalfHeight, false)
        end)
        -- a Pawn that blocks only pawns: moved by teleports, a profile that also blocks vehicles flipped the
        -- host's car when the puppet followed its player into it (seat -1, waiting for a seat)
        pcall(function()
            cap:SetCollisionObjectType(2)            -- ECC_Pawn
            cap:SetCollisionResponseToAllChannels(0) -- Ignore
            cap:SetCollisionResponseToChannel(2, 2)  -- Pawn: Block
        end)
        capsulePath = Sync.ref(cap)
    else
        err("no capsule: " .. tostring(cap))
        pcall(function() a:SetActorEnableCollision(false) end)
    end
    puppetSolid = true
    -- the game has no full-body sitting animation (first-person game: only ALS locomotion is loaded),
    -- so the sitting puppet is a PoseableMeshComponent with bent hips and knees
    local okp, pose = pcall(function()
        return a:AddComponentByClass(StaticFindObject("/Script/Engine.PoseableMeshComponent"), false,
            { Translation = { X = 0, Y = 0, Z = 0 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false)
    end)
    if okp and pose and pose:IsValid() then
        pose:SetSkeletalMesh(mesh.SkeletalMesh, true)
        pcall(function() pose:SetCollisionEnabled(0) end)
        M.sitPose(pose)
        poseArms = nil
        pose:SetVisibility(false, true)
        posePath = Sync.ref(pose)
    else
        err("no poseable mesh: " .. tostring(pose))
    end
    puppetPath = Sync.ref(a)
    animState = nil
    st.puppetSpawned = st.puppetSpawned + 1
    return a
end

-- velocity from the previous sample (sender clock), used to extrapolate over the sample's age
-- (the samples' times are the other PC's clock: its offset is the smallest receive-minus-send lately. The prediction's age by the sender's clock straight - nowMs() - time - was 0 or the cap whenever
-- the two PCs' clocks differed: the other's car stood and jumped to each sample, 10 a second - owner's alpha 21 test;
-- on one PC the clocks are the same, the tests never saw it)
function M.withVelocity(prev, cur)
    cur.vel = { X = 0, Y = 0, Z = 0 }
    if cur.time then
        -- (the smallest of the last 2 s, as TD.carSample: a clock set anew on either PC is followed within 2 s)
        local now = M.nowMs()
        local hs = prev and prev.offs or {}
        hs[#hs + 1] = { r = now, o = now - cur.time }
        while #hs > 1 and hs[1].r < now - 2000 do table.remove(hs, 1) end
        local o
        for _, x in ipairs(hs) do if not o or x.o < o then o = x.o end end
        cur.offs, cur.off = hs, o
    end
    if prev and prev.time and cur.time > prev.time then
        local dt = (cur.time - prev.time) / 1000
        if dt > 0 and dt < 0.5 then
            cur.vel = { X = (cur.loc.X - prev.loc.X) / dt, Y = (cur.loc.Y - prev.loc.Y) / dt, Z = (cur.loc.Z - prev.loc.Z) / dt }
            -- a timing glitch (two samples a few ms apart) must not throw the puppet across the map
            local sp = math.sqrt(cur.vel.X ^ 2 + cur.vel.Y ^ 2 + cur.vel.Z ^ 2)
            if sp > MAX_SPEED then
                local k = MAX_SPEED / sp
                cur.vel = { X = cur.vel.X * k, Y = cur.vel.Y * k, Z = cur.vel.Z * k }
            end
        end
    end
    return cur
end
local function predicted(tgt)
    local age = math.min(math.max((M.nowMs() - (tgt.off or 0) - tgt.time) / 1000, 0), EXTRAPOLATE_MAX)
    return { X = tgt.loc.X + tgt.vel.X * age, Y = tgt.loc.Y + tgt.vel.Y * age, Z = tgt.loc.Z + tgt.vel.Z * age }
end

local function lerp(a, b, k) return a + (b - a) * k end
local function lerpAngle(a, b, k)
    local d = (b - a + 180) % 360 - 180
    return a + d * k
end

-- The walking puppet is drawn INTERP_MS in the past between two real samples (the owner saw it jerk, sink into the
-- garage floor and jump up: it was extrapolated along the sample velocity, Z too, and moved in 33 ms steps - with
-- the real network's uneven arrival it overshot and snapped back). The other PC's clock: the smallest receive-minus-
-- send of the last samples (= its offset + the shortest trip). Moved every frame (puppetFrame).
local INTERP_MS = 120
local HIST_MS = 3000
local hist = {}
local clockOff
pushSample = function(smp)
    local now = M.nowMs()
    hist[#hist + 1] = { t = smp.time, r = now, loc = smp.loc, rot = smp.rot }
    while #hist > 2 and hist[1].r < now - HIST_MS do table.remove(hist, 1) end
    local off
    for _, h in ipairs(hist) do local o = h.r - h.t if not off or o < off then off = o end end
    clockOff = off
end
-- the other player's ground speed: the way its samples went over the last SPEED_WINDOW_MS (sender clock)
TD.SPEED_WINDOW_MS = 300
function TD.histSpeed()
    local n = #hist
    if n < 2 then return 0 end
    local b = hist[n]
    local a = hist[n - 1]
    for i = n - 1, 1, -1 do
        a = hist[i]
        if b.t - a.t >= TD.SPEED_WINDOW_MS then break end
    end
    local dt = (b.t - a.t) / 1000
    if dt <= 0 then return 0 end
    -- (no sample for a while: the player stands or the link stalls - not walking either way)
    if M.nowMs() - b.r > 500 then return 0 end
    return math.sqrt((b.loc.X - a.loc.X) ^ 2 + (b.loc.Y - a.loc.Y) ^ 2) / dt
end
function M.interpolated()
    local n = #hist
    if n == 0 then return nil end
    local rt = M.nowMs() - clockOff - INTERP_MS
    if rt >= hist[n].t then
        -- no newer sample yet: hold the newest (a short glide along its velocity on the ground plane only)
        local h, v = hist[n], target.player and target.player.vel or { X = 0, Y = 0 }
        local age = math.min((rt - h.t) / 1000, 0.1)
        return { X = h.loc.X + v.X * age, Y = h.loc.Y + v.Y * age, Z = h.loc.Z }, h.rot
    end
    if rt <= hist[1].t then return hist[1].loc, hist[1].rot end
    for i = n - 1, 1, -1 do
        local a, b = hist[i], hist[i + 1]
        if a.t <= rt then
            local k = (b.t > a.t) and (rt - a.t) / (b.t - a.t) or 1
            return { X = lerp(a.loc.X, b.loc.X, k), Y = lerp(a.loc.Y, b.loc.Y, k), Z = lerp(a.loc.Z, b.loc.Z, k) },
                { Pitch = 0, Yaw = lerpAngle(a.rot.Yaw, b.rot.Yaw, k), Roll = 0 }
        end
    end
    return hist[n].loc, hist[n].rot
end
local puppetOff -- set by applyTick while the puppet walks free (nil: seated / attached / gone)
local function puppetFrame()
    if not puppetOff then return end
    local p = Sync.deref(puppetPath)
    if not p then return end
    local loc, rot = M.interpolated()
    if not loc then return end
    if TD.RUN.knock then loc = TD.RUN.knockAt(loc) end -- (run over by this side's car: thrown at once)
    p:K2_SetActorLocationAndRotation({ X = loc.X + puppetOff.X, Y = loc.Y + puppetOff.Y, Z = loc.Z + puppetOff.Z },
        { Pitch = 0, Yaw = rot.Yaw + puppetOff.Yaw, Roll = 0 }, false, {}, true)
end

-- kin: a kinematic body (the twin): moved without teleport unless it snaps, so physics sees its velocity and a car it
-- drives into is pushed (a teleport only pushed it out of the overlap, or not at all)
TD.KIN_MAX_SPEED = 4000 -- units/s (~145 km/h): a faster step is a teleport
TD.kinAt = {}
-- k: the share of the way covered now (SMOOTH by default); at: { loc, rot } to go to instead of tgt's (extrapolated)
local function follow(actor, tgt, offset, kin, k, at)
    local cur = actor:K2_GetActorLocation()
    local SMOOTH = k or SMOOTH
    if at then tgt = { loc = at.loc, rot = at.rot } end
    local p = tgt.vel and predicted(tgt) or tgt.loc
    local goal = { X = p.X + offset.X, Y = p.Y + offset.Y, Z = p.Z + offset.Z }
    local shoved
    if kin and TD.kick then goal, shoved = TD.kicked(actor, goal) end
    local d2 = (goal.X - cur.X) ^ 2 + (goal.Y - cur.Y) ^ 2 + (goal.Z - cur.Z) ^ 2
    local loc, rot
    local r = actor:K2_GetActorRotation()
    if d2 > SNAP_DIST ^ 2 then
        loc, rot = goal, { Pitch = tgt.rot.Pitch, Yaw = tgt.rot.Yaw + offset.Yaw, Roll = tgt.rot.Roll }
    else
        loc = { X = lerp(cur.X, goal.X, SMOOTH), Y = lerp(cur.Y, goal.Y, SMOOTH), Z = lerp(cur.Z, goal.Z, SMOOTH) }
        if shoved then loc.X, loc.Y = goal.X, goal.Y end -- (no lag behind the kick: the striker would hit it again)
        rot = { Pitch = lerpAngle(r.Pitch, tgt.rot.Pitch, SMOOTH), Yaw = lerpAngle(r.Yaw, tgt.rot.Yaw + offset.Yaw, SMOOTH),
                Roll = lerpAngle(r.Roll, tgt.rot.Roll, SMOOTH) }
    end
    -- (a step faster than a car goes is a jump - a stall's catch-up, a car put elsewhere: as a kinematic move physics
    -- took it for that speed and threw what it touched - world items out of the map, the other player killed; soak
    -- test 2026-10-28. The speed by the frame's time at most: physics divides the step by the frame.)
    local push = kin and d2 <= SNAP_DIST ^ 2
    if push then
        local now, key = os.clock(), actor:GetAddress()
        local dt = math.min(now - (TD.kinAt[key] or 0), 1 / 30)
        TD.kinAt[key] = now
        local step = math.sqrt((loc.X - cur.X) ^ 2 + (loc.Y - cur.Y) ^ 2 + (loc.Z - cur.Z) ^ 2)
        if step > TD.KIN_MAX_SPEED * dt and not shoved then push = false st.kinJumps = (st.kinJumps or 0) + 1 end
    end
    actor:K2_SetActorLocationAndRotation(loc, rot, false, {}, not push)
    return loc
end

-- The other's car moved every frame (owner, alpha 16: riding in the host's car, its motion was jerky): it was moved 30
-- times a second (the apply loop) toward a sample extrapolated along its velocity and pulled back at each new sample (10
-- a second) - a camera in it shook. Sitting in it, it is drawn TD.CAR_INTERP_MS in the past between two real samples
-- (a Hermite curve, Catmull-Rom tangents from the samples around); outside it - collisions need it where it is now -
-- extrapolated as before, but every frame with a smoothing by the frame's time.
TD.CAR_INTERP_MS = 160
TD.OUTSIDE_EVERY_FRAME = true -- the twin seen from outside moved every frame (TD.twinFrame), not by the apply loop
TD.carHist, TD.carOff = { car = {}, otherCar = {}, drv = {} }, {}
function TD.carSample(which, s)
    local h = TD.carHist[which]
    local now = M.nowMs()
    if #h > 0 and s.time <= h[#h].t then return end
    h[#h + 1] = { t = s.time, r = now, loc = s.loc, rot = s.rot }
    while #h > 3 and h[1].r < now - 2000 do table.remove(h, 1) end
    local off
    for _, x in ipairs(h) do local o = x.r - x.t if not off or o < off then off = o end end
    TD.carOff[which] = off
end
function TD.carInterp(which)
    local h = TD.carHist[which]
    local n = #h
    if n == 0 then return nil end
    local rt = M.nowMs() - TD.carOff[which] - TD.CAR_INTERP_MS
    local function vel(i, j) -- the way from sample i to j per second
        local a, b = h[i], h[j]
        local dt = (b.t - a.t) / 1000
        if dt <= 0 then return { X = 0, Y = 0, Z = 0 } end
        return { X = (b.loc.X - a.loc.X) / dt, Y = (b.loc.Y - a.loc.Y) / dt, Z = (b.loc.Z - a.loc.Z) / dt }
    end
    if rt >= h[n].t then
        -- (no newer sample yet: on along the last way a little, then it stands)
        local v = n > 1 and vel(n - 1, n) or { X = 0, Y = 0, Z = 0 }
        local age = math.min((rt - h[n].t) / 1000, 0.15)
        return { X = h[n].loc.X + v.X * age, Y = h[n].loc.Y + v.Y * age, Z = h[n].loc.Z + v.Z * age }, h[n].rot
    end
    if rt <= h[1].t then return h[1].loc, h[1].rot end
    for i = n - 1, 1, -1 do
        local a, b = h[i], h[i + 1]
        if a.t <= rt then
            local dt = (b.t - a.t) / 1000
            local k = dt > 0 and (rt - a.t) / (b.t - a.t) or 1
            local va = vel(i > 1 and i - 1 or i, i + 1)
            local vb = vel(i, i + 2 <= n and i + 2 or i + 1)
            local k2, k3 = k * k, k * k * k
            local h00, h10, h01, h11 = 2 * k3 - 3 * k2 + 1, k3 - 2 * k2 + k, -2 * k3 + 3 * k2, k3 - k2
            local function at(c) return h00 * a.loc[c] + h10 * dt * va[c] + h01 * b.loc[c] + h11 * dt * vb[c] end
            return { X = at("X"), Y = at("Y"), Z = at("Z") },
                { Pitch = lerpAngle(a.rot.Pitch, b.rot.Pitch, k), Yaw = lerpAngle(a.rot.Yaw, b.rot.Yaw, k), Roll = lerpAngle(a.rot.Roll, b.rot.Roll, k) }
        end
    end
    return h[n].loc, h[n].rot
end
-- the player looks at a storage of the other's twin: its trunk pointed at the twin's own container before E (carstore)
function TD.storeLook()
    local hm = (CoopSyncFirst or FindFirstOf)("BP_HighlightManager_C")
    local h = hm and hm.CurrentHighlight
    local a = h and h:IsValid() and h:GetOwner()
    if not (a and a:IsValid()) or (TD.lookedStore == a:GetAddress()) then return end
    TD.lookedStore = a:GetAddress()
    if not a:GetClass():GetFName():ToString():find("Storage", 1, true) then return end
    local car, g = a, 0
    while g < 10 do local p = car:GetAttachParentActor() if not (p and p:IsValid()) then break end car, g = p, g + 1 end
    if Twin.isTwin(car) then pcall(Twin.Store.repoint, car) st.storeRepointed = (st.storeRepointed or 0) + 1 end
end
-- (the hook on RefreshTrunkInventory: a twin's storage pointed back at its own container)
function TD.trunkRefreshed(part)
    if M.stopped or not (part and part:IsValid()) then return end
    local car, g = part, 0
    while g < 10 do local p = car:GetAttachParentActor() if not (p and p:IsValid()) then break end car, g = p, g + 1 end
    if not Twin.isTwin(car) then return end
    pcall(Twin.Store.repoint, car)
    st.trunkRefreshBack = (st.trunkRefreshBack or 0) + 1
end
-- (the hook on a trunk storage's E: the other's car's - the menu just opened on the own trunk shows the twin's instead,
-- the menu's own setter UMG_PlayerMenu_Inventory "Set Transfer Containers")
function TD.trunkOpened(part)
    if M.stopped or not (part and part:IsValid()) then return end
    local car, g = part, 0
    while g < 10 do local p = car:GetAttachParentActor() if not (p and p:IsValid()) then break end car, g = p, g + 1 end
    if not Twin.isTwin(car) then return end
    pcall(Twin.Store.repoint, car)
    local cont = part.BP_InventoryContainerComponent.Container
    if not (cont and cont:IsValid()) then return end
    local im = (CoopSyncFirst or FindFirstOf)("BP_InventoryManager_C")
    local own = {}
    for _, f in ipairs({ "Inventory_Trunk", "Inventory_LargeTrunk" }) do local c = im and im[f] if c and c:IsValid() then own[c:GetAddress()] = true end end
    for _, w in ipairs(FindAllOf("UMG_PlayerMenu_Inventory_C") or {}) do
        local cur = w:IsValid() and w.TransferContainer
        if cur and cur:IsValid() and own[cur:GetAddress()] then
            w["Set Transfer Containers"](w, cont, true, nil)
            st.trunkMenuPointed = (st.trunkMenuPointed or 0) + 1
            st.lastTrunkMenu = cont:GetFName():ToString()
        end
    end
end
-- every frame: the twins (client: the host's car, host: the guest's)
function TD.twinFrame()
    if garage or M.stopped then return end
    pcall(TD.storeLook)
    if TD.doorSnapUntil and not inGhost then pcall(TD.restoreDoorStates) end
    local now = os.clock()
    local dt = math.min(math.max(now - (TD.frameAt or now), 0), 0.1)
    TD.frameAt = now
    local list = {}
    if target.car then list[#list + 1] = { "car", localCar(), target.car } end
    if target.otherCar then list[#list + 1] = { "otherCar", Sync.deref(otherCarPath), target.otherCar } end
    if TD.drivenBy and target.drv then
        local own = TD.ownCarActor()
        local loc, rot = TD.carInterp("drv")
        if own and loc then follow(own, target.drv, { X = 0, Y = 0, Z = 0, Yaw = 0 }, true, 1, { loc = loc, rot = rot }) end
    end
    for _, e in ipairs(list) do
        local which, actor, tgt = e[1], e[2], e[3]
        local drivenHere = TD.driving and ((which == "car" and TD.driving == "H") or (which == "otherCar" and TD.driving == "G"))
        if actor and Twin.isTwin(actor) then pcall(Twin.doorEase, actor, dt) end
        if actor and Twin.isTwin(actor) and not drivenHere then
            local zero = { X = 0, Y = 0, Z = 0, Yaw = 0 }
            -- (a passenger: drawn in the past, smooth; the driver: where it is now - its own input must show at once)
            if TD.inTwin(actor) and inGhost.seat ~= 1 then
                local loc, rot = TD.carInterp(which)
                if loc then follow(actor, tgt, zero, true, 1, { loc = loc, rot = rot }) st.twinInterp = (st.twinInterp or 0) + 1 end
            elseif TD.inTwin(actor) or TD.OUTSIDE_EVERY_FRAME then
                -- (its driver, and from outside: where it is now, the old 0.6 per 33 ms step as a share of the way per
                -- this frame's time. Outside it was moved by the apply loop, 30 times a second, toward a sample
                -- extrapolated along its velocity and pulled back at each new sample: at 50+ fps the owner saw the
                -- other's car jerk - alpha 20 test, ping 13 ms, the frame rate steady)
                follow(actor, tgt, zero, true, 1 - (1 - SMOOTH) ^ (dt / 0.033))
            end
        end
    end
end

local function section(name, t0)
    local dt = (os.clock() - t0) * 1000
    local p = prof[name] or { ms = 0, n = 0, mx = 0 }
    prof[name] = p
    p.ms, p.n = p.ms + dt, p.n + 1
    if dt > p.mx then p.mx = dt end
    if CoopSyncHitch then CoopSyncHitch.op("players " .. name, dt) CoopSyncHitch.crumb("players after " .. name) end
    return os.clock()
end
local function applyTick()
    local ts = os.clock()
    local lines = readLines()
    ts = section("apply_read", ts)
    for _, line in ipairs(lines) do
        local t = {}
        for v in (line .. "\t"):gmatch("([^\t]*)\t") do t[#t + 1] = v end
        -- the garage: the puppets, the host's sky (W / WE / WC, weathersync) and music (RT / RN / RK / RI) only
        if garage and t[1] ~= "P" and t[1] ~= "KK" and t[1] ~= "W" and t[1] ~= "WE" and t[1] ~= "WC"
            and t[1] ~= "RT" and t[1] ~= "RN" and t[1] ~= "RK" and t[1] ~= "RI" then t[1] = "-" end
        if t[1] == "P" then
            local loc, rot = parse(t, 3)
            -- car tag: H host's car, G guest's car (older senders: none = H)
            local ptag = (t[10] and t[10] ~= "") and t[10] or "H"
            target.player = M.withVelocity(target.player, { loc = loc, rot = rot, seat = tonumber(t[9]) or 0, tag = ptag, time = tonumber(t[2]) })
            pushSample(target.player)
            lastPlayerRecv = M.nowMs()
            st.recv = st.recv + 1
            if #st.delays < 2000 then st.delays[#st.delays + 1] = M.nowMs() - tonumber(t[2]) end
            -- host: the client got out (or sits in its own car) -> its seat in the host's car is free again
            if role == "host" and (target.player.seat == 0 or ptag ~= "H") then seatOf.client = nil end
            -- client: the host left the client's car -> its seat there is free again
            if role == "client" and (target.player.seat == 0 or ptag ~= "G") then seatOfG.host = nil end
        elseif t[1] == "C" and role == "client" then
            local loc, rot = parse(t, 3)
            target.car = M.withVelocity(target.car, { loc = loc, rot = rot, time = tonumber(t[2]) })
            TD.carSample("car", target.car)
            st.recv = st.recv + 1
            local hs, cs = tonumber(t[9]) or 0, tonumber(t[10]) or 0
            seatOf.host, seatOf.client = hs > 0 and hs or nil, cs > 0 and cs or nil
            -- the host's ignition / lever: follow it (not the transient "starting", not right after our own K)
            local hIgn, hGear = tonumber(t[11]), tonumber(t[12])
            target.hostCtl = { ign = hIgn, gear = hGear, ltw = TD.parseLtw(t[14]) } -- (a twin driver toggles from this)
            target.busyH = t[13] -- seats of the host's car taken by devices
            -- the host sent a new car layout (a part came off, a device moved): rebuild the ghost
            local rebuilt = false
            if ownCar and layoutIn.ready and localCar() and layoutIn.readySeq ~= ghostSeq and not restyleCopy(localCar()) then
                Ghost.destroy(localCar()) carPath, carPuppeted = nil, false
                rebuilt = true
            end
            if ownCar and not localCar() then
                if carPath and not rebuilt then st.copyLost = (st.copyLost or 0) + 1 end -- (gone by itself)
                local a = spawnCarCopy(target.car)
                if a then carPath = Sync.ref(a) carPuppeted = true end
                -- the player sitting in the old ghost stays in the new one
                local pawn = localPawn()
                if a and rebuilt and inGhost and inGhost.tag == "H" and pawn then
                    pcall(function() pawn:K2_AttachToActor(a, FName("None"), 1, 1, 1, false) end)
                end
            end
            local car = localCar()
            -- (own-car mode: the car manager is the client's own car's - the host car copy's key / lever later)
            if car and not ownCar and M.nowMs() >= ctlHoldUntil and M.nowMs() >= ctlFollowUntil then
                local ign, gear = readControls()
                -- a local value that moved since we last looked is the player's own change, not yet sent (this
                -- runs before wheelFrame in the frame): leave it, wheelFrame sends it and holds the host's state
                local mine = function(what, v) return ctl[what] ~= nil and v ~= ctl[what] and not (what == "ign" and v == 1 and ctl.ign == 2) end
                if mine("ign", ign) or mine("gear", gear) then ign, gear = nil, nil end
                if hIgn and hIgn ~= 1 and hIgn >= 0 and ign and ign ~= hIgn and ign ~= 1 then
                    ctl.ign = hIgn setControl(car, "ign", hIgn) st.ctlFollowed = (st.ctlFollowed or 0) + 1
                    ctlFollowUntil = M.nowMs() + CTL_FOLLOW_MS
                end
                if hGear and hGear >= 0 and gear and gear ~= hGear then
                    ctl.gear = hGear setControl(car, "gear", hGear) st.ctlFollowed = (st.ctlFollowed or 0) + 1
                    ctlFollowUntil = M.nowMs() + CTL_FOLLOW_MS
                end
            end
        elseif t[1] == "S" and role == "host" then
            -- the client got in and asks for a seat (entry point = where it stood, car-local)
            local car = localCar()
            local entry = (t[3] ~= "-" and t[4] ~= "-") and { X = tonumber(t[3]), Y = tonumber(t[4]) } or nil
            seatOf.client = nil
            local n, why = nil, "no car"
            if car then n, why = chooseSeat(car, "client", entry, nil, t[5] == "x") end
            if n then seatOf.client = n end
            append(outFile, string.format("A\t%d\t%d\t%s", M.nowMs(), n or 0, n and SEAT_NAME[n] or ("no free seat (" .. tostring(why) .. ")")))
            st.seatRequests = (st.seatRequests or 0) + 1
            if not n then st.denied = (st.denied or 0) + 1 st.lastDenied = "client: " .. tostring(why) end
        elseif t[1] == "A" and role == "client" then
            seatPending = false
            local n = tonumber(t[3]) or 0
            local pawn = localPawn()
            if n > 0 then
                myAssigned = n
                st.seated = (st.seated or 0) + 1
            elseif pawn and inGhost then
                ghostLeave(pawn, t[4] or "denied")
            elseif pawn and Sync.parentOf(pawn) then
                exitCar(pawn, t[4] or "denied")
            end
        elseif t[1] == "SG" and role == "client" then
            -- own-car mode: the host got into this client's car (its ghost there) and asks for a seat
            local car = Sync.deref(ownCarPath)
            local entry = (t[3] ~= "-" and t[4] ~= "-") and { X = tonumber(t[3]), Y = tonumber(t[4]) } or nil
            local pawn = localPawn()
            local par = pawn and Sync.parentOf(pawn)
            seatOfG.client = (car and par and par:GetFullName() == car:GetFullName()) and 1 or nil
            seatOfG.host = nil
            local n, why = nil, "no car"
            if car then n, why = chooseSeat(car, "host", entry, seatOfG, t[5] == "x") end
            if n then seatOfG.host = n end
            append(outFile, string.format("AG\t%d\t%d\t%s", M.nowMs(), n or 0, n and SEAT_NAME[n] or ("no free seat (" .. tostring(why) .. ")")))
            st.seatRequests = (st.seatRequests or 0) + 1
        elseif t[1] == "AG" and role == "host" then
            local n, pawn = tonumber(t[3]) or 0, localPawn()
            if inGhost and inGhost.tag == "G" then
                inGhost.pending = false
                if n > 0 then inGhost.seat = n st.seated = (st.seated or 0) + 1
                elseif pawn then ghostLeave(pawn, t[4] or "denied") end
            end
        elseif t[1] == "IG" and role == "client" then
            -- own-car mode: the host drives this client's car from its ghost: its input for the real car here
            wheelInG = { v = { tonumber(t[3]) or 0, tonumber(t[4]) or 0, tonumber(t[5]) or 0, tonumber(t[6]) or 0 }, recvMs = M.nowMs() }
            st.inRecv = (st.inRecv or 0) + 1
        elseif t[1] == "X" and role == "host" then
            local ok, r = pcall(M.removeSeatDevice, tonumber(t[4]) or 0)
            st.lastDeviceRequest = ok and r or ("ERR " .. tostring(r))
        elseif t[1] == "DV" then
            pcall(TD.onDrive, t)
        elseif t[1] == "VD" then
            if t[3] == myTag() and TD.drivenBy then
                local loc, rot = parse(t, 4)
                target.drv = M.withVelocity(target.drv, { loc = loc, rot = rot, time = tonumber(t[2]) })
                TD.carSample("drv", target.drv)
            end
        elseif t[1] == "DR" then
            -- the other player works a door of this side's car (from its twin of it)
            local car = role == "host" and localCar() or Sync.deref(ownCarPath)
            -- (the own car the game's context first, held TD.DR_CTX_MS: a door's open / shut goes by the manager's flag of
            -- the context car - with the other's twin the context (this player had aimed at it), the lid read "shut"
            -- and the other player's shut did nothing; it stood open for good. Owner's two-games test 2026-11-11: "the
            -- trunk can shut and not open again"; trunk-test)
            if car and TD.native and Native and not inGhost and not Sync.parentOf(localPawn()) then
                pcall(Native.use, car)
                TD.ownCtxUntil = M.nowMs() + TD.DR_CTX_MS
            end
            local r = car and Twin.setDoor(car, tonumber(t[3]) or 0, t[4] or "toggle") or "no car"
            TD.logDoor("d", t[3], r)
            st.doorsDone = (st.doorsDone or 0) + 1
            st.lastDoorDone = tostring(t[3]) .. ":" .. tostring(r)
        elseif t[1] == "KK" then
            kicked(tonumber(t[3]) or 0, tonumber(t[4]) or 0)
        elseif t[1] == "RO" then
            TD.RUN.hit(tonumber(t[3]) or 0, tonumber(t[4]) or 0, tonumber(t[5]) or 0, tonumber(t[6]) or 0, tonumber(t[7]) or 0)
        elseif t[1] == "L" and role == "client" then
            onHostLeaving(t[3] or "?")
        elseif t[1] == "V" then
            target.pose = t[3] -- the other's car: wheels, steering wheel, key, needles (its twin on this side)
            st.poseAt, st.poseSentAt = M.nowMs(), tonumber(t[2])
        elseif t[1] == "KG" and role == "client" and ownCar then
            -- the host, at the wheel of this client's car (its twin there), turned the key / moved the lever
            local own, what, v = Sync.deref(ownCarPath), t[3], tonumber(t[4])
            if own and v and (what == "ign" or what == "gear") then setControl(own, what, v) st.ctlApplied = (st.ctlApplied or 0) + 1
            elseif own and v and TD.ltwDef(what) then st.lastLtwDone = what .. "=" .. v .. ":" .. tostring(TD.toggleLtw(own, what, v)) st.ctlApplied = (st.ctlApplied or 0) + 1 end
        elseif t[1] == "EQ" then
            -- the other player's car contents (its twin here carries them)
            if t[3] and t[3] ~= "" then target.equip, target.equipSeq = Twin.parseEquip(t[3]), (target.equipSeq or 0) + 1 st.equipRecv = (st.equipRecv or 0) + 1 end
        elseif t[1] == "EP" then
            -- the other player's parts' paint (its twin here shows it: TD.equipTick)
            if t[3] then target.paint, target.paintSeq = t[3], (target.paintSeq or 0) + 1 end
        elseif t[1] == "EX" then
            -- the other player took a part off / put one on its twin of this side's car
            st.lastEx = Twin.ownerEquip(t[3] or "", t[4] or "-") st.equipExDone = (st.equipExDone or 0) + 1
        elseif t[1] == "ES" then
            -- the other player's parts' health / fuel / battery (its twin here follows)
            if t[3] and t[3] ~= "" then target.state, target.stateSeq = Twin.parseState(t[3]), (target.stateSeq or 0) + 1 st.stateRecv = (st.stateRecv or 0) + 1 end
        elseif t[1] == "TU" then
            -- the other player's car's part parameters (its twin here drives by them: tuning.lua)
            if TD.tuning and t[3] and t[3] ~= "" then pcall(TD.tuning.applyOwner, t[3]) st.tuningRecv = (st.tuningRecv or 0) + 1 end
        elseif t[1] == "LI" then
            -- the other player's car lights (its twin here shows them)
            if t[3] and t[3] ~= "" then target.lights = t[3] st.lightsRecv = (st.lightsRecv or 0) + 1 end
        elseif t[1] == "HN" then
            -- the other player's car horn (its twin here honks)
            TD.setTwinHorn(t[3] == "1", tonumber(t[4]))
            st.hornRecv = (st.hornRecv or 0) + 1
        elseif t[1] == "HR" then
            -- the other player honks in its twin of this side's car: this side's real car honks
            st.lastHornDone = tostring(t[3]) .. ":" .. tostring(TD.askedHorn(t[3] == "1"))
        elseif t[1] == "RT" then
            -- the track the other player's own radio plays (its twin's radio here plays it)
            if t[3] and t[3] ~= "" then
                if t[3] ~= target.track then target.nextTrack = nil end
                target.track = t[3]
                target.trackPos, target.trackAt = tonumber(t[4]), M.nowMs()
                st.trackRecv = (st.trackRecv or 0) + 1
            end
        elseif t[1] == "RN" then
            -- the other player's next track (queued there; here too while following)
            target.nextTrack, target.nextAt = t[3], M.nowMs()
            st.nextRecv = (st.nextRecv or 0) + 1
        elseif t[1] == "BI" then
            -- a hit seen on the other side: the shared speed on this side's car, its twin here moved on at it
            local nx, ny, vc = tonumber(t[3]), tonumber(t[4]), tonumber(t[5])
            local ok, twinPath = pcall(Twin.bumpGot, nx, ny, vc)
            st.bumpGot = (st.bumpGot or 0) + (ok and 1 or 0)
            local tw = ok and twinPath and Sync.deref(twinPath)
            if tw then TD.kickTwin(tw, nx, ny, vc) end
        elseif t[1] == "CS" then
            -- the other player's car storages (filled into its twin here by storeTick)
            local f = {}
            for i = 3, #t do f[#f + 1] = t[i] end
            target.store = f
            st.storeRecv = (st.storeRecv or 0) + 1
        elseif t[1] == "CX" then
            -- the other player put / took something in its twin of this side's car: this side's real storage
            local ok, what, n = pcall(Twin.Store.ownerChange, t[3], t[4], tonumber(t[5]), t[6] or "", t[7], t[8], tonumber(t[9]))
            if ok and what == "nack" then append(outFile, string.format("CN\t%d\t%s\t%d\t%s", M.nowMs(), t[3], n, t[6]))
            elseif ok and what == "missing" then append(outFile, string.format("CT\t%d\t%s\t%d\t%s", M.nowMs(), t[3], n, (t[6] or ""):match("^([^{*]*)"))) end
            TD.store.checkMs = -1e9
            st.storeDone = (st.storeDone or 0) + 1
        elseif t[1] == "CN" then
            pcall(Twin.Store.giveBack, tonumber(t[4]) or 0, t[5] or "")
        elseif t[1] == "CT" then
            pcall(Twin.Store.takeBack, tonumber(t[4]) or 0, t[5] or "")
        elseif t[1] == "RI" then
            -- the other player's radio DJ break (here too while following its radio)
            st.djRecv = (st.djRecv or 0) + 1
            if t[3] == "-" then
                -- it ended there (skipped with the channel button too): here as well
                local ok, stopped = pcall(Twin.djStop)
                st.djStopped = (st.djStopped or 0) + ((ok and stopped) and 1 or 0)
            elseif t[3] and t[3] ~= "" and M.nowMs() - TD.music.followMs < 1000 then
                local ok, played = pcall(Twin.djPlay, t[3])
                st.djPlayed = (st.djPlayed or 0) + ((ok and played) and 1 or 0)
            end
        elseif t[1] == "RS" then
            target.radioOn, target.radioAt = t[3] == "1", M.nowMs()
        elseif t[1] == "RK" then
            -- the other player changed channel on a radio following this side's: the station's radio changes (the
            -- garage: the host's own car's; the zone: the radio playing here - the car this player is in or by)
            local m = (CoopSyncFirst or FindFirstOf)("BP_CarManager_C")
            local c = m and m.NewCarActor
            local own = Twin.ownCar()
            local car = garage and own or (TD.isStation() and c and c:IsValid() and c) or nil
            local ok = car and Twin.changeChannel(car, tonumber(t[3]) or 1)
            st.lastChannelDone = tostring(ok and true or false)
            TD.music.checkMs = -1e9
        elseif t[1] == "EY" then
            -- the other player repaired / refuelled / charged a part of this side's car on its twin
            st.lastEy = Twin.ownerState(t[3] or "", t[4] or "", tonumber(t[5])) st.stateEyDone = (st.stateEyDone or 0) + 1
        elseif t[1] == "Y" then
            takeLayoutLine(t)
        elseif t[1] == "G" and role == "host" then
            -- own-car mode: the client's own car -> the host's copy of it
            local loc, rot = parse(t, 3)
            target.otherCar = M.withVelocity(target.otherCar, { loc = loc, rot = rot, time = tonumber(t[2]) })
            TD.carSample("otherCar", target.otherCar)
            lastOtherRecv = M.nowMs()
            target.guestCtl = { ign = tonumber(t[9]), gear = tonumber(t[10]), ltw = TD.parseLtw(t[12]) }
            target.busyG = t[11] -- seats of the guest's car taken by devices
        elseif t[1] == "K" and role == "host" then
            -- the client driver turned the key / moved the lever: do it on the real car
            local car, what, v = localCar(), t[3], tonumber(t[4])
            if car and v and (what == "ign" or what == "gear") then
                setControl(car, what, v)
                st.ctlApplied = (st.ctlApplied or 0) + 1
            elseif car and v and TD.ltwDef(what) then
                -- (own-car mode: the guest worked a lever in its twin of this car)
                st.lastLtwDone = what .. "=" .. v .. ":" .. tostring(TD.toggleLtw(car, what, v))
                st.ctlApplied = (st.ctlApplied or 0) + 1
            end
        elseif t[1] == "I" and role == "host" then
            wheelIn = { v = { tonumber(t[3]) or 0, tonumber(t[4]) or 0, tonumber(t[5]) or 0, tonumber(t[6]) or 0 }, recvMs = M.nowMs() }
            st.inRecv = (st.inRecv or 0) + 1
        elseif (t[1] == "W" or t[1] == "WE" or t[1] == "WC") and role == "client" and M.onWeather then
            local okW, eW = pcall(M.onWeather, t) -- weathersync.lua
            if not okW then err("weather: " .. tostring(eW)) end
        elseif t[1] == "MK" and M.onMarks then
            local okM, eM = pcall(M.onMarks, t) -- marksync.lua
            if not okM then err("marks: " .. tostring(eM)) end
        end
    end
    ts = section("apply_parse", ts)
    -- the other player left (went home, died, link lost): no P for PLAYER_GONE_MS -> hide its puppet and
    -- free its seat; the puppet comes back with the next P
    if target.player and lastPlayerRecv and M.nowMs() - lastPlayerRecv > PLAYER_GONE_MS then
        if not st.playerGone then
            st.playerGone = true
            st.playerGoneCount = (st.playerGoneCount or 0) + 1
            local p = Sync.deref(puppetPath)
            if p then pcall(function() p:SetActorHiddenInGame(true) end) end
            setPuppetSolid(false)
            if role == "host" then seatOf.client = nil end
        end
    elseif st.playerGone then
        st.playerGone = false
        local p = Sync.deref(puppetPath)
        if p then pcall(function() p:SetActorHiddenInGame(false) end) end
    end
    if target.player and not st.playerGone then
        local p = ensurePuppet(target.player.loc)
        if p then
            -- pawn location is the capsule centre; the mesh sits at the mesh component's relative offset
            local off = { X = 0, Y = 0, Z = meshRel and meshRel.loc.Z or 0, Yaw = meshRel and meshRel.rot.Yaw or 0 }
            local seat = target.player.seat or 0
            -- the car it sits in (own-car mode: the host's or the guest's - real car or ghost on this side)
            local car = seat > 0 and target.player.tag ~= "-" and carForTag(target.player.tag or "H") or nil
            if car then
                puppetOff = nil
                -- seated: ride with that car at the seat, no world-space following
                local cp = Sync.ref(car)
                if attachedTo ~= cp then
                    if attachedTo then pcall(function() p:K2_DetachFromActor(1, 1, 1) end) end
                    pcall(function() p:K2_AttachToActor(car, FName("None"), 1, 1, 1, false) end) -- KeepWorld
                    attachedTo = cp
                end
                local sr = seatRel(seat)
                local want = { X = sr.X, Y = sr.Y, Z = sr.Z + off.Z }
                local rc = p.RootComponent
                local rel = rc.RelativeLocation
                if (rel.X - want.X) ^ 2 + (rel.Y - want.Y) ^ 2 + (rel.Z - want.Z) ^ 2 > 1 then
                    pcall(function() p:K2_SetActorRelativeLocation(want, false, {}, true) end)
                    pcall(function() p:K2_SetActorRelativeRotation({ Pitch = 0, Yaw = off.Yaw, Roll = 0 }, false, {}, true) end)
                end
                setAnimState(p, "sit")
                setPuppetSolid(false)
                -- hands: on the wheel in the driver seat, on the knees elsewhere
                local arms = seat == 1 and "wheel" or "lap"
                local pose = Sync.deref(posePath)
                if pose and poseArms ~= arms then
                    local okP, eP = pcall(M.sitPose, pose, arms)
                    if not okP then err("arms: " .. tostring(eP)) end
                    poseArms = arms
                end
                local l = p:K2_GetActorLocation()
                trace("puppet", { X = l.X, Y = l.Y, Z = l.Z - off.Z })
            else
                if attachedTo then
                    pcall(function() p:K2_DetachFromActor(1, 1, 1) end)
                    attachedTo = nil
                end
                setPuppetSolid(seat == 0) -- in a car, still waiting for its seat (-1): not solid either
                -- the position: every frame, interpolated (puppetFrame)
                puppetOff = off
                local l = p:K2_GetActorLocation()
                trace("puppet", { X = l.X, Y = l.Y, Z = l.Z - off.Z })
                if seat > 0 then
                    -- sitting in a car this side has no copy of (the garage): the sitting pose where the seat is
                    setAnimState(p, "sit")
                    local pose = Sync.deref(posePath)
                    if pose and poseArms ~= "wheel" then
                        local okP, eP = pcall(M.sitPose, pose, "wheel")
                        if not okP then err("arms: " .. tostring(eP)) end
                        poseArms = "wheel"
                    end
                    goto seated
                end
                -- Sample pairs are uneven (~22 fps, the host's state tick blocks the game thread), so the
                -- instantaneous speed often drops to 0 mid-walk: the speed over the last TD.SPEED_WINDOW_MS of
                -- samples (sender clock), idle after it stayed low for IDLE_HOLD_MS. (An average of the
                -- instantaneous speed kept walking ~1 s after the player stood - a kick's knock-back, owner.)
                speedEma = TD.histSpeed()
                local now = M.nowMs()
                local want = speedEma > RUN_SPEED and "run" or (speedEma > WALK_SPEED and "walk" or "idle")
                if want == "idle" and animState ~= "idle" and animState ~= "sit" and animState ~= nil then
                    lowSince = lowSince or now
                    if now - lowSince < IDLE_HOLD_MS then want = animState end
                else
                    lowSince = nil
                end
                setAnimState(p, want)
                ::seated::
            end
            -- foot motion relative to the puppet (evidence that the clip is really evaluated)
            if animState ~= "sit" and #footSamples < 200 then
                local ok, fl = pcall(function() return p.SkeletalMeshComponent:GetSocketLocation(FName("foot_l")) end)
                if ok and fl then
                    local al = p:K2_GetActorLocation()
                    footSamples[#footSamples + 1] = { X = fl.X - al.X, Y = fl.Y - al.Y, Z = fl.Z - al.Z }
                end
            end
        end
    end
    ts = section("apply_puppet", ts)
    if garage then return end -- the garage: puppets only, no cars
    if target.car then
        local car = localCar()
        if car and not carPuppeted then
            -- the host owns the car: stop this copy's own vehicle simulation so it cannot fight the updates
            for _, c in ipairs(FindAllOf("VehicleControllerComponent") or {}) do
                if Sync.alive(c) and c:GetOuter():IsValid() and c:GetOuter():GetFullName() == car:GetFullName() then
                    pcall(function() c:SetComponentTickEnabled(false) end)
                end
            end
            carPuppeted = true
        end
        if car then
            -- (a twin the local player sits in: every frame, TD.twinFrame)
            local l = (Twin.isTwin(car) and (TD.inTwin(car) or TD.OUTSIDE_EVERY_FRAME)) and car:K2_GetActorLocation() or follow(car, target.car, { X = 0, Y = 0, Z = 0, Yaw = 0 }, Twin.isTwin(car))
            ts = section("car_follow", ts)
            if target.pose and Twin.isTwin(car) then TD.doorGuard = true pcall(Twin.applyPose, car, target.pose) TD.doorGuard = false end -- (its door shuts are the pose, not the exit: TD.onDoorCall)
            ts = section("car_pose", ts)
            if Twin.isTwin(car) then
                TD.equipTick(car) ts = section("car_equip", ts)
                TD.storeTick(car) ts = section("car_store", ts)
                TD.bump(car, target.car.vel)
                TD.clearOwnCar(car)
            end
            trace("carcopy", l)
        end
    end
    -- host, own-car mode: the copy of the client's car; gone with the client (home, death: its car goes home)
    if target.otherCar then
        if lastOtherRecv and M.nowMs() - lastOtherRecv > PLAYER_GONE_MS then
            local c = Sync.deref(otherCarPath)
            local pawn = localPawn()
            if pawn and inGhost then ghostLeave(pawn, "owner left") end -- no leaving in another's car
            if c then st.copiesRemoved = (st.copiesRemoved or 0) + removeCopy(c) end
            otherCarPath, target.otherCar = nil, nil
            st.otherCarGone = (st.otherCarGone or 0) + 1
        else
            local c = Sync.deref(otherCarPath)
            if c and layoutIn.ready and layoutIn.readySeq ~= ghostSeq and not restyleCopy(c) then Ghost.destroy(c) c, otherCarPath = nil, nil end
            if not c then
                if otherCarPath then st.copyLost = (st.copyLost or 0) + 1 end -- (gone by itself: fell out of the world)
                localCar() -- the host's own car is found (and cached) before the copy exists
                c = spawnCarCopy(target.otherCar)
                if c then otherCarPath = Sync.ref(c) end
            end
            if c then
                if not (Twin.isTwin(c) and (TD.inTwin(c) or TD.OUTSIDE_EVERY_FRAME)) then follow(c, target.otherCar, { X = 0, Y = 0, Z = 0, Yaw = 0 }, Twin.isTwin(c)) end -- (sat in: TD.twinFrame)
                ts = section("car_follow", ts)
                if target.pose and Twin.isTwin(c) then TD.doorGuard = true pcall(Twin.applyPose, c, target.pose) TD.doorGuard = false end
                ts = section("car_pose", ts)
                if Twin.isTwin(c) then
                    TD.equipTick(c) ts = section("car_equip", ts)
                    TD.storeTick(c) ts = section("car_store", ts)
                    TD.bump(c, target.otherCar.vel)
                end
            end
        end
    end
    section("apply_car", ts)
end

---------------------------------------------------------------------------------------------------
-- the wheel: who drives, the client's input stream, the host applying it

-- Whoever sits on seat 1 drives (no wheel key: get out and take the driver seat). While the client
-- drives it streams its input; the host applies it every frame.
local lastInputSend = 0
local lastDriver
local lastInputSendG, gDriving = 0, false
-- Ignition / lever while sitting in a twin. The car manager (BP_CarManager_C) holds ONE ignition state and ONE lever
-- for the game - the own car's. In the twin it holds the owner's (C / G lines) instead: the prompt at the key reads
-- right ("Выключить" when the owner's engine runs) and the game's own key / lever action changes it (observed: that
-- action had put the own car in park before) - the change goes to the owner (K / KG). Back on getting out.
local function twinControls()
    local m = Sync.deref(carManagerPath) or (CoopSyncFirst or FindFirstOf)("BP_CarManager_C")
    if not (m and m:IsValid()) then return end
    if not (inGhost and inGhost.twin) then return end
    if inGhost.exitAt then return end -- (getting out: the own state is back in the manager - not the player's change)
    local owner = inGhost.tag == "H" and target.hostCtl or target.guestCtl
    local now = M.nowMs()
    if not inGhost.savedCtl then
        if not (owner and owner.ign and owner.ign >= 0) then return end
        inGhost.savedCtl = { ign = m.CarIgnitionState, gear = m.MyCarGearBox }
        inGhost.savedCtl.ign0, inGhost.savedCtl.gear0 = inGhost.savedCtl.ign, inGhost.savedCtl.gear
        if not TD.native then TD.doorSnap, TD.doorSnapUntil = TD.readDoorStates(m), nil end
        inGhost.expect, inGhost.ctlHold = { ign = owner.ign, gear = owner.gear }, 0
        pcall(function() m.CarIgnitionState = owner.ign m.MyCarGearBox = owner.gear end)
        -- the lights / top light / wipers likewise (an owner without them on its lines: left alone)
        if owner.ltw then
            pcall(Twin.holdOwnLights, Twin.ownCar()) -- (the own car keeps its lights while the manager holds the owner's)
            inGhost.savedCtl.ltw = TD.readLtw(m)
            inGhost.expectLtw, inGhost.ltwHold = {}, 0
            for _, d in ipairs(TD.LTW) do
                inGhost.expectLtw[d[1]] = owner.ltw[d[1]]
                if inGhost.savedCtl.ltw[d[1]] ~= owner.ltw[d[1]] then TD.setLtw(m, d[1], owner.ltw[d[1]]) end
            end
        end
        return
    end
    if inGhost.expectLtw then
        local cur = TD.readLtw(m)
        for _, d in ipairs(TD.LTW) do
            local what = d[1]
            if cur[what] >= 0 and cur[what] ~= inGhost.expectLtw[what] then
                -- the player worked the lever / switch here (the game's own, on the manager): to the owner
                append(outFile, string.format("%s\t%d\t%s\t%d", inGhost.tag == "H" and "K" or "KG", now, what, cur[what]))
                st.twinCtlSent = (st.twinCtlSent or 0) + 1
                st.lastLtwSent = what .. "=" .. cur[what]
                inGhost.expectLtw[what], inGhost.ltwHold = cur[what], now + TD.LTW_HOLD_MS
            elseif owner and owner.ltw and owner.ltw[what] ~= inGhost.expectLtw[what] and now >= inGhost.ltwHold then
                -- the owner changed it (or our K arrived): follow
                inGhost.expectLtw[what] = owner.ltw[what]
                TD.setLtw(m, what, owner.ltw[what])
            end
        end
    end
    for _, what in ipairs({ "ign", "gear" }) do
        local field = what == "ign" and "CarIgnitionState" or "MyCarGearBox"
        local cur = tonumber(m[field])
        if cur and cur ~= inGhost.expect[what] and not (what == "ign" and cur == 1 and inGhost.expect.ign == 2) then
            -- the player's change in the game (ignition goes 0 -> 1 "starting" -> 2: send where it heads)
            local v = (what == "ign" and cur == 1) and 2 or cur
            append(outFile, string.format("%s\t%d\t%s\t%d", inGhost.tag == "H" and "K" or "KG", now, what, v))
            st.twinCtlSent = (st.twinCtlSent or 0) + 1
            inGhost.expect[what], inGhost.ctlHold = v, now + CTL_HOLD_MS
        elseif owner and owner[what] and owner[what] >= 0 and owner[what] ~= inGhost.expect[what] and now >= inGhost.ctlHold then
            -- the owner changed it (or our K arrived): follow
            inGhost.expect[what] = owner[what]
            pcall(function() m[field] = owner[what] end)
        end
    end
end
-- getting out of a twin: the own car's ignition / lever back into the manager
twinControlsRestore = function()
    if TD.horn.asked then -- (out of the other's twin with the horn key down: the owner's car stops)
        TD.horn.asked = false
        append(outFile, string.format("HR\t%d\t0", M.nowMs()))
    end
    if not (inGhost and inGhost.savedCtl) then return end
    local m = Sync.deref(carManagerPath) or (CoopSyncFirst or FindFirstOf)("BP_CarManager_C")
    local sc = inGhost.savedCtl
    pcall(function() m.CarIgnitionState = sc.ign m.MyCarGearBox = sc.gear end)
    -- (changed by the other player meanwhile - its K into the kept state: the own car's key / lever turned there with
    -- the game's own animation, from where they stood; set straight, the lever stood at drive with the gear in park)
    local own = Twin.ownCar()
    if own and sc.gear0 and sc.gear ~= sc.gear0 then
        pcall(function() m.MyCarGearBox = sc.gear0 own:ToggleGearBoxState(sc.gear0, false) end)
        st.ctlRestoredAnimated = (st.ctlRestoredAnimated or 0) + 1
    end
    if own and sc.ign0 and sc.ign ~= sc.ign0 then
        pcall(function() m.CarIgnitionState = sc.ign0 own:ToggleIgnitionState(sc.ign) end)
    end
    local saved = inGhost.savedCtl.ltw
    if saved then
        local cur = TD.readLtw(m)
        for _, d in ipairs(TD.LTW) do
            if saved[d[1]] >= 0 and cur[d[1]] ~= saved[d[1]] then TD.setLtw(m, d[1], saved[d[1]]) end
        end
    end
    pcall(Twin.releaseOwnLights)
end

-- The other player drives this side's car (it sits at its wheel in its twin) while the owner is out of it: the car's own
-- input fields (User*Input, writeInput) reach its vehicle controller only with the game's own driver inside, and the game
-- set the parking brake when the owner got out - the other's pedals moved nothing (cars-test). With nobody of this side
-- inside, the input goes straight into the vehicle controller (as the bots drive), the parking brake released while the
-- throttle is pressed (once a second at most).
function TD.releaseBrake(car, v)
    -- (own-car mode only - the guest's G lines come: in the frozen guest mode the car's own path drives it, drive-test)
    if role == "host" and not lastOtherRecv then return end
    local pawn = localPawn()
    local par = pawn and Sync.parentOf(pawn)
    if par and par:GetAddress() == car:GetAddress() then return end -- (the owner inside: the car's own path)
    local vc = TD.vcPath and Sync.deref(TD.vcPath)
    if not (vc and vc:GetOuter():GetAddress() == car:GetAddress()) then
        vc = nil
        for _, c in ipairs(FindAllOf("VehicleControllerComponent") or {}) do
            if Sync.alive(c) and c:GetOuter():IsValid() and c:GetOuter():GetAddress() == car:GetAddress() then vc = c end
        end
        TD.vcPath = vc and Sync.ref(vc) or nil
    end
    if not vc then return end
    -- (the lever on park - 1; 0 is drive: the gas moves nothing, the parking brake stays, as with the game's driver;
    -- written in park the car rolled off - wheel-test)
    local _, gear = readControls()
    if gear == 1 then v = ZERO end
    pcall(function() vc.ThrottleInput, vc.BrakeInput, vc.SteerInput, vc.HandbrakeInput = v[1] or 0, v[2] or 0, v[3] or 0, v[4] or 0 end)
    if not (v[1] and v[1] ~= 0) then return end
    local now = M.nowMs()
    if now - (TD.brakeAt or -1e9) < 1000 then return end
    TD.brakeAt = now
    pcall(function() vc:SetParkingBrakeActive(false) vc:Wake() end)
    st.brakeReleased = (st.brakeReleased or 0) + 1
end
local function wheelFrame()
    if garage then
        if TD.ownSeat and TD.ownSeat.seated then
            local own = Twin.ownCar()
            if own then pcall(writeInput, own, ZERO) end
        end
        return
    end
    pcall(twinControls)
    -- (on a back seat of the own car: the game's car input still goes to the car - its pedals / wheel held off, every
    -- frame as the car BP rewrites them; the other player at the wheel drives it from its side)
    if TD.ownSeat and TD.ownSeat.seated then
        local own = Twin.ownCar()
        if own then pcall(writeInput, own, ZERO) end
    end
    -- own-car mode, the guest's car: the host drives it from its ghost (IG lines) / the client applies that
    if role == "host" and inGhost and inGhost.tag == "G" and inGhost.seat == 1 and not TD.native then -- (native: the driver's side simulates the car)
        local now = M.nowMs()
        if now - lastInputSendG >= INPUT_SEND_MS then
            lastInputSendG = now
            local v = ghostInput(target.otherCar) -- (twin: the car interface axes; ghost: the character's)
            append(outFile, string.format("IG\t%d\t%.3f\t%.3f\t%.3f\t%.3f", now, v[1], v[2], v[3], v[4]))
            st.inSent = (st.inSent or 0) + 1
        end
    end
    if role == "client" and ownCar then
        local own = Sync.deref(ownCarPath)
        if own and seatOfG.host == 1 and not TD.native then
            -- every frame (the car BP keeps what was written); stale -> released
            if wheelInG and M.nowMs() - wheelInG.recvMs <= INPUT_STALE_MS then writeInput(own, wheelInG.v) TD.releaseBrake(own, wheelInG.v) st.inApplied = (st.inApplied or 0) + 1
            else writeInput(own, ZERO) TD.releaseBrake(own, ZERO) end
            gDriving = true
        elseif own and gDriving then
            writeInput(own, ZERO) TD.releaseBrake(own, ZERO) -- the host's last input must not stick
            gDriving = false
        end
    end
    local car = localCar()
    if not car then return end
    local driver = driverRole()
    if role == "host" and lastDriver == "client" and driver ~= "client" then
        writeInput(car, ZERO) TD.releaseBrake(car, ZERO) -- the client's last input must not stick
    end
    if driver ~= lastDriver then st.driverChanges = (st.driverChanges or 0) + 1 lastDriver = driver end
    if role == "client" then
        -- the player's own key / lever changes (anything not set by following the host) -> K to the host
        local ign, gear = readControls()
        if ign then
            if ctl.ign == nil then ctl.ign, ctl.gear = ign, gear end
            if M.nowMs() < ctlFollowUntil then
                ctl.ign, ctl.gear = ign, gear -- our copy is still moving to the host's state
            elseif driver == "client" and myAssigned == 1 and not ownCar then
                -- (own-car mode: this manager is the client's own car's, not the host's - not sent)
                for _, c in ipairs({ { "ign", ign }, { "gear", gear } }) do
                    local what, v = c[1], c[2]
                    -- ignition goes 0 -> 1 (starting) -> 2: on "starting" send where it is heading (2), the
                    -- host turns its key with its own animation; reaching 2 later is then no change
                    if what == "ign" and v == 1 then v = 2 end
                    if v ~= ctl[what] then
                        append(outFile, string.format("K\t%d\t%s\t%d", M.nowMs(), what, v))
                        ctl[what] = v
                        ctlHoldUntil = M.nowMs() + CTL_HOLD_MS
                        st.ctlSent = (st.ctlSent or 0) + 1
                    end
                end
            else
                ctl.ign, ctl.gear = ign, gear
            end
        end
        if driver == "client" and myAssigned == 1 and not (TD.native and inGhost and ownCar) then
            local now = M.nowMs()
            local pawn = localPawn()
            if now - lastInputSend >= INPUT_SEND_MS and pawn and Sync.parentOf(pawn) then
                lastInputSend = now
                -- in the host's ghost (own-car mode) the car input comes from the character's input events
                local v = (inGhost and inGhost.tag == "H") and ghostInput(target.car) or readInput(car)
                append(outFile, string.format("I\t%d\t%.3f\t%.3f\t%.3f\t%.3f", now, v[1], v[2], v[3], v[4]))
                st.inSent = (st.inSent or 0) + 1
            end
        end
    elseif driver == "client" and not (TD.native and lastOtherRecv) then -- (own-car mode, native: the driver's side simulates)
        -- every frame, so the host's own (passenger) input events cannot win; stale input -> released
        if wheelIn and M.nowMs() - wheelIn.recvMs <= INPUT_STALE_MS then
            writeInput(car, wheelIn.v)
            TD.releaseBrake(car, wheelIn.v)
            st.inApplied = (st.inApplied or 0) + 1
        else
            writeInput(car, ZERO) TD.releaseBrake(car, ZERO)
            st.inStale = (st.inStale or 0) + 1
        end
    end
end

function M.wheelInfo()
    local car = localCar()
    if not car then return "car=none" end
    local v, l, vel = readInput(car), car:K2_GetActorLocation(), car:GetVelocity()
    return string.format("driver=%s my_seat=%d input=%.2f,%.2f,%.2f,%.2f car=%.1f,%.1f,%.1f speed=%.0f changes=%d in_sent=%d in_recv=%d in_applied=%d in_stale=%d",
        tostring(driverRole()), mySeat() or 0, v[1], v[2], v[3], v[4], l.X, l.Y, l.Z, math.sqrt(vel.X * vel.X + vel.Y * vel.Y),
        st.driverChanges or 0, st.inSent or 0, st.inRecv or 0, st.inApplied or 0, st.inStale or 0)
end

-- The client's own (real) car in own-car mode, the local car otherwise.
function M.ownCarActor() return (role == "client" and ownCar) and Sync.deref(ownCarPath) or localCar() end

-- Own-car mode as this side sees it: player cars in the world, own car and copy positions (for the tests).
function M.carsInfo()
    local n = 0
    for _, x in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
        if Sync.alive(x) and x:GetFullName():find(":PersistentLevel%.") and not (Twin and Twin.isTwin(x)) then n = n + 1 end
    end
    local function at(p)
        local a = Sync.deref(p)
        if not a then return "-" end
        local l = a:K2_GetActorLocation()
        return string.format("%.1f,%.1f,%.1f", l.X, l.Y, l.Z)
    end
    local own = role == "client" and ownCarPath or carPath
    local copy = role == "client" and (ownCar and carPath or nil) or otherCarPath
    local cp = Sync.deref(copy)
    local kind = cp and (Twin.isTwin(cp) and "twin" or "ghost") or "-"
    return string.format("cars=%d copy_kind=%s own=%s copy=%s copies_spawned=%d ghost_meshes=%d layouts_sent=%d layouts_received=%d copies_removed=%d other_gone=%d copy_lost=%d split=%s",
        n, kind, at(own), at(copy), st.carCopies or 0, st.ghostMeshes or 0, st.layoutsSent or 0, st.layoutsReceived or 0, st.copiesRemoved or 0, st.otherCarGone or 0, st.copyLost or 0, tostring(st.split == true))
end

-- Ignition / lever as this side sees them, and the K traffic (for the tests).
function M.controlsInfo()
    local ign, gear = readControls()
    return string.format("ign=%s gear=%s ctl_sent=%d ctl_applied=%d ctl_followed=%d", tostring(ign), tostring(gear),
        st.ctlSent or 0, st.ctlApplied or 0, st.ctlFollowed or 0)
end

-- Seat table and devices as this side sees them (for the tests).
-- The doors of the cars (for the tests): door n of the own car open (owner side), of the other's twin its mesh's
-- car-relative yaw / pitch (the owner's pose on it), what went out / came in.
function M.doorInfo(n)
    local own = Twin.ownCar()
    local g = ghostOf(otherTag())
    local twinRot = "-"
    local d = g and Twin.isTwin(g) and Twin.door(g, n)
    if d then
        pcall(function()
            local rel = KML:ComposeTransforms(d.MainMesh:K2_GetComponentToWorld(), KML:InvertTransform(g:GetTransform()))
            local r = KML:Quat_Rotator(rel.Rotation)
            twinRot = string.format("%.0f/%.0f", r.Yaw, r.Pitch)
        end)
    end
    return string.format("own_open=%s twin_rot=%s doors_sent=%d last_sent=%s doors_done=%d last_done=%s last_taken=%s busyH=%s busyG=%s press=%s own_enter=%s",
        tostring(own and Twin.doorOpen(own, n)), twinRot, st.doorsSent or 0, tostring(st.lastDoorSent), st.doorsDone or 0,
        tostring(st.lastDoorDone):gsub(" ", "_"), tostring(st.lastDoorTaken), tostring(target.busyH), tostring(target.busyG), tostring(TD.doorPress ~= nil), tostring(st.ownEnter))
end
function M.seatInfo()
    local car = localCar()
    local dev = {}
    for n = 1, 4 do dev[#dev + 1] = n .. ":" .. tostring(car and seatDevice(car, n) or "-") end
    local trunk = {}
    pcall(function()
        local c = (CoopSyncFirst or FindFirstOf)("BP_InventoryManager_C").Inventory_Trunk
        for i = 1, c.Slots:GetArrayNum() do
            local s = c.Slots[i]
            for j = 1, s.Items:GetArrayNum() do trunk[#trunk + 1] = s.Items[j].Archetype:GetFName():ToString() end
        end
    end)
    return string.format("host_seat=%d client_seat=%d my_seat=%d driver=%s devices=%s trunk=%s requests=%d seated=%d denied=%d last_denied=%s removed=%d last_device=%s",
        seatOf.host or 0, seatOf.client or 0, mySeat() or 0, tostring(driverRole()), table.concat(dev, ","),
        #trunk > 0 and table.concat(trunk, ",") or "-", st.seatRequests or 0, st.seated or 0, st.denied or 0,
        tostring(st.lastDenied):gsub(" ", "_"), st.devicesRemoved or 0, tostring(st.lastDeviceRequest):gsub(" ", "_"))
end

---------------------------------------------------------------------------------------------------
-- leaving the zone
--   L <time> garage|leg        host -> client: the host's game is travelling home / to the next leg
-- Guest mode: a guest sitting in the host's car leaves with it (home = the game's own successful return;
-- next leg = follow the host's next run descriptor); a guest not in the car is left behind = failed run
-- (owner's rule): the game's own death (random loss of carried items) sends it home.
onHostLeaving = function(dest)
    if garage or st.leaveHandled then return end
    st.leaveHandled = dest
    -- own-car mode: the guest has its own car - the host leaving splits them (no failed run); the copy of
    -- the host's car goes away with the host
    if ownCar then
        st.split = true
        local pawn = localPawn()
        if pawn and inGhost then ghostLeave(pawn, "owner left") end -- no leaving in another's car
        local c = Sync.deref(carPath)
        if c then removeCopy(c) end
        carPath, carPuppeted, target.car = nil, false, nil
        return
    end
    local pawn = localPawn()
    local inCar = pawn and Sync.parentOf(pawn) ~= nil and myAssigned ~= nil
    if not inCar then
        st.leftBehind = true
        pcall(function() FindFirstOf("BP_MainCharacterManager_C"):KillPlayer() end)
    elseif dest == "garage" then
        st.wentHomeWithHost = true
        pcall(function() FindFirstOf("BP_ProgressionManager_C"):TravelToGarage(0, false, false, false, 1, {}) end)
    else
        -- the host publishes the next zone's descriptor once it has arrived there: wait for it to change, then
        -- drive after the host (Run.follow). Game thread; the zone's sync loops stop by themselves on arrival.
        st.followLeg = true
        local descPath = Link.docPath(chan, "inbox", "host-run.txt")
        local function read()
            local s = Link.read(descPath)
            return s and s:match("^[^\r\n]*") or nil
        end
        local old = read()
        local untilT = os.clock() + 300
        loop(1000, function()
            if os.clock() > untilT then st.followResult = "ERR no new descriptor within 5 min" return true end
            local cur = read()
            if not cur or cur == old then return end
            local okR, Run = pcall(dofile, Sync.DIR .. "runsync.lua")
            local okF, r = false, okR and nil or tostring(Run)
            if okR then okF, r = pcall(Run.follow, cur) end
            st.followResult = okF and r or ("ERR " .. tostring(r))
            return true
        end)
    end
end

-- Host: tell the guest before the game starts loading elsewhere. Pre-hooks on the game's travel functions
-- (registered once per Lua state; they call whatever host sync is current).
local function hookLeaving()
    CoopSyncLeaveHooks = CoopSyncLeaveHooks or {}
    CoopSyncLeaveHooks.notify = function(dest)
        if not outFile or M.stopped then return end
        -- any side travelling: its car copies go first (a second player car crashes the travel's save), and
        -- this map's sync ends here - C lines still coming in would spawn the copy again mid-travel (crashed)
        pcall(destroyCopies)
        if role == "host" and not garage then
            append(outFile, string.format("L\t%d\t%s", M.nowMs(), dest))
            st.leaveSent = dest
        end
        M.stopped = true
        st.stoppedLeaving = dest
    end
    if CoopSyncLeaveHooks.done then return end
    CoopSyncLeaveHooks.done = true
    local pm = FindFirstOf("BP_ProgressionManager_C")
    local pmCls = pm and pm:GetClass():GetFullName():gsub("^%S+%s+", "")
    if pmCls then
        pcall(Hook, pmCls .. ":TravelToGarage", function() CoopSyncLeaveHooks.notify("garage") end)
    end
    pcall(Hook, "/Script/PenDriverPro.BaseRouteState:TravelTo", function() CoopSyncLeaveHooks.notify("leg") end)
end

function M.leaveInfo()
    return string.format("leave_sent=%s leave_handled=%s left_behind=%s went_home_with_host=%s follow_leg=%s follow_result=%s",
        tostring(st.leaveSent), tostring(st.leaveHandled), tostring(st.leftBehind == true), tostring(st.wentHomeWithHost == true), tostring(st.followLeg == true),
        tostring(st.followResult):gsub(" ", "_"))
end

-- opts.ownCar (client): own-car mode - the client keeps driving its own car, the host's car is a copy.
function M.start(syncModule, r, channelDir, opts)
    if CoopSyncHitch then CoopSyncHitch.crumbsFor(30) end
    Sync, role, chan = syncModule, r, channelDir
    ownCar = (opts and opts.ownCar) == true
    garage = (opts and opts.garage) == true
    hist, clockOff, puppetOff = {}, nil, nil
    TD.RUN.knock = nil
    TD.carHist, TD.carOff = { car = {}, otherCar = {}, drv = {} }, {}
    TD.driving, TD.drivenBy, target.drv = nil, nil, nil
    TD.catSlot = {}
    -- nothing of an earlier start's cars: in the garage after a run the last C line of the host's car (zone
    -- coordinates) still moved the guest's OWN car there every tick - and its vehicle controller was off (stuck)
    -- (the garage, and every new world: a restart in the same zone keeps its copies' paths, or a second copy would be
    -- spawned. A second visit to a zone kept the first visit's paths (alpha 9): object names come again in the new
    -- world, so they named other objects - the host's "own car" was something 1 km off, the copies' lookups missed)
    local world = Sync.worldName()
    if garage or world ~= M.startWorld then
        target = { player = nil, car = nil }
        carPath, carPuppeted, otherCarPath, lastOtherRecv = nil, false, nil, nil
        puppetPath, posePath, capsulePath, attachedTo, carManagerPath, ownCarPath = nil, nil, nil, nil, nil, nil
    end
    M.startWorld = world
    Ghost = dofile(Sync.DIR .. "carghost.lua")
    Ghost.init(Sync)
    Twin = dofile(Sync.DIR .. "twincar.lua")
    Twin.init(Sync, Ghost)
    -- native cars (nativecar.lua, 2026-10-30): the default; CoopSyncNative = false runs the old twin interactions (muted
    -- handlers, the mod's entry / exit, remote pedals)
    TD.native = CoopSyncNative ~= false and (role == "host" or ownCar) -- (the old guest mode, no own cars: as it was)
    if TD.native then CoopSyncNoMute = true end
    Native = dofile(Sync.DIR .. "nativecar.lua")
    Native.init(Sync)
    TD.tuning = dofile(Sync.DIR .. "tuning.lua")
    -- (the other's car's gas cap: its own tanks, siphoned and filled - gascap.lua)
    TD.gascap = dofile(Sync.DIR .. "gascap.lua")
    pcall(TD.gascap.start, function(car) return Twin.isTwin(car) end, function(...) return Twin.noteSiphon(...) end)
    Native.ownCar = function() return Twin.ownCar() end
    -- a car's door flags from its doors (the own car: open = the door simulates; the other's: posed open by its owner)
    Native.stayParked = function(dn, o, fn)
        if dn ~= "OnDoorChanged" or fn ~= "OnDoorChanged_Event_0" then return false end
        if o:GetClass():GetFName():ToString() ~= "BP_CarPart_Door_Base_C" then return false end
        local car = Native.carOf(o)
        return car ~= nil and Twin.isTwin(car)
    end
    Native.realDoors = function(car)
        local t, twin = {}, Twin.isTwin(car)
        for k, n in pairs(DOOR_OF_ENUM) do
            if Twin.door(car, n) then t[k] = twin and TD.twinDoorAngle(car, n) > 20 or (not twin and Twin.doorOpen(car, n)) end
        end
        return t
    end
    TD.aimed, TD.nativeDoors, TD.sweepAt, TD.slotOf = nil, nil, 0, {}
    if TD.native then pcall(TD.hookSlotLookup) end
    if TD.native or garage then pcall(TD.hookPassengerReach) end
    pcall(Twin.forgetGone)
    -- the own car drives itself again (an earlier start may have puppeted it: vehicle controller tick off)
    pcall(function()
        local own = Twin.ownCar()
        if not own then return end
        for _, c in ipairs(FindAllOf("VehicleControllerComponent") or {}) do
            if Sync.alive(c) and c:GetOuter():IsValid() and c:GetOuter():GetAddress() == own:GetAddress() then c:SetComponentTickEnabled(true) end
        end
        -- and simulates (a puppeted or gate-moved car could stay kinematic: hanging in the air)
        pcall(function() own.RootComponent:SetSimulatePhysics(true) end)
    end)
    useTwin = not (opts and opts.ghost) -- opts.ghost: the other's car as a ghost (the old way)
    layoutOut = { seq = 0, sig = nil, lines = {}, sentMs = -1e9 }
    layoutIn = { seq = -1, n = 0, lines = {}, have = 0, ready = nil, readySeq = -1 }
    ghostSeq = -1
    inGhost, seatOfG, wheelInG = nil, { host = nil, client = nil }, nil
    pcall(hookPawn)
    if ownCar and role == "client" then
        local own = Twin.ownCar()
        if own then ownCarPath = Sync.ref(own) end
        carPath = nil
    end
    pcall(hookLeaving)
    pcall(hookKick)
    pcall(hookDoors)
    pcall(TD.hookHighlight)
    pcall(TD.hookCarLights)
    outFile = chan .. "/" .. (role == "host" and "host.fast" or "client.fast")
    inFile = chan .. "/" .. (role == "host" and "client.fast" or "host.fast")
    outStream, inStream = role == "host" and "host.fast" or "client.fast", role == "host" and "client.fast" or "host.fast"
    local f = io.open(inFile, "rb")
    if f then readOff = f:seek("end") f:close() end -- ignore samples from before this session
    Link.drain(inStream)
    -- the session belongs to this map: stop once the game travels elsewhere (home, death), so a player
    -- in its own garage does not show up walking around in the other player's zone
    local startAddr = Sync.worldAddr()
    M.stopped = false
    -- a generation per start: the loops of an earlier start (the garage lobby) end without stopping this one
    M.gen = (M.gen or 0) + 1
    local gen = M.gen
    -- (every loop, every call: the frame loops below ran on in the new world with the old zone's freed objects while
    -- only the send loop looked - Sync.worldAddr)
    local function gone()
        if M.stopped or gen ~= M.gen then return true end
        if Sync.worldAddr() ~= startAddr then M.stopped = true st.stoppedWorldChanged = true return true end
        return false
    end
    loop(SEND_MS, function()
        if gone() then return true end
        local ok, e = timed("send", sendTick)
        if not ok then err("send: " .. tostring(e)) end
    end, "p.send")
    loop(APPLY_MS, function()
        if gone() then return true end
        local ok, e = timed("apply", applyTick)
        if not ok then err("apply: " .. tostring(e)) end
        local okD, eD = pcall(TD.doorTick)
        if not okD then err("doors: " .. tostring(eD)) end
        local okN, eN = pcall(TD.nativeTick)
        if not okN then err("native: " .. tostring(eN)) end
    end, "p.apply")
    loop(1, function()
        if gone() then return true end
        local okP, eP = pcall(puppetFrame)
        if not okP then err("puppet frame: " .. tostring(eP)) end
        local okT, eT = pcall(TD.twinFrame)
        if not okT then err("twin frame: " .. tostring(eT)) end
        local okR, eR = pcall(TD.RUN.check)
        if not okR then err("run over: " .. tostring(eR)) end
        local okV, eV = pcall(TD.RUN.drive)
        if not okV then err("run over (driver): " .. tostring(eV)) end
        local okL, eL = pcall(TD.LID.check)
        if not okL then err("lid: " .. tostring(eL)) end
        local ok, e = timed("wheel", wheelFrame)
        if not ok then err("wheel: " .. tostring(e)) end
    end, "p.frame")
    return role .. " player sync started"
end

-- Session left (single player again): the loops end, the other player's puppet and car ghosts go (they stood frozen before).
function M.stop()
    pcall(destroyCopies)
    M.stopped = true
    local p = Sync and Sync.deref(puppetPath)
    if p then pcall(function() p:K2_DestroyActor() end) end
    puppetPath, posePath, capsulePath, attachedTo, animState, poseArms = nil, nil, nil, nil, nil, nil
end

-- What the puppet looks like right now (used by the automated test).
-- (tests / probes: the puppet and its sitting mesh)
function M.puppetParts() return Sync.deref(puppetPath), Sync.deref(posePath) end
function M.puppetInfo()
    local p = Sync.deref(puppetPath)
    if not p then return "puppet=none" end
    local sk = p.SkeletalMeshComponent
    -- (reading sk.AnimationData.AnimToPlay crashed UE4SS with an AV: keep our own record instead)
    local anim = animName or "-"
    local par = Sync.parentOf(p)
    local rel = p.RootComponent.RelativeLocation
    local foot = 0
    if #footSamples > 1 then
        for _, f in ipairs(footSamples) do
            local d = math.sqrt((f.X - footSamples[1].X) ^ 2 + (f.Y - footSamples[1].Y) ^ 2 + (f.Z - footSamples[1].Z) ^ 2)
            if d > foot then foot = d end
        end
    end
    -- sitting pose geometry in the puppet's own frame (mesh forward = +Y of the mesh)
    local knee, footDrop, handFwd, handOut, handKnee = 0, 0, 0, 0, 0
    local pose = Sync.deref(posePath)
    if pose then
        local pv = pose:GetBoneLocationByName(FName("pelvis"), 1)
        local kv = pose:GetBoneLocationByName(FName("calf_l"), 1)
        local fv = pose:GetBoneLocationByName(FName("foot_l"), 1)
        knee = kv.Y - pv.Y         -- how far the knee is in front of the pelvis
        footDrop = kv.Z - fv.Z     -- how far the foot hangs below the knee
        -- arms: the left hand in front of the shoulder, its distance from the body's middle (the A-pose: ~70, out
        -- through the door), its distance from the knee (hands on the lap)
        local sv, hv = pose:GetBoneLocationByName(FName("upperarm_l"), 1), pose:GetBoneLocationByName(FName("hand_l"), 1)
        handFwd, handOut = hv.Y - sv.Y, math.abs(hv.X - pv.X)
        handKnee = math.sqrt((hv.X - kv.X) ^ 2 + (hv.Y - kv.Y) ^ 2 + (hv.Z - kv.Z) ^ 2)
    end
    local hidden = false
    pcall(function() hidden = p.bHidden end)
    return string.format("state=%s anim=%s skVisible=%s poseVisible=%s attached=%s rel=%.1f,%.1f,%.1f foot_motion=%.1f sit_knee_forward=%.1f sit_foot_below_knee=%.1f arms=%s hand_fwd=%.1f hand_out=%.1f hand_knee=%.1f seatTarget=%d hidden=%s gone=%s gone_count=%d",
        tostring(animState), anim, tostring(sk:IsVisible()), tostring(pose and pose:IsVisible()), par and Sync.clsName(par) or "no",
        rel.X, rel.Y, rel.Z, foot, knee, footDrop, tostring(poseArms), handFwd, handOut, handKnee, target.player and target.player.seat or -1,
        tostring(hidden), tostring(st.playerGone == true), st.playerGoneCount or 0)
end

-- debug menu: put the local player next to the other player (stuck under the map, lost in the fog)
function M.teleportToOther()
    local function L(k, ...) return CoopSyncLoc and CoopSyncLoc.L(k, ...) or k end -- (loc.lua: the game's language)
    local pawn = localPawn()
    if not pawn then return L("tp.no_character") end
    if Sync.parentOf(pawn) then return L("tp.get_out_first") end
    local p = Sync.deref(puppetPath)
    if not p then return L("tp.no_other") end
    local loc = p:K2_GetActorLocation()
    local hit = {}
    pawn:K2_SetActorLocation({ X = loc.X + 150, Y = loc.Y, Z = loc.Z + 60 }, false, hit, true)
    return L("tp.near", loc.X, loc.Y, loc.Z)
end

-- tests: the driver's seat measured again at the next entry (seat-measure-test)
function M.testResetSeat()
    seats, sockDelta, TD.seatCand, st.seatMeasured, st.seatOutside = nil, nil, nil, nil, 0
    return "seat measure reset"
end
function M.selfInfo()
    local pawn = localPawn()
    if not pawn then return "pawn=none" end
    local par = Sync.parentOf(pawn)
    local rel = pawn.RootComponent.RelativeLocation
    return string.format("in_car=%s seat=%d rel=%.1f,%.1f,%.1f seat_moves=%d driver_seat_measured=%s",
        tostring(par ~= nil), mySeat() or 0, rel.X, rel.Y, rel.Z, st.seatMoves or 0, tostring(st.seatMeasured))
end

function M.trace(path) traceFile, tracing = path, path ~= nil end

-- the puppet's animation state (idle / walk / run / sit), for the session status
function M.puppetAnim() return animState or "-" end
-- where the other player and its car are (the last samples): statesync's host serializes the loot near them
function M.otherPoints()
    local t = {}
    if target.player and target.player.loc then t[#t + 1] = target.player.loc end
    if target.otherCar and target.otherCar.loc then t[#t + 1] = target.otherCar.loc end
    if target.car and target.car.loc then t[#t + 1] = target.car.loc end
    return t
end
CoopSyncOtherPoints = M.otherPoints
function M.report()
    local p = Sync.deref(puppetPath)
    local d = {}
    for i, v in ipairs(st.delays) do d[i] = v end
    table.sort(d)
    local med = #d > 0 and d[math.floor(#d / 2) + 1] or -1
    local p95 = #d > 0 and d[math.floor(#d * 0.95) + 1] or -1
    local s = string.format("sent=%d recv=%d puppetSpawned=%d puppet=%s transport_ms median=%d p95=%d",
        st.sent, st.recv, st.puppetSpawned, p and "yes" or "no", med, p95 or -1)
    if #st.errors > 0 then s = s .. " ERRORS: " .. table.concat(st.errors, " || ") end
    return s
end

---------------------------------------------------------------------------------------------------
-- test bots: move along a straight line in steps (owner side). The car keeps its height and yaw;
-- the character is first taken out of the car (test only, no exit animation or game logic).

local bot
function M.botMove(what, steps, stepDist, intervalMs)
    local a = what == "car" and localCar() or localPawn()
    if not a then return "no " .. what end
    if what == "player" and Sync.parentOf(a) then pcall(function() a:K2_DetachFromActor(1, 1, 1) end) end -- KeepWorld
    local start = a:K2_GetActorLocation()
    local yaw = math.rad(a:K2_GetActorRotation().Yaw)
    bot = { path = Sync.ref(a), i = 0, steps = steps, dx = math.cos(yaw) * stepDist, dy = math.sin(yaw) * stepDist,
            start = start, every = math.max(1, math.floor(intervalMs / 33)), n = 0 }
    if not M.botLoop then
        M.botLoop = true
        loop(33, function()
            if not bot or bot.i >= bot.steps then return end
            bot.n = bot.n + 1
            if bot.n % bot.every ~= 0 then return end
            local x = Sync.deref(bot.path)
            if not x then bot = nil return end
            bot.i = bot.i + 1
            local l = { X = bot.start.X + bot.dx * bot.i, Y = bot.start.Y + bot.dy * bot.i, Z = bot.start.Z }
            pcall(function() x:K2_SetActorLocation(l, false, {}, true) end)
        end)
    end
    return string.format("%s moving %d x %d units from %.0f,%.0f,%.0f", what, steps, stepDist, start.X, start.Y, start.Z)
end

function M.botDone() return bot == nil or bot.i >= bot.steps end

-- Realistic test bots: drive with the car's own physics (vehicle controller throttle), leave the car with
-- the character's "Exit Car", walk with AddMovementInput (character movement like a player).
local act -- { kind, untilMs, path }
local function vehicleController(car)
    for _, c in ipairs(FindAllOf("VehicleControllerComponent") or {}) do
        if Sync.alive(c) and c:GetOuter():IsValid() and c:GetOuter():GetFullName() == car:GetFullName() then return c end
    end
end
local function ensureActLoop()
    if M.actLoop then return end
    M.actLoop = true
    -- every frame, like a player's input: AddMovementInput lasts one frame and the car BP rewrites its
    -- inputs every frame, so a 16 ms loop at ~120 fps left every other frame without input (walk ~10x slower)
    loop(1, function()
        if not act or M.nowMs() > act.untilMs then
            if act and act.kind == "drive" then
                -- the car BP rewrites inputs every frame, so braking must be held, not set once
                act = { kind = "brake", untilMs = M.nowMs() + 4000, path = act.path }
                return
            end
            if act and act.kind == "input" then
                local car = Sync.deref(act.path)
                if car then writeInput(car, ZERO) end -- release the pedals
            elseif act and act.kind == "enter" then
                local pawn = Sync.deref(act.path)
                if pawn then pcall(function() pawn:CommandEnterCar(true, nil, false) end) end
            end
            act = nil
            return
        end
        local x = Sync.deref(act.path)
        if not x then act = nil return end
        if act.kind == "input" then
            -- (wheelFrame holds a back-seat player's pedals off every frame; this loop's place in the frame against
            -- wheelFrame's is not fixed - the throttle won one run in two - so the bot keeps the same rule itself)
            writeInput(x, (TD.ownSeat and TD.ownSeat.seated) and ZERO or act.v)
            return
        end
        if act.kind == "drive" then
            x.ThrottleInput = 1.0 x.BrakeInput = 0 x.HandbrakeInput = 0
        elseif act.kind == "brake" then
            x.ThrottleInput = 0 x.BrakeInput = 1.0 x.HandbrakeInput = 1.0
        elseif act.kind == "walk" then
            local r = x:K2_GetActorRotation()
            local yaw = math.rad(r.Yaw)
            x:AddMovementInput({ X = math.cos(yaw), Y = math.sin(yaw), Z = 0 }, act.scale or 1.0, false)
        end
    end)
end
function M.botDrive(seconds)
    local car = M.ownCarActor() -- (own-car mode, the guest: its own car, not this side's twin of the host's)
    local vc = car and vehicleController(car)
    if not vc then return "no vehicle controller" end
    pcall(function() vc:SetParkingBrakeActive(false) end)
    pcall(function() vc:Wake() end)
    act = { kind = "drive", untilMs = M.nowMs() + seconds * 1000, path = Sync.ref(vc) }
    ensureActLoop()
    return "driving " .. seconds .. " s from " .. string.format("%.0f,%.0f", car:K2_GetActorLocation().X, car:K2_GetActorLocation().Y)
end
function M.botExitCar()
    local pawn = localPawn()
    if not pawn then return "no pawn" end
    if not Sync.parentOf(pawn) then return "not in car" end
    local ok, e = pcall(function() pawn["Exit Car"](pawn, false, true) end)
    return "exit car: " .. tostring(ok) .. " " .. tostring(e or "")
end
function M.botEnterCar()
    local pawn = localPawn()
    if not pawn then return "no pawn" end
    if Sync.parentOf(pawn) then return "already in car" end
    -- (native cars: CommandEnterCar takes the manager's car - the own one, not the other's the player last aimed at)
    if TD.native and Native then pcall(Native.use, Twin.ownCar()) end
    local ok, e = pcall(function() pawn:CommandEnterCar(true, nil, false) end) -- Teleport, no door, no dip to black
    return "enter car: " .. tostring(ok) .. " " .. tostring(e or "")
end

-- Driver input as the player's keys produce it: the car BP's raw input fields, every frame, released
-- at the end. On the client this is what the wheel stream picks up and sends to the host.
function M.botInput(seconds, throttle, steer, brake)
    local car = M.ownCarActor() -- (own-car mode, the guest: its own car)
    if not car then return "no car" end
    act = { kind = "input", untilMs = M.nowMs() + seconds * 1000, path = Sync.ref(car), v = { throttle or 0, brake or 0, steer or 0, 0 } }
    ensureActLoop()
    return string.format("input %.1f s throttle=%.2f steer=%.2f brake=%.2f, driver=%s", seconds, throttle or 0, steer or 0, brake or 0, tostring(driverRole()))
end

-- Walk up to a door (FL, FR, RL, RR: front/rear, left/right; stand ~0.5 m outside it) and get in with
-- the game's own CommandEnterCar 0.4 s later (the send tick notes where the character stood).
local DOORS = { FL = 1, FR = 2, RL = 3, RR = 4 }
function M.botEnterAt(door)
    local pawn, car = localPawn(), localCar()
    if not (pawn and car) then return "no pawn/car" end
    if Sync.parentOf(pawn) then return "already in the car" end
    local p = SEAT_DOOR[DOORS[door] or 0]
    if not p then return "unknown door " .. tostring(door) end
    local at = toWorld(car, { X = p.X, Y = p.Y, Z = 0 })
    at.Z = pawn:K2_GetActorLocation().Z
    pcall(function() pawn:K2_SetActorLocation(at, false, {}, true) end)
    act = { kind = "enter", untilMs = M.nowMs() + 400, path = Sync.ref(pawn) }
    ensureActLoop()
    return "at door " .. door .. ", getting in"
end

-- scale = stick deflection 0..1 (character movement scales max speed by it): ~0.4 walks, 1.0 runs
function M.botWalk(seconds, scale)
    local pawn = localPawn()
    if not pawn then return "no pawn" end
    act = { kind = "walk", untilMs = M.nowMs() + seconds * 1000, path = Sync.ref(pawn), scale = scale or 1.0 }
    ensureActLoop()
    return "walking " .. seconds .. " s at input " .. (scale or 1.0) .. ", in car: " .. tostring(Sync.parentOf(pawn) ~= nil)
end

return M
