-- Crash trace for the game-thread loops: UE4SS's crash dumps hold no Lua stack (the heap is not in them), so a crash
-- in a loop callback names no mod function. Loaded first (CoopSync main.lua, CoopDev main.lua), it wraps
-- LoopInGameThreadWithDelay / ExecuteInGameThread. On while <COOPDEV_DIR>/trace-until.txt holds a time (os.time())
-- still ahead; each Lua state (CoopSyncTraceTag: "sync", "dev") then writes <COOPDEV_DIR>/trace-<tag>.txt, one flushed
-- line each. The file's second line is the mode:
--   light (default): "@ src:line" for each loop callback run and each CoopSyncAfter call (CoopSyncTraceNote), the
--     last line names the one a crash was in; cheap enough not to change the timing much.
--   full: a debug hook in each callback - "> src:line" for every mod function entered, "src:line" where a C function
--     (a UObject's method / property) is called from. Slows the loops a lot (it hid the going-home crash 3 of 3).
-- Off: one os.time() per callback and a file check a second (only with COOPDEV_DIR set: test instances).
if CoopSyncTraceWrapped then return end
CoopSyncTraceWrapped = true
local dir = os.getenv("COOPDEV_DIR")
local tag = CoopSyncTraceTag or "lua"
local f, last
local nextCheck, untilT, full = 0, 0, false
local function out(s)
    if s == last then return end
    last = s
    pcall(function() f:write(s, "\n") f:flush() end)
end
local function hook()
    local i = debug.getinfo(2, "S")
    if not i then return end
    if i.what == "C" then
        local c = debug.getinfo(3, "Sl")
        if c and c.what == "Lua" then out(c.short_src .. ":" .. c.currentline) end
    else
        out("> " .. i.short_src .. ":" .. i.linedefined)
    end
end
local function on()
    if not dir then return false end
    local t = os.time()
    if t >= nextCheck then
        nextCheck, untilT, full = t + 1, 0, false
        local h = io.open(dir .. "/trace-until.txt", "r")
        if h then
            untilT = tonumber(h:read("l")) or 0
            full = h:read("l") == "full"
            h:close()
        end
    end
    if t >= untilT then return false end
    if not f then f = io.open(dir .. "/trace-" .. tag .. ".txt", "a") end
    return f ~= nil
end
local function where(fn)
    local i = debug.getinfo(fn, "S")
    return i and (i.short_src .. ":" .. i.linedefined) or "?"
end
-- a line for fn about to run (light mode; CoopSyncAfter calls it for each due call)
function CoopSyncTraceNote(fn)
    if on() and not full then out(string.format("@ %s %.3f", where(fn), os.clock())) end
end
local function wrap(cb)
    local at = where(cb)
    return function(...)
        if not on() then return cb(...) end
        if not full then
            out(string.format("@ %s %.3f", at, os.clock()))
            return cb(...)
        end
        out(string.format("--- %s %s %.3f", at, os.date("%H:%M:%S"), os.clock()))
        debug.sethook(hook, "c")
        local r = table.pack(pcall(cb, ...))
        debug.sethook()
        if not r[1] then error(r[2], 0) end
        return table.unpack(r, 2, r.n)
    end
end
local rawLoop, rawExec = LoopInGameThreadWithDelay, ExecuteInGameThread
if rawLoop then LoopInGameThreadWithDelay = function(ms, cb) return rawLoop(ms, wrap(cb)) end end
if rawExec then ExecuteInGameThread = function(cb) return rawExec(wrap(cb)) end end
