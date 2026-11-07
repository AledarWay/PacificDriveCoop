-- CoopDev: developer remote control for agent-driven tests.
-- Polls <userdir>/coopdev/cmd.lua; when it appears, runs it on the game thread,
-- writes print output + result to out.txt, then deletes cmd.lua.
local DIR = os.getenv("COOPDEV_DIR") or "C:/PacificDriveCoop/local/coopdev"
local CMD = DIR .. "/cmd.lua"
local OUT = DIR .. "/out.txt"
local POLL_MS = 500
-- (CoopSync's crash trace: the sync modules a test starts here run in this mod's loops)
CoopSyncTraceTag = "dev"
pcall(dofile, "C:/PacificDriveCoop/mod/CoopSync/Scripts/trace.lua")

local function readall(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function append(path, s)
    local f = io.open(path, "ab")
    if f then f:write(s) f:close() end
end

-- helpers available to command scripts
Dev = {}
function Dev.out(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    append(OUT, table.concat(parts, "\t") .. "\n")
end
function Dev.name(obj)
    if obj == nil or not obj:IsValid() then return "<invalid>" end
    return obj:GetFullName()
end
function Dev.vec(v) return string.format("%.1f,%.1f,%.1f", v.X, v.Y, v.Z) end

-- fn on the game thread after ms, for commands (a key released later...). Never ExecuteWithDelay: UE4SS runs its
-- callback on the async thread against the same Lua registry with no lock - a test using it crashed the game in
-- luaH_getint (2026-10-26).
local later = {}
function Dev.after(ms, fn) later[#later + 1] = { at = os.clock() + ms / 1000, fn = fn } end
LoopInGameThreadWithDelay(10, function()
    if #later == 0 then return end
    local now, due, still = os.clock(), {}, {}
    for _, l in ipairs(later) do if now >= l.at then due[#due + 1] = l else still[#still + 1] = l end end
    later = still
    for _, l in ipairs(due) do
        if CoopSyncTraceNote then CoopSyncTraceNote(l.fn) end
        pcall(l.fn)
    end
end)

-- Poll on the game thread itself. LoopAsync runs its callback on another thread with the same
-- lua_State; that race corrupted the Lua registry ("Ref was not function") and crashed UE4SS.
LoopInGameThreadWithDelay(POLL_MS, function()
    local src = readall(CMD)
    if not src then return end
    os.remove(CMD)
    append(OUT, "=== cmd " .. os.date("%H:%M:%S") .. "\n")
    local fn, err = load(src, "cmd", "t")
    if not fn then
        Dev.out("COMPILE ERROR: " .. tostring(err))
    else
        local ok, res = pcall(fn)
        Dev.out(ok and ("OK " .. tostring(res)) or ("RUNTIME ERROR: " .. tostring(res)))
    end
    append(OUT, "=== end\n")
end)

print("[CoopDev] polling " .. CMD .. "\n")

