-- The host's zone through the game's own save (owner, 2026-10-30: "the zone reproducible the right way"; NOTES
-- "Prototype: the host's zone through the game's save" - the guest got the host's exact zone, 1945 of 1954 objects,
-- where generating it from the seed left buildings as other variants, interiors outside).
--   Host, its zone settled: the game's SaveGame into a scratch slot (past the menu's slots), back to its own slot,
--     the file to the guest as a document ("host-zonesave-<seq>"), the scratch slot deleted.
--   Guest, arrived (the game generated the zone from the seed meanwhile): its departure save (the slot the game wrote
--     on leaving the garage: its car, inventory, garage, managers - no zone) gets the host's "Map" (the zone, every
--     object as the host's game has it) put in (CoopNative_SaveSplice; its scene's player / car transforms moved
--     beside the host's car), a backup kept, and the game loads it (UserLoadGame) - the host's zone, the game's way.
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
function M.slotPath(slot) local d = M.saveDir() return d and (d .. "odsave" .. tostring(slot) .. ".sav") or nil end
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

-- a free save slot of the game's (one past its last is not saved at all): the highest without a file, else none -
-- the player's saves are never written over
function M.scratchSlot()
    local m = sm()
    local max = 9
    pcall(function() max = m:GetMaxSaveSlots() end)
    for slot = max, 2, -1 do
        if slot ~= m.CurrentSaveSlot and not fileSize(M.slotPath(slot)) then return slot end
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
    if CoopNative_DeleteFiles then CoopNative_DeleteFiles(M.saveDir(), "odsave" .. s.scratch .. "-backup-") end
    M.stats.saved, M.stats.sent = M.stats.saved + 1, sent > 0 and M.stats.sent + 1 or M.stats.sent
    M.stats.last = string.format("host: %s %d bytes in %.1f s (call %.0f ms), slot %d back to %d", s.doc, sent, now() - s.t0, s.callMs, s.scratch, s.own)
    M.s = { state = sent > 0 and "host sent" or "host failed", doc = s.doc }
end

-------------------------------------------------------------------------------------------------------------------
-- guest
-- the host's zone save (document docName) into the guest's own departure save, loaded. Returns a note.
function M.guestLoad(docPath, side)
    local m = sm()
    if not (m and m:IsValid()) then return nil, "no save manager" end
    local slot = m.CurrentSaveSlot
    local own = M.slotPath(slot)
    local dir = M.saveDir()
    if not (own and fileSize(own)) then return nil, "no own save at " .. tostring(own) end
    local hostFile = dir .. "coop-host-zone.sav"
    local v
    if docPath:sub(1, 4) == "doc:" then v = CoopNative_DocGetFile and CoopNative_DocGetFile(docPath:sub(5), hostFile)
    elseif fileSize(docPath) then v = copyFile(docPath, hostFile) end
    if not v then return nil, "no host zone save yet" end
    -- (a backup of the own save: its departure state, restored by M.restore if anything goes wrong)
    local bak = dir .. "odsave" .. slot .. ".coopbak"
    if not copyFile(own, bak) then return nil, "backup failed" end
    local t0 = now()
    local r = CoopNative_SaveSplice(own, hostFile, own, 0, side or 500)
    if not tostring(r):find("^ok") then copyFile(bak, own) return nil, "splice: " .. tostring(r) end
    local spliceMs = (now() - t0) * 1000
    M.selfLoad = true -- (session.lua's load hook: not a player's load, the lobby stays)
    local ok, e = pcall(function() m:UserLoadGame(slot, 1, 0) end)
    M.selfLoad = false
    if not ok then copyFile(bak, own) return nil, "UserLoadGame: " .. tostring(e) end
    M.stats.loaded = M.stats.loaded + 1
    M.stats.last = string.format("guest: %s into slot %d (%s, %.0f ms), loading", docPath, slot, r, spliceMs)
    M.s = { state = "guest loading", slot = slot, bak = bak, t0 = now() }
    return M.stats.last
end

function M.tick()
    if M.s.state == "host saving" then pcall(hostTick) end
end

function M.info()
    return string.format("zonesave=%s saved=%d sent=%d loaded=%d last=%s", M.s.state, M.stats.saved, M.stats.sent, M.stats.loaded, M.stats.last)
end

return M
