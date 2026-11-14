-- The host's zone through the game's own save (owner, 2026-10-30: "the zone reproducible the right way"; NOTES
-- "Prototype: the host's zone through the game's save" - the guest got the host's exact zone, 1945 of 1954 objects,
-- where generating it from the seed left buildings as other variants, interiors outside).
--   Host, its zone settled: the game's SaveGame into a scratch slot (past the menu's slots), back to its own slot,
--     the file to the guest as a document ("host-zonesave-<seq>"), the scratch slot deleted.
--   Guest, arrived (the game generated the zone from the seed meanwhile): a copy of its departure save (the slot the
--     game wrote on leaving the garage: its car, inventory, garage, managers - no zone) with the host's "Map" (the zone,
--     every object as the host's game has it; CoopNative_SaveSplice, its scene's player / car transforms moved beside
--     the host's car) in a scratch slot, and the game loads it (UserLoadGame) - the host's zone, the game's way.
-- Steps over ticks: M.tick() from session.lua, its state in M.s.
local M = {}
CoopSyncZoneSave = M -- (tests and the panel: the live module)
M.s = { state = "idle" }
M.stats = { saved = 0, sent = 0, loaded = 0, last = "-" }

local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local function sm() return (CoopSyncFirst or FindFirstOf)("BP_SaveGameManager_C") end
local function now() return os.clock() end

-- the game's SaveGames folder (a -userdir test instance has its own)
function M.saveDir()
    local ok, p = pcall(function() return KSL:ConvertToAbsolutePath(KSL:GetProjectSavedDirectory()):ToString() end)
    if not ok or not p then return nil end
    p = p:gsub("\\", "/")
    if not p:find("/$") then p = p .. "/" end
    return p .. "SaveGames/"
end
-- (slot 0 is the game's own scratch slot - "odsave_scratch", not in the menu's slots 1-9: the mod's)
local function slotName(slot) return slot == 0 and "odsave_scratch" or ("odsave" .. tostring(slot)) end
function M.slotPath(slot) local d = M.saveDir() return d and (d .. slotName(slot) .. ".sav") or nil end
local function fileSize(p)
    local f = p and io.open(p, "rb")
    if not f then return nil end
    local n = f:seek("end")
    f:close()
    return n
end
local function copyFile(a, b)
    local f = io.open(a, "rb")
    if not f then return false end
    local d = f:read("a")
    f:close()
    local g = io.open(b, "wb")
    if not g then return false end
    g:write(d)
    g:close()
    return true
end

-- The slot the mod saves / loads through: the game's own scratch slot 0 (owner, 2026-11-11: "what if the guest has no
-- free slot?" - the game names slot 0 "odsave_scratch", the menu lists 1-9, SaveGame / LoadGame take 0-9 only); a
-- free one of 9..2 only if slot 0 is the current one. The player's saves are never written over.
-- (fresh: not one used as such this session - its memory copy would be served instead of the file; slot 0 is
-- deleted after each use, DeleteGame, which drops that copy)
M.SCRATCH = 0
function M.scratchSlot(fresh)
    local m = sm()
    if m.CurrentSaveSlot ~= M.SCRATCH then return M.SCRATCH end
    local max = 9
    pcall(function() max = m:GetMaxSaveSlots() end)
    for slot = max, 2, -1 do
        if slot ~= m.CurrentSaveSlot and not fileSize(M.slotPath(slot)) and not (fresh and M.usedScratch and M.usedScratch[slot]) then return slot end
    end
    return nil
end
-------------------------------------------------------------------------------------------------------------------
-- host
-- docPath: link.lua's Link.docPath of the document - "doc:<name>" (the in-game network) or a channel file (tests)
function M.hostSave(docPath)
    local m = sm()
    if not (m and m:IsValid()) then return "no save manager" end
    local own, scratch = m.CurrentSaveSlot, M.scratchSlot()
    if not scratch then return "no free save slot" end
    local path = M.slotPath(scratch)
    if not path then return "no save folder" end
    os.remove(path)
    local t0 = now()
    local ok, e = pcall(function() m:SaveGame(scratch, "", 1) end)
    if not ok then return "SaveGame failed: " .. tostring(e) end
    M.s = { state = "host saving", own = own, scratch = scratch, path = path, doc = docPath, t0 = t0, size = -1, stable = 0, callMs = (now() - t0) * 1000 }
    return "saving into slot " .. scratch
end
local function hostTick()
    local s = M.s
    local m = sm()
    local busy = false
    pcall(function() busy = m:IsAsyncSaveInProgress() end)
    local n = fileSize(s.path)
    if busy or not n or n ~= s.size then s.size, s.stable = n or -1, 0 return end
    s.stable = s.stable + 1
    if s.stable < 2 then return end
    -- written: back to the host's own slot (SaveGame made the scratch one current: the rinse would write there)
    pcall(function() m:SetCurrentSlot(s.own) end)
    local sent = -1
    if s.doc:sub(1, 4) == "doc:" then sent = CoopNative_DocPutFile and CoopNative_DocPutFile(s.doc:sub(5), s.path) or -1
    elseif copyFile(s.path, s.doc .. ".tmp") then os.remove(s.doc) os.rename(s.doc .. ".tmp", s.doc) sent = fileSize(s.doc) or -1 end
    pcall(function() m:DeleteGame(s.scratch, true) end)
    os.remove(s.path)
    if CoopNative_DeleteFiles then CoopNative_DeleteFiles(M.saveDir(), slotName(s.scratch) .. "-backup-") end
    M.stats.saved, M.stats.sent = M.stats.saved + 1, sent > 0 and M.stats.sent + 1 or M.stats.sent
    M.stats.last = string.format("host: %s %d bytes in %.1f s (call %.0f ms), slot %d back to %d", s.doc, sent, now() - s.t0, s.callMs, s.scratch, s.own)
    M.s = { state = sent > 0 and "host sent" or "host failed", doc = s.doc }
end

-------------------------------------------------------------------------------------------------------------------
-- guest
-- The host's zone save (document docName) into a copy of the guest's own departure save, loaded. Returns a note.
-- (2026-11-11: the copy goes into a scratch slot this session has not loaded or saved - loaded from the guest's own
-- (current) slot, the save manager served its memory copy of that slot, the departure without the zone: the game
-- logged "FAILED TO LOAD V4 (Map) SCENE DATA" and generated the zone from its own seed - the host's zone never came,
-- in the owner's two games; the tests roll one seed on both, so the generated zone matched anyway. The slot's
-- metadata cache is dropped first; once the zone is in, M.afterLoad: the own slot current again (the rinse home
-- writes there), the scratch slot deleted. The own save is not touched any more.)
M.usedScratch = M.usedScratch or {}
-- (the own car: the car manager's)
local function ownCar()
    local c
    pcall(function() c = FindFirstOf("BP_CarManager_C").NewCarActor end)
    return c and c:IsValid() and c or nil
end
-- (the same host zone save may be loaded again - a late join to the zone it was in: the game built no car then; the
-- car is built by M.afterLoad now. loadedDocs: only counted)
M.loadedDocs = M.loadedDocs or {}
function M.guestLoad(docPath, side)
    local m = sm()
    if not (m and m:IsValid()) then return nil, "no save manager" end
    -- (a load's car still awaited, or slot 0 current: an earlier load not done - never a second one over it)
    if M.s.waiting or M.s.state == "direct saving" then return nil, "busy: " .. tostring(M.s.state) end
    local slot = m.CurrentSaveSlot
    if slot == M.SCRATCH then return nil, "busy: slot 0 is current" end
    local own = M.slotPath(slot)
    local dir = M.saveDir()
    if not (own and fileSize(own)) then return nil, "no own save at " .. tostring(own) end
    local scratch = M.scratchSlot(true)
    if not scratch then return nil, "no free save slot" end
    local hostFile = dir .. "coop-host-zone.sav"
    local v
    if docPath:sub(1, 4) == "doc:" then v = CoopNative_DocGetFile and CoopNative_DocGetFile(docPath:sub(5), hostFile)
    elseif fileSize(docPath) then v = copyFile(docPath, hostFile) end
    if not v then return nil, "no host zone save yet" end
    local out = M.slotPath(scratch)
    local t0 = now()
    local r = CoopNative_SaveSplice(own, hostFile, out, 0, side or 500)
    if not tostring(r):find("^ok") then os.remove(out) return nil, "splice: " .. tostring(r) end
    -- (the host's META too - its Level the host's zone: the own slot's save may be a departure written in the garage,
    -- by the one load - its Level the garage, and the load went home: revisit-test 2026-11-11)
    local mr, me = M.swapMeta(out, hostFile)
    if not mr then os.remove(out) return nil, "META: " .. tostring(me) end
    local spliceMs = (now() - t0) * 1000
    M.usedScratch[scratch] = true
    M.loadedDocs[docPath] = true
    -- (what the load will do with the scene's player / car transforms: the late join once had no car, the player at 0,0)
    local slt, gls = "?", "?"
    pcall(function() slt = tostring(m:ShouldLoadTransforms()) end)
    pcall(function() local t = {} FindFirstOf("BP_ProgressionManager_C")["Get Garage Load State"](FindFirstOf("BP_ProgressionManager_C"), t) gls = tostring(t.GarageLoadState) end)
    M.stats.before = "transforms=" .. slt .. " garage_load=" .. gls
    -- (not loading them - the garage's load state after a trip home: the player stood at 0,0 and the game built no car,
    -- startflow's late join; the state reset so the scene places both)
    if slt == "false" then
        pcall(function() local pm = FindFirstOf("BP_ProgressionManager_C") pm["Reset Garage Load State"](pm) end)
        pcall(function() slt = tostring(m:ShouldLoadTransforms()) end)
        M.stats.before = M.stats.before .. " -> reset, transforms=" .. slt
    end
    if CoopSyncHitch then pcall(CoopSyncHitch.note, "zone save load: " .. M.stats.before) end
    -- (the spliced save kept for a look - save-dump.ps1; the scratch slot is deleted after the load)
    copyFile(out, dir .. "coop-last-splice.sav")
    pcall(function() m:InvalidateMetadataCacheSlot(scratch) end)
    local seated = M.seatedNow() or M.droveOutSeated == true
    M.droveOutSeated = nil
    M.selfLoad = true -- (session.lua's load hook: not a player's load, the lobby stays)
    local ok, e = pcall(function() m:UserLoadGame(scratch, 1, 0) end)
    M.selfLoad = false
    if not ok then os.remove(out) return nil, "UserLoadGame: " .. tostring(e) end
    M.stats.loaded = M.stats.loaded + 1
    M.stats.last = string.format("guest: %s via slot %d for %d (%s, %.0f ms), loading", docPath, scratch, slot, r, spliceMs)
    M.s = { state = "guest loading", slot = slot, scratch = scratch, t0 = now(), wasSeated = seated }
    return M.stats.last
end
-- One save's META chunk put into another (tools/save-meta-swap.ps1 in Lua): META is the slot's summary - its Level,
-- MapLocation, ShapeLeg - and the META's Level decides what LoadGame loads. Chunks copied byte for byte, the slot table
-- (16 x 24 bytes from 16: tag, offset, stored, size, flags) rebuilt, chunks from byte 400.
function M.swapMeta(into, from)
    local function rd(p) local f = io.open(p, "rb") if not f then return nil end local s = f:read("a") f:close() return s end
    local a, h = rd(into), rd(from)
    if not (a and h) then return nil, "cannot read" end
    local function slots(b)
        local r = {}
        for i = 0, 15 do
            local o = 16 + i * 24
            r[i] = { tag = b:sub(o + 1, o + 4), off = string.unpack("<I4", b, o + 5), len = string.unpack("<I4", b, o + 9), entry = b:sub(o + 1, o + 24) }
        end
        return r
    end
    local as, hs = slots(a), slots(h)
    local hm
    for i = 0, 15 do if hs[i].tag == "META" then hm = hs[i] end end
    if not hm then return nil, "no META in the host's save" end
    local body, offs = {}, {}
    local pos = 400
    for i = 0, 15 do
        local s = as[i]
        if s.off < #a and s.tag:match("^[A-Z0-9_][A-Z0-9_][A-Z0-9_][A-Z0-9_]$") then
            local c = s.tag == "META" and h:sub(hm.off + 1, hm.off + hm.len) or (s.len > 0 and a:sub(s.off + 1, s.off + s.len) or "")
            body[#body + 1] = c
            offs[i] = { off = pos, entry = s.tag == "META" and hm.entry or s.entry }
            pos = pos + #c
        end
    end
    local head = { a:sub(1, 16) }
    for i = 0, 15 do
        local e = offs[i] and offs[i].entry or string.rep("\0", 24)
        head[#head + 1] = e:sub(1, 4) .. string.pack("<I4", offs[i] and offs[i].off or pos) .. e:sub(9, 24)
    end
    local f = io.open(into, "wb")
    if not f then return nil, "cannot write" end
    f:write(table.concat(head), table.concat(body))
    f:close()
    return string.format("META %d bytes swapped, %d bytes", hm.len, pos)
end

-- The one load straight from the garage into the host's zone (owner, 2026-11-11: "the host's exact zone and one
-- load"; NOTES "One load from the garage works": 17 s, the host's objects in place, the leg the host's). Instead of
-- the travel (the own zone generated, then the host's loaded over it): the route's leg made the host's
-- (runsync.prepareDirect), SaveGame into slot 0 (a departure to the host's zone), the host's Map spliced into it
-- and the host's META put in (its Level), slot 0's memory copy dropped (DeleteGame) and the file written again,
-- LoadGame(0, LOAD_CAR_TRANSFORM | LOAD_PLAYER_TRANSFORM, STORY, 0) - not into the current world (the garage): the
-- level the META names. No car comes with it: M.afterLoad builds it (BP_CarSpawnpoint) and seats the player.
-- Steps over ticks (M.tick): "direct saving" -> load. A failure: state "direct failed" (session.lua travels then).
function M.directStart(docPath)
    local m = sm()
    if not (m and m:IsValid()) then return nil, "no save manager" end
    if M.s.state == "direct saving" or M.s.state == "guest loading" then return nil, "busy: " .. M.s.state end
    local dir = M.saveDir()
    if not dir then return nil, "no save folder" end
    local hostFile = dir .. "coop-host-zone.sav"
    local v
    if docPath:sub(1, 4) == "doc:" then v = CoopNative_DocGetFile and CoopNative_DocGetFile(docPath:sub(5), hostFile)
    elseif fileSize(docPath) then v = copyFile(docPath, hostFile) end
    if not v then return nil, "no host zone save yet" end
    local own = m.CurrentSaveSlot
    if own == M.SCRATCH then return nil, "the own slot is slot 0" end
    -- (the departure into the own slot, as the game's own travel writes it there: a slot just saved is served from
    -- memory on a load - saved into slot 0 and loaded from there, gates-test 2026-11-11 got the garage back, LOAD V4:
    -- Garage, though the file had the host's Map and META)
    local path = M.slotPath(own)
    local seated = M.seatedNow() or M.droveOutSeated == true
    M.droveOutSeated = nil
    local t0 = now()
    local before = fileSize(path)
    local ok, e = pcall(function() m:SaveGame(own, "", 1) end)
    if not ok then return nil, "SaveGame failed: " .. tostring(e) end
    M.s = { state = "direct saving", own = own, path = path, hostFile = hostFile, doc = docPath, t0 = t0, size = -1, stable = 0, wasSeated = seated, mtime0 = before }
    return "one load: saving the departure into slot " .. own
end
local function directTick()
    local s = M.s
    local m = sm()
    local busy = false
    pcall(function() busy = m:IsAsyncSaveInProgress() end)
    local n = fileSize(s.path)
    -- (the own slot's old file is there from the start: the save is async, its flag may not be up at once)
    if busy or not n or n ~= s.size or now() - s.t0 < 1 then
        s.size, s.stable = n or -1, 0
        if now() - s.t0 > 20 then M.s = { state = "direct failed", why = "the save never came" } end
        return
    end
    s.stable = s.stable + 1
    if s.stable < 2 then return end
    -- (the save is async: a file the same size as before may be the old one for a moment - 2 stable ticks, 1 s)
    local out = M.slotPath(M.SCRATCH)
    local function fail(why)
        pcall(function() m:SetCurrentSlot(s.own) end)
        pcall(function() m:DeleteGame(M.SCRATCH, true) end)
        os.remove(out)
        M.stats.last = "guest: one load failed: " .. why
        M.s = { state = "direct failed", why = why }
    end
    local dir = M.saveDir()
    local dep = dir .. "coop-own-departure.sav"
    if not copyFile(s.path, dep) then return fail("cannot copy the departure") end
    -- (slot 0 cleared - a file of an earlier load, its memory copy)
    pcall(function() m:DeleteGame(M.SCRATCH, true) end)
    os.remove(out)
    local t0 = now()
    local r = CoopNative_SaveSplice(dep, s.hostFile, out, 0, 500)
    if not tostring(r):find("^ok") then return fail("splice: " .. tostring(r)) end
    local mr, me = M.swapMeta(out, s.hostFile)
    if not mr then return fail("META: " .. tostring(me)) end
    local spliceMs = (now() - t0) * 1000
    copyFile(out, dir .. "coop-last-splice.sav")
    pcall(function() m:InvalidateMetadataCacheSlot(M.SCRATCH) end)
    if CoopSyncHitch then pcall(CoopSyncHitch.note, string.format("zone save: one load from the garage (saved in %.1f s, %s, %s)", now() - s.t0, r, mr)) end
    M.selfLoad = true
    local ok, e = pcall(function() m:LoadGame(M.SCRATCH, 6, 1, 0) end)
    M.selfLoad = false
    if not ok then return fail("LoadGame: " .. tostring(e)) end
    M.usedScratch[M.SCRATCH] = true
    M.loadedDocs[s.doc] = true
    M.stats.loaded = M.stats.loaded + 1
    M.stats.direct = (M.stats.direct or 0) + 1
    M.stats.last = string.format("guest: one load of %s via slot 0 for %d (%s, %.0f ms)", s.doc, s.own, r, spliceMs)
    M.s = { state = "guest loading", slot = s.own, scratch = M.SCRATCH, t0 = now(), wasSeated = s.wasSeated, direct = true }
end

-- The own car the game did not build after the load (2026-11-11, gates-test -ZoneSave: no BP_PlayerCarNew_C, the
-- player at 0,0, in_car_on_load true). In a zone the car comes from a BP_CarSpawnpoint_C the game spawns at the
-- entrance (the host had one, made at runtime - no save holds it); after the guest's load into the current world none
-- came. Spawned by the mod, its BeginPlay builds the own car from the car manager (all its parts) and makes it
-- NewCarActor; CommandEnterCar(true) seats the player (the driver's door stays - checked). at: {X, Y, Z, Yaw}.
local SPAWNPOINT = "/Game/Characters/PlayerCar/BP_CarSpawnpoint.BP_CarSpawnpoint_C"
local NO_CAR_S = 2.5
function M.spawnOwnCar(at)
    local cls = StaticFindObject(SPAWNPOINT)
    -- (straight from the garage no spawnpoint was ever in memory: loaded)
    if not (cls and cls:IsValid()) then pcall(function() LoadAsset(SPAWNPOINT:gsub("%.[^.]+$", "")) end) cls = StaticFindObject(SPAWNPOINT) end
    if not (cls and cls:IsValid()) then return "no spawnpoint class" end
    local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local y = math.rad(at.Yaw or 0)
    local xf = { Translation = { X = at.X, Y = at.Y, Z = at.Z + 100 }, Rotation = { X = 0, Y = 0, Z = math.sin(y / 2), W = math.cos(y / 2) }, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local ok, e = pcall(function()
        local a = GS:BeginDeferredActorSpawnFromClass(FindFirstOf("PlayerController"), cls, xf, 1, nil)
        GS:FinishSpawningActor(a, xf)
    end)
    if not ok then return "spawn failed: " .. tostring(e) end
    M.stats.carSpawned = (M.stats.carSpawned or 0) + 1
    return string.format("own car spawned at %.0f,%.0f", at.X, at.Y)
end
-- the player at the own car's wheel now. (Also the drive-out's: session.lua sets M.droveOutSeated when the guest drove
-- out of its garage seated - the arrival's gate move, 2 km, then the load came with the player off the seat, startflow
-- 2026-11-14: the guest joined standing beside its car)
function M.seatedNow()
    local seated = false
    pcall(function()
        local par = FindFirstOf("PlayerController").Pawn:GetAttachParentActor()
        seated = par ~= nil and par:IsValid() and par:GetFullName() == ownCar():GetFullName()
    end)
    return seated
end
-- the player into the own car when it stands beside it (after a load)
function M.seatNow()
    local r = "no own car"
    pcall(function()
        local p = FindFirstOf("PlayerController").Pawn
        local par = p:GetAttachParentActor()
        if not ownCar() then return end
        if par and par:IsValid() then r = "seated already" return end
        p:CommandEnterCar(true, nil, false)
        M.stats.seated = (M.stats.seated or 0) + 1
        r = "seated"
    end)
    return r
end
-- the guest's own slot current again, the scratch slot gone (once a load's zone is in)
function M.slotsBack()
    local s = M.s
    if not s.scratch then return "no scratch slot" end
    local m = sm()
    if m and m:IsValid() then
        pcall(function() m:SetCurrentSlot(s.slot) end)
        pcall(function() m:DeleteGame(s.scratch, true) end)
    end
    os.remove(M.slotPath(s.scratch))
    if CoopNative_DeleteFiles then CoopNative_DeleteFiles(M.saveDir(), slotName(s.scratch) .. "-backup-") end
    M.stats.scratchDone = (M.stats.scratchDone or 0) + 1
    return "slot " .. tostring(s.slot) .. " current again"
end
-- (tests that load through their own commands - sync-test -GuestJoin: no session, no CoopSyncAfter there) the load's
-- end in one call: the own car built at at when the game built none, the slots back; then seatNow
function M.finishNow(at)
    local r = ownCar() and "the game's car" or (at and M.spawnOwnCar(at) or "no place")
    local b = M.slotsBack()
    M.s = { state = "guest loaded" }
    return r .. "; " .. b
end-- (session.lua holds the zone's steps while the load's car is awaited)
function M.waitingCar() return M.s.waiting and not ownCar() and true or false end
-- the zone is in (session.lua, the new world): once the own car is there (the game's, or spawned after NO_CAR_S at
-- spot() - the host's car's place), the guest's own slot current again, the scratch slot gone (20 s at most)
function M.afterLoad(spot)
    local s = M.s
    if not s.scratch or s.waiting then return end
    s.waiting, s.loadedAt = true, now()
    local function done()
        local cars = #(FindAllOf("BP_PlayerCarNew_C") or {})
        if not ownCar() and not s.spawned and now() - s.loadedAt >= NO_CAR_S then
            s.spawned = true
            local at = spot and spot()
            local r = at and M.spawnOwnCar(at) or "no place for the own car"
            M.stats.spawn = r
            if CoopSyncHitch then pcall(CoopSyncHitch.note, "zone save: no car after the load - " .. r) end
        end
        if not ownCar() and now() - s.loadedAt < 20 then if CoopSyncAfter then CoopSyncAfter(500, done) end return end
        -- back in the seat it had before the load (startflow 2026-11-11: the game built the car but left the player
        -- standing beside it; the mod's own car likewise): a moment after the car is there
        if s.wasSeated and CoopSyncAfter then CoopSyncAfter(1000, M.seatNow) end
        M.slotsBack()
        pcall(function()
            local p = FindFirstOf("PlayerController").Pawn:K2_GetActorLocation()
            M.stats.after = string.format("cars=%d pawn=%.0f,%.0f after %.1f s", cars, p.X, p.Y, now() - s.loadedAt)
        end)
        if CoopSyncHitch then pcall(CoopSyncHitch.note, "zone save loaded: " .. tostring(M.stats.after)) end
        s.scratch, s.waiting, s.spawned = nil, nil, nil
    end
    if CoopSyncAfter then CoopSyncAfter(500, done) else done() end
end
function M.tick()
    if M.s.state == "host saving" then pcall(hostTick) end
    if M.s.state == "direct saving" then
        local ok, e = pcall(directTick)
        if not ok then M.s = { state = "direct failed", why = tostring(e) } end
    end
end

function M.info()
    return string.format("zonesave=%s saved=%d sent=%d loaded=%d last=%s before=%s after=%s spawn=%s", M.s.state, M.stats.saved, M.stats.sent, M.stats.loaded, M.stats.last, tostring(M.stats.before), tostring(M.stats.after), tostring(M.stats.spawn))
end

return M
