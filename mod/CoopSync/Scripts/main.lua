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
