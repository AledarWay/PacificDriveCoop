-- The player's settings for CoopSync (owner, 2026-11-11: "put the value in a config to change it without rebuilding
-- the mod; and a way to turn it off"): <Saved>/CoopSync/config.txt - next to the mod's status and logs, so an update
-- of the mod does not write over it. "key = value" lines, "#" starts a comment. Written with the defaults and their
-- explanations when it is missing; read again at most every RELOAD_S, so a change applies within seconds.
local M = {}
CoopSyncConfig = M

local RELOAD_S = 5
-- (the tests - their channel set by COOPSYNC_CHAN - get no split entrances unless they write one: a test is to know
-- where the guest arrives)
local TESTS = (os.getenv("COOPSYNC_CHAN") or "") ~= ""
M.DEFAULTS = {
    entrance_split_chance = TESTS and 0 or 0.25,
    zone_from_save = 1,
    direct_load = 1,
}
local TEMPLATE = [[
# CoopSync settings. Edit and save; the game picks a change up within a few seconds.

# How often the host and the guest come into a zone by different entrances and have to find each other on the map
# (0 = never, 0.25 = about one zone in four, 1 = always). The host's value decides.
entrance_split_chance = 0.25

# The guest loads the host's exact zone from the host's save (the same buildings and rolls).
# 1 = on. 0 = off: the guest's game builds the zone from its own seed and the mod makes it the host's (the older way;
# some buildings can differ).
zone_from_save = 1

# With zone_from_save on: the guest goes from its garage straight into the host's zone with one load.
# 0 = the guest's game first travels into a zone of its own, then loads the host's over it (slower).
direct_load = 1
]]

local path, values, readAt = nil, {}, -1e9

local function parse(text)
    local t = {}
    for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        local l = line:gsub("#.*$", "")
        local k, v = l:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and v and v ~= "" then
            local n = tonumber(v)
            if n then t[k] = n
            elseif v == "on" or v == "true" or v == "yes" then t[k] = 1
            elseif v == "off" or v == "false" or v == "no" then t[k] = 0
            else t[k] = v end
        end
    end
    return t
end

local function read()
    if not path then return end
    readAt = os.clock()
    local f = io.open(path, "rb")
    if not f then
        local w = io.open(path, "wb")
        if w then w:write(TESTS and (TEMPLATE:gsub("entrance_split_chance = 0.25", "entrance_split_chance = 0")) or TEMPLATE) w:close() end
        values = {}
        return
    end
    local text = f:read("a")
    f:close()
    values = parse(text or "")
end

-- dir: the mod's channel directory (<Saved>/CoopSync)
function M.load(dir)
    path = dir and (dir:gsub("\\", "/"):gsub("/$", "") .. "/config.txt") or nil
    read()
    return path
end

function M.get(key)
    if os.clock() - readAt > RELOAD_S then pcall(read) end
    local v = values[key]
    if v == nil then v = M.DEFAULTS[key] end
    return v
end

-- (tests / the panel: what is in effect)
function M.info()
    local o = {}
    for k in pairs(M.DEFAULTS) do o[#o + 1] = k .. "=" .. tostring(M.get(k)) end
    table.sort(o)
    return "config " .. tostring(path) .. ": " .. table.concat(o, " ")
end

return M
