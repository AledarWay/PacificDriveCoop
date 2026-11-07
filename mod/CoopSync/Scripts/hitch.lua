-- Hitch log (owner's real test, 2026-10-24: short stalls and stalls up to a minute in the zone, on the friend's PC
-- most): <chan>/hitches.log gets every frame gap over GAP_MS (the game stood still) with the mod's own heavy work
-- of that gap, and every mod operation over OP_MS. The report zip takes the file, so a real test shows whether the
-- mod or the game stalled, and in what.
--   G <time> <gap ms> <world> <ops in the gap: label=ms,...>
--   O <time> <label> <ms>
--   N <time> <text>      (a job's summary: the import / cleanup / twin restyle spread over frames)
--   F <time> <fps> <frame ms avg> <frame ms worst> <mod ms per frame> <world> <module=ms,...>   every WINDOW_S: low frame rates the
--     gap lines miss (owner, alpha 9: 15-22 fps in the session, nothing over 250 ms); mod ms = the time of the mod's
--     own loops (every module's loop helper reports it through M.spent)
local M = {}

local GAP_MS, OP_MS = 250, 30
local MAX_LINES = 5000 -- per game start; the file is started over at every start
local path
local lines = 0
local last
local ops = {} -- operations since the last frame: { label, ms }
M.stats = { gaps = 0, worst = 0, ops = 0 }
local WINDOW_S, LOAD_MS = 10, 1000
local win = { t0 = nil, frames = 0, ms = 0, worst = 0, mod = 0, by = {} }
M.fps, M.modMs = -1, -1
-- seconds the mod's loops took (summed per window, and per module: label)
function M.spent(s, label)
    win.mod = win.mod + s
    if label then win.by[label] = (win.by[label] or 0) + s end
end

local function stamp() return os.date("%H:%M:%S") end
local function write(s)
    if not path or lines >= MAX_LINES then return end
    local f = io.open(path, "ab")
    if f then f:write(s, "\n") f:close() lines = lines + 1 end
end

-- a module's operation took ms (called by the modules; CoopSyncHitch.op from anywhere)
function M.op(label, ms)
    if ms < OP_MS then return end
    ops[#ops + 1] = { label, ms }
    M.stats.ops = M.stats.ops + 1
    write(string.format("O\t%s\t%s\t%.0f", stamp(), label, ms))
end
-- a line of its own (a job's summary): N <time> <text>
function M.note(text) write(string.format("N\t%s\t%s", stamp(), text)) end
-- time f as an operation: returns f's results (pcall-style: ok, ...)
function M.timed(label, f, ...)
    local t0 = os.clock()
    local r = table.pack(pcall(f, ...))
    M.op(label, (os.clock() - t0) * 1000)
    return table.unpack(r, 1, r.n)
end

local function frame()
    local now = os.clock()
    if last then
        local gap = (now - last) * 1000
        if gap > GAP_MS then
            M.stats.gaps = M.stats.gaps + 1
            if gap > M.stats.worst then M.stats.worst = gap end
            local o = {}
            for _, x in ipairs(ops) do o[#o + 1] = string.format("%s=%.0f", x[1], x[2]) end
            local world = "-"
            pcall(function() world = FindFirstOf("DrivingGameInstance"):GetWorld():GetFName():ToString() end)
            write(string.format("G\t%s\t%.0f\t%s\t%s", stamp(), gap, world, #o > 0 and table.concat(o, ",") or "-"))
        end
    end
    ops = {}
    -- the window: frames and their time (a travel's load left out), the mod's share
    if last then
        local gap = (now - last) * 1000
        if gap < LOAD_MS then
            win.frames, win.ms = win.frames + 1, win.ms + gap
            if gap > win.worst then win.worst = gap end
        end
    end
    win.t0 = win.t0 or now
    if now - win.t0 >= WINDOW_S and win.frames > 0 then
        M.fps = 1000 * win.frames / math.max(win.ms, 1)
        M.modMs = win.mod * 1000 / win.frames
        local world = "-"
        pcall(function() world = FindFirstOf("DrivingGameInstance"):GetWorld():GetFName():ToString() end)
        -- the modules' ms per frame, the costliest first
        local by = {}
        for k, v in pairs(win.by) do by[#by + 1] = { k, v * 1000 / win.frames } end
        table.sort(by, function(a, b) return a[2] > b[2] end)
        local t = {}
        for i = 1, math.min(#by, 5) do t[i] = string.format("%s=%.2f", by[i][1], by[i][2]) end
        write(string.format("F	%s	%.0f	%.1f	%.0f	%.1f	%s	%s", stamp(), M.fps, win.ms / win.frames, win.worst, M.modMs, world, table.concat(t, ",")))
        win = { t0 = now, frames = 0, ms = 0, worst = 0, mod = 0, by = {} }
    end
    last = now
end

function M.start(chan)
    path = chan .. "/hitches.log"
    local f = io.open(path, "wb")
    if f then f:write("# CoopSync hitch log, game start ", os.date("%Y-%m-%d %H:%M:%S"), "\n") f:close() end
    -- every frame (LoopInGameThreadWithDelay(1) runs once per frame); a travel's load is one long gap, logged too
    LoopInGameThreadWithDelay(1, function() pcall(frame) end)
    return "hitch log: " .. path
end

function M.short() return string.format("%d/%.0f/%d", M.stats.gaps, M.stats.worst, M.stats.ops) end
-- the last window: fps / the mod's ms per frame
function M.fpsShort() return string.format("%.0f/%.1f", M.fps, M.modMs) end

CoopSyncHitch = M
return M
