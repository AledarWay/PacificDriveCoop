-- Player-action audit: a small event log for reproducing reports after a real playtest. No world scans and nothing is
-- written while disabled (config.txt audit=0, F7 -> Debug toggles it). Tests can force it with COOPSYNC_AUDIT=1.
local M = {}
CoopSyncAudit = M

local path, started, keysDone = nil, false, false
local stats = { events = 0 }
local lastInput = {}

function M.enabled()
    if os.getenv("COOPSYNC_AUDIT") == "1" then return true end
    return CoopSyncConfig and CoopSyncConfig.get and CoopSyncConfig.get("audit") == 1
end

function M.event(kind, detail)
    if not started or not M.enabled() then return end
    local s = CoopSyncSession and CoopSyncSession.state and CoopSyncSession.state() or {}
    -- No engine lookup here: the audit starts before the first UWorld exists (construct_fname on nil crashed the game).
    local world = s.world or "?"
    local line = string.format("%s.%03d\t%s\t%s\t%s\t%s\t%s\n", os.date("%H:%M:%S"), math.floor((os.clock() % 1) * 1000),
        world, tostring(s.role or "-"), tostring(s.state or "-"), tostring(kind):gsub("%s", "_"), tostring(detail):gsub("[\r\n]+", " "):sub(1, 500))
    local f = io.open(path, "ab")
    if f then f:write(line) f:flush() f:close() stats.events = stats.events + 1 end
end

local KEY_NAMES = {
    [0x45] = "E", [0x57] = "W", [0x41] = "A", [0x53] = "S", [0x44] = "D", [0x20] = "Space",
    [0xA0] = "Shift", [0xA2] = "Ctrl", [0x43] = "C", [0x47] = "G", [0x48] = "H", [0x4B] = "K",
    [0x4C] = "L", [0x52] = "R", [0x09] = "Tab", [0x1B] = "Esc", [0x76] = "F7",
}
function M.input(what, value)
    if what == "carLookX" or what == "carLookY" then return end
    if lastInput[what] == value then return end
    lastInput[what] = value
    M.event("input", what .. "=" .. tostring(value))
end

function M.start(dir)
    path = dir:gsub("\\", "/"):gsub("/$", "") .. "/audit.log"
    started = true
    if M.enabled() then
        os.remove(path .. ".2") os.rename(path .. ".1", path .. ".2") os.rename(path, path .. ".1")
        M.event("audit", "started")
    end
    if keysDone then return end
    keysDone = true
    local OnKey = CoopSyncOnKey or dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "hooks.lua").onKey
    for vk, name in pairs(KEY_NAMES) do
        OnKey(vk, (function(down) M.event("key", name .. "=" .. (down and "down" or "up")) end), true)
    end
end

function M.toggle()
    if not (CoopSyncConfig and CoopSyncConfig.set) then return "audit config unavailable" end
    local enable = not M.enabled()
    CoopSyncConfig.set("audit", enable and 1 or 0)
    M.event("audit", enable and "enabled" or "disabled")
    return enable and "audit: on" or "audit: off"
end

function M.info()
    return string.format("enabled=%s events=%d path=%s", tostring(M.enabled()), stats.events, tostring(path))
end

return M
