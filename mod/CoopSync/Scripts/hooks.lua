-- Hooks on the game's functions, one safe way for every module (2026-10-26). RegisterHook on a path that is no
-- UFunction (a class not loaded yet, a function the class does not have) raises a C++ error inside UE4SS; caught by
-- pcall it still degrades the Lua state, and repeated it crashed the game later anywhere in Lua (esc-test, NOTES "The
-- esc-test crash"). So a hook is registered only once its function is there - a Function object at exactly that path;
-- one that is not there yet (a blueprint class loads with the game's UI or a zone) waits and is tried every RETRY_MS.
--   CoopSyncHook(path, pre, post) -> "hooked" | "waiting"   (pre / post as RegisterHook takes them; post optional)
local M = {}
local SFO = StaticFindObject
if CoopNative_HasPath then SFO = function(p) if CoopNative_HasPath(p) then return StaticFindObject(p) end return nil end end

local RETRY_MS = 2000
M.waiting = {} -- { path, pre, post }
M.stats = { hooked = 0, waited = 0, failed = 0 }

function M.exists(path)
    local f = SFO(path)
    if not (f and f:IsValid()) then return false end
    local ok, c = pcall(function() return f:GetClass():GetFName():ToString() end)
    return ok and c == "Function"
end

local function register(h)
    local ok, e = pcall(RegisterHook, h.path, h.pre, h.post)
    if ok then M.stats.hooked = M.stats.hooked + 1 return true end
    -- (it existed and still failed: not tried again - a repeated failure is what breaks the Lua state)
    M.stats.failed = M.stats.failed + 1
    if CoopSyncHitch then CoopSyncHitch.note("hook failed: " .. h.path .. ": " .. tostring(e):sub(1, 120)) end
    return true
end

local looping = false
local function retryLoop()
    if looping then return end
    looping = true
    local h
    h = LoopInGameThreadWithDelay(RETRY_MS, function()
        local ok = pcall(function()
            local still = {}
            for _, w in ipairs(M.waiting) do
                if M.exists(w.path) then register(w) else still[#still + 1] = w end
            end
            M.waiting = still
        end)
        if (not ok or #M.waiting == 0) and h then CancelDelayedAction(h) h = nil looping = false end
    end)
end

function M.hook(path, pre, post)
    local h = { path = path, pre = pre, post = post or function() end }
    if M.exists(path) then register(h) return "hooked" end
    M.waiting[#M.waiting + 1] = h
    M.stats.waited = M.stats.waited + 1
    retryLoop()
    return "waiting"
end
function M.info()
    return string.format("hooks=%d waiting=%d failed=%d", M.stats.hooked, #M.waiting, M.stats.failed)
end

-- fn on the game thread after ms (2026-10-26). UE4SS's ExecuteWithDelay runs its callback on the mod's async thread
-- against the same Lua registry, with no lock (LuaMod::process_delayed_actions): racing the game thread's Lua it broke
-- the registry - a crash in luaH_getint under lua_rawgeti (ghostseat-test, a test's delayed key release). Never use
-- ExecuteWithDelay / LoopAsync: one game-thread loop runs the due calls instead.
--   CoopSyncAfter(ms, fn)
M.later = {}
local afterLooping = false
function M.after(ms, fn)
    M.later[#M.later + 1] = { at = os.clock() + ms / 1000, fn = fn }
    if afterLooping then return end
    afterLooping = true
    LoopInGameThreadWithDelay(10, function()
        if #M.later == 0 then return end
        local now, due, still = os.clock(), {}, {}
        for _, l in ipairs(M.later) do
            if now >= l.at then due[#due + 1] = l else still[#still + 1] = l end
        end
        M.later = still
        for _, l in ipairs(due) do
            if CoopSyncTraceNote then CoopSyncTraceNote(l.fn) end
            local ok, e = pcall(l.fn)
            if not ok and CoopSyncHitch then CoopSyncHitch.note("after: " .. tostring(e):sub(1, 120)) end
        end
    end)
end

-- fn on the game thread when key vk goes down (2026-10-29). UE4SS's RegisterKeyBind calls its Lua callback on UE4SS's
-- own thread, in the Lua state the game thread's loops and hooks use, and those take no lock (LuaMod.cpp:
-- process_delayed_actions, the hook callbacks): an Esc / F7 during a loop broke the Lua heap (the friend's alpha 16
-- crash inside a fresh Lua table, reading an enum). The keys are polled here instead (CoopNative_KeyDown: the key
-- held while this game's window is in front). Without it (an old main.dll) RegisterKeyBind as before.
--   CoopSyncOnKey(vk, fn)
M.keys = {}
local keyLooping = false
function M.onKey(vk, fn)
    if not CoopNative_KeyDown then
        return pcall(RegisterKeyBind, vk, function() ExecuteInGameThread(fn) end)
    end
    M.keys[#M.keys + 1] = { vk = vk, fn = fn, was = true } -- (held at the start: not a press)
    if keyLooping then return true end
    keyLooping = true
    LoopInGameThreadWithDelay(15, function()
        for _, k in ipairs(M.keys) do
            local down = CoopNative_KeyDown(k.vk) == true
            if down and not k.was then
                local ok, e = pcall(k.fn)
                if not ok and CoopSyncHitch then CoopSyncHitch.note("key: " .. tostring(e):sub(1, 120)) end
            end
            k.was = down
        end
    end)
    return true
end

CoopSyncHook, CoopSyncHooks, CoopSyncAfter, CoopSyncOnKey = M.hook, M, M.after, M.onKey
return M
