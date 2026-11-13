-- CoopSync: co-op replication modules (spawnsync, lootsync, statesync, playersync, runsync, session, menu, panel).
-- Runs on its own here: the guest-car insurance watcher (runsync.watch: on every garage entry it puts back car
-- parts a co-op run as a guest took), the session (session.lua: driven by the in-game network or a test's
-- <chan>/control.txt; idle until it gets a role), the network (link.lua: CoopNative's Steam lobby + P2P), the co-op
-- menu (pause menu item) and the F7 panel (lobby + debug actions, a fallback when the pause-menu UI breaks).
-- Tests still start the sync modules by commands (CoopDev).
CoopSyncTraceTag = "sync"
require("trace") -- (first: it wraps the game-thread loops for a crash trace a test can switch on)
CoopSync = require("spawnsync")
CoopSyncRunMod = require("runsync")
CoopSyncSession = require("session")
CoopSyncMenu = require("menu")
CoopSyncPanel = require("panel")
CoopSyncChecklist = require("checklist")
local s = CoopSyncSession.start(CoopSync, CoopSyncRunMod)
-- the mod's own log in its channel (<chan>/coopsync.log, a new one per game start): UE4SS.log is one file for every
-- game started from this folder - the two copies of TwoGamesTest.bat wrote over each other's (owner's alpha 18 test)
do
    local f = io.open(CoopSyncSession.channel() .. "/coopsync.log", "w")
    if f then
        local rawPrint = print
        _G.print = function(...)
            rawPrint(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
            local line = table.concat(parts, " "):gsub("%s+$", "")
            -- (flushed by hand: "line" buffering is full buffering in the Windows C runtime - the log stayed empty)
            pcall(function() f:write(os.date("%H:%M:%S "), line, "\n") f:flush() end)
        end
    end
end
print("[CoopSync] loaded; " .. CoopSyncRunMod.watch() .. "; " .. s .. "; " .. CoopSyncSession.startNet() .. "; "
    .. CoopSyncMenu.start(CoopSyncSession) .. "; " .. CoopSyncPanel.start(CoopSyncSession, CoopSyncMenu) .. "; "
    .. CoopSyncChecklist.start(CoopSyncSession, CoopSyncMenu) .. "\n")
-- tests (journey-test): commands into THIS mod's Lua state - the running session's own modules (CoopDev runs in a
-- Lua state of its own: CoopSyncSession is not there). Only in a test game (COOPDEV_DIR set by the test's start):
-- <dir>/scmd.lua run on the game thread, its output and result appended to <dir>/sout.txt (send.ps1 -Session).
do
    local dir = os.getenv("COOPDEV_DIR")
    if dir and dir ~= "" then
        local cmd, out = dir .. "/scmd.lua", dir .. "/sout.txt"
        local after = CoopSyncAfter or require("hooks").after
        local function append(s) local f = io.open(out, "ab") if f then f:write(s) f:close() end end
        Dev = Dev or {}
        Dev.after = Dev.after or function(ms, fn) after(ms, fn) end
        Dev.out = Dev.out or function(...)
            local p = {}
            for i = 1, select("#", ...) do p[#p + 1] = tostring((select(i, ...))) end
            append(table.concat(p, "\t") .. "\n")
        end
        LoopInGameThreadWithDelay(300, function()
            local f = io.open(cmd, "rb")
            if not f then return end
            local src = f:read("*a")
            f:close()
            os.remove(cmd)
            append("=== cmd " .. os.date("%H:%M:%S") .. "\n")
            local fn, err = load(src, "scmd", "t")
            if not fn then Dev.out("COMPILE ERROR: " .. tostring(err))
            else
                local ok, res = pcall(fn)
                Dev.out(ok and ("OK " .. tostring(res)) or ("RUNTIME ERROR: " .. tostring(res)))
            end
            append("=== end\n")
        end)
    end
end
