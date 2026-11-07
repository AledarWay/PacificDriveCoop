-- Counts game-thread frames for FPS_SEC seconds (default 5) and returns frames per second + the slowest frame.
-- Run it, wait FPS_SEC + 1 s, run it again with FPS_READ = true to read the result.
if FPS_READ then
    local r = CoopDevFps
    if not r or not r.done then return "not done" end
    return string.format("fps=%.1f worst_frame_ms=%.0f frames=%d", r.n / r.sec, r.worst * 1000, r.n)
end
CoopDevFps = { n = 0, sec = FPS_SEC or 5, worst = 0, done = false }
local r = CoopDevFps
local t0 = os.clock()
local last = t0
LoopInGameThreadWithDelay(1, function()
    if r.done then return true end
    local t = os.clock()
    r.n = r.n + 1
    if t - last > r.worst then r.worst = t - last end
    last = t
    if t - t0 >= r.sec then r.done = true return true end
end)
return "counting " .. r.sec .. " s"
