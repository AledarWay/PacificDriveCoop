-- The channel to the other player, two transports:
--   native  CoopNative's in-game network (mod/CoopNative/net.cpp: Steam lobby + P2P, or the local test link): lines,
--           the menu's commands, the lobby status and the session's commands go through memory
--   files   the channel files (<chan>/host.events, host.fast, ..., net-control.txt, net-status.txt), moved by
--           CoopNet.exe (the old helper, COOPSYNC_NET=exe) or the tests' relays (relay.ps1)
-- The lines take the in-game network once it gave the session its role (M.carries); a role from <chan>/control.txt
-- (the relay tests) keeps them on the files. The host's documents (zone list, run descriptor, gates, map, session
-- line) likewise: "doc:<name>" paths in memory (CoopNative_DocPut / DocGet, the latest version of each, sent again to
-- every new peer), else <chan>/outbox -> the other's <chan>/inbox files. (Files of an earlier game in the inbox sent
-- the guest to another map in alpha 9.)
local M = {}
local chan
M.mode = "files"  -- "native": the in-game network runs | "offline": it could not start (no Steam) | "files"
M.native = false  -- mode == "native"
M.carries = false -- the session's role came from it: the lines go through it

local CH = { ["host.events"] = 0, ["client.requests"] = 0, ["host.fast"] = 1, ["client.fast"] = 1 }

local function lines(s)
    local t = {}
    for l in (s or ""):gmatch("([^\n]*)\n") do t[#t + 1] = l end
    return t
end

-- COOPSYNC_NET: "" = Steam, "tcp:<port>:<name>" = the local test link (two games on one PC), "exe" = CoopNet.exe
function M.start(chanDir)
    chan = chanDir
    local spec = os.getenv("COOPSYNC_NET") or ""
    if spec == "exe" or not CoopNative_NetStart then M.mode, M.native = "files", false return nil end
    local r = tostring(CoopNative_NetStart(chan, spec))
    M.native = not r:match("^offline")
    M.mode = M.native and "native" or "offline"
    return "in-game network: " .. r
end

-- The game brings Steam up after the mod has started (owner's alpha 8: "Steam not initialized" at the start, a lobby
-- made fine later by hand): while the in-game network is offline it is started again every RETRY_S (session tick).
local RETRY_S, lastTry = 2, 0
function M.tick()
    if M.mode ~= "offline" or os.clock() - lastTry < RETRY_S then return end
    lastTry = os.clock()
    M.start(chan)
end

-- the menu's commands (create | join <id> | leave | invite <id> | mode m | ready 0/1 | start | runend)
function M.cmd(s)
    if M.native then CoopNative_NetCmd(s) return end
    local f = io.open(chan .. "/net-control.txt", "ab")
    if f then f:write(s .. "\n") f:close() end
end

-- the lobby's status: the head line (state=.. lobby=.. owner=.. peer=..) and member / friend / invite rows
function M.status()
    if M.mode ~= "files" then
        local s = CoopNative_NetStatus()
        if s ~= "" then return lines(s) end
    end
    local f = io.open(chan .. "/net-status.txt", "rb")
    if not f then return {} end
    local t = {}
    for l in f:lines() do t[#t + 1] = l end
    f:close()
    return t
end

-- the session's commands from the in-game network (role host | role client | mode m | go | stop)
function M.sessionLines()
    if not M.native then return {} end
    return lines(CoopNative_NetSession())
end

-- a line on stream (host.events, client.requests, host.fast, client.fast): true = sent through memory, false = the
-- caller writes its file
function M.send(stream, line)
    if not M.carries then return false end
    CoopNative_NetSend(CH[stream], line)
    return true
end

-- the other's lines on stream since the last call, or nil: read the file
function M.recv(stream)
    if not M.carries then return nil end
    return lines(CoopNative_NetRecv(CH[stream]))
end

-- where the document name lives: "doc:<name>" through the in-game network, else the channel file (box: "outbox" for
-- this side's, "inbox" for the other's)
function M.docPath(chanDir, box, name)
    if M.carries then return "doc:" .. name end
    return chanDir .. "/" .. box .. "/" .. name
end
-- a document's text (nil: none yet) or a file's; and its version (documents: how many came of that name)
function M.read(path)
    if not path then return nil end
    if path:sub(1, 4) == "doc:" then
        if not CoopNative_DocGet then return nil end
        return CoopNative_DocGet(path:sub(5))
    end
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a") f:close()
    return s
end
function M.write(path, text)
    if path:sub(1, 4) == "doc:" then
        if not CoopNative_DocPut then return false end
        CoopNative_DocPut(path:sub(5), text)
        return true
    end
    local f = io.open(path .. ".tmp", "wb")
    if not f then return false end
    f:write(text) f:close()
    os.remove(path)
    return os.rename(path .. ".tmp", path)
end
CoopSyncRead, CoopSyncWrite = M.read, M.write

-- a session start: lines that came in before belong to the last one
function M.drain(stream)
    if M.carries then CoopNative_NetDrain(CH[stream]) end
end

CoopSyncLink = M
return M
