-- Map marks (alpha 22 item 4, owner: "the other player green; each one's own marks seen by both, one's own blue, the
-- other's green"). Both sides send their own marks (the game's BP_WaypointActor_C, placed on the ARC map) on the player
-- channel (playersync.send / onMarks):
--   MK  <n> then x, y, z per mark - every SEND_MS when they changed, else every RESEND_MS
-- The other's marks are spawned here as waypoint actors of their own, their map icon green; marks gone there go here.
-- The other player's car (its twin, twincar.lua) is colored green by M.paintTwin.
-- The game keeps one own waypoint (UMG_GobblerScreen.Waypoint, FindExistingWaypoint): a green one it took for its own
-- (moved by the player's next pin) is let go - its color back, it counts as own from then on - and sent.
-- The host's zone save carries its waypoints, the guest's ones among them: after the guest's load they stand there as
-- the guest's own. The guest takes an own one where a host mark is for that mark (green); the host spawns none over an
-- own one of its (the guest sent those back before it knew).
local M = {}
local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")

local SEND_MS, RESEND_MS = 500, 5000
local SAME_CM = 100 -- a mark this close to where it was is the same mark
local CLASS = "/Game/UI/CarEquipment/Internal/Gobbler/BP_WaypointActor.BP_WaypointActor_C" -- (else taken from an own one)
M.GREEN = { R = 0.1, G = 1.0, B = 0.2, A = 1.0 }

local Players, role
local st = { sent = 0, applied = 0, spawned = 0, removed = 0, taken = 0, painted = 0, errors = {} }
local remote = {} -- address -> { a = actor, loc = where it was put, color = its own color }
local lastSent, lastSentMs = nil, 0

local function err(s)
    if #st.errors < 5 then st.errors[#st.errors + 1] = tostring(s):sub(1, 160) end
end
local function d2(a, b) local x, y, z = a.X - b.X, a.Y - b.Y, a.Z - b.Z return x * x + y * y + z * z end
-- (a destroyed one stays in FindAllOf until the GC, valid, not "being destroyed", at exactly 0,0,0: marks-test counted
-- the removed ones)
local function valid(a)
    if not (a and a:IsValid()) or a:GetFullName():find("Default__", 1, true) then return false end
    local l = a:K2_GetActorLocation()
    return not (l.X == 0 and l.Y == 0 and l.Z == 0)
end

local function paint(icon, color)
    icon:SetIconDrawColor(color)
    local n = 0
    pcall(function() n = icon:GetIconLayerCount() end)
    for i = 0, (n or 0) - 1 do pcall(function() icon:SetIconDrawColorForLayer(color, i) end) end
end
local function colorOf(icon)
    local c = icon.IconDrawColor
    return { R = c.R, G = c.G, B = c.B, A = c.A }
end

-- the other's car on this side green
function M.paintTwin(twin)
    local ok, e = pcall(function() paint(twin.MapIcon, M.GREEN) end)
    if ok then st.painted = st.painted + 1 else err("twin: " .. tostring(e)) end
end

local function waypoints()
    local out = {}
    for _, a in ipairs(FindAllOf("BP_WaypointActor_C") or {}) do if valid(a) then out[#out + 1] = a end end
    return out
end

-- a green one the game moved (the player's pin put there) is the player's own from now on
local function letGoTaken()
    for addr, r in pairs(remote) do
        if not valid(r.a) then remote[addr] = nil
        elseif d2(r.a:K2_GetActorLocation(), r.loc) > SAME_CM * SAME_CM then
            pcall(paint, r.a.MapIcon, r.color)
            remote[addr] = nil
            st.taken = st.taken + 1
        end
    end
end

local function ownMarks()
    local out = {}
    for _, a in ipairs(waypoints()) do
        if not remote[a:GetAddress()] then out[#out + 1] = a:K2_GetActorLocation() end
    end
    return out
end

local function line(marks)
    local f = { tostring(#marks) }
    for _, l in ipairs(marks) do f[#f + 1] = string.format("%.0f\t%.0f\t%.0f", l.X, l.Y, l.Z) end
    return table.concat(f, "\t")
end

function M.tick(nowMs)
    if not Players or Players.stopped then return end
    letGoTaken()
    local f = line(ownMarks())
    if f ~= lastSent or nowMs - lastSentMs >= RESEND_MS then
        if Players.send("MK", f) then st.sent = st.sent + 1 lastSent, lastSentMs = f, nowMs end
    end
end

local cls
local function wpClass()
    if cls and cls:IsValid() then return cls end
    -- (StaticFindObject itself: the native path check missed the loaded class; the miss costs once, then cached)
    cls = StaticFindObject(CLASS)
    if not (cls and cls:IsValid()) then
        local any = waypoints()[1]
        cls = any and any:GetClass() or nil
    end
    if not (cls and cls:IsValid()) then
        pcall(function() LoadAsset(CLASS:gsub("%.[^.]+$", "")) end)
        cls = StaticFindObject(CLASS)
    end
    return cls
end

local function spawnAt(l)
    local c = wpClass()
    if not c then err("no waypoint class") return nil end
    local xf = KML:MakeTransform(l, { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 1, Y = 1, Z = 1 })
    local b = GS:BeginDeferredActorSpawnFromClass(FindFirstOf("PlayerController"), c, xf, 1, nil)
    local a = GS:FinishSpawningActor(b, xf)
    if not valid(a) then return nil end
    local color = { R = 1, G = 1, B = 1, A = 1 }
    pcall(function() color = colorOf(a.MapIcon) end)
    pcall(paint, a.MapIcon, M.GREEN)
    remote[a:GetAddress()] = { a = a, loc = l, color = color }
    st.spawned = st.spawned + 1
    return a
end

-- MK from the other: its marks here, green; the ones it took away gone
function M.apply(t)
    local n = tonumber(t[3]) or 0
    local want = {}
    for i = 1, n do
        local j = 3 + (i - 1) * 3
        local x, y, z = tonumber(t[j + 1]), tonumber(t[j + 2]), tonumber(t[j + 3])
        if x and y and z then want[#want + 1] = { X = x, Y = y, Z = z } end
    end
    letGoTaken()
    local have = {}
    for addr, r in pairs(remote) do have[#have + 1] = addr end
    for _, l in ipairs(want) do
        local hit
        for i, addr in ipairs(have) do
            if d2(remote[addr].loc, l) <= SAME_CM * SAME_CM then hit = i break end
        end
        local mine
        if not hit then
            for _, a in ipairs(waypoints()) do
                if not remote[a:GetAddress()] and d2(a:K2_GetActorLocation(), l) <= SAME_CM * SAME_CM then mine = a break end
            end
        end
        if hit then table.remove(have, hit)
        elseif mine and role == "client" then
            local color = { R = 1, G = 1, B = 1, A = 1 }
            pcall(function() color = colorOf(mine.MapIcon) end)
            pcall(paint, mine.MapIcon, M.GREEN)
            remote[mine:GetAddress()] = { a = mine, loc = mine:K2_GetActorLocation(), color = color }
            st.adopted = (st.adopted or 0) + 1
        elseif mine then
        else
            local ok, e = pcall(spawnAt, l)
            if not ok then err("spawn: " .. tostring(e)) end
        end
    end
    for _, addr in ipairs(have) do
        local r = remote[addr]
        remote[addr] = nil
        if valid(r.a) then pcall(function() r.a:K2_DestroyActor() end) st.removed = st.removed + 1 end
    end
    st.applied = st.applied + 1
end

-- the other's marks gone (session over, zone left): its waypoints are not the player's
function M.clear()
    for addr, r in pairs(remote) do
        if valid(r.a) then pcall(function() r.a:K2_DestroyActor() end) end
        remote[addr] = nil
    end
    lastSent = nil
end

function M.start(playersModule, r)
    Players, role = playersModule, r
    M.clear()
    Players.onMarks = function(t)
        local ok, e = pcall(M.apply, t)
        if not ok then err("apply: " .. tostring(e)) end
    end
    M.gen = (M.gen or 0) + 1
    local gen = M.gen
    local h
    h = LoopInGameThreadWithDelay(SEND_MS, function()
        if gen ~= M.gen then if h then CancelDelayedAction(h) end return end
        local t0 = os.clock()
        local ok, e = pcall(M.tick, Players.nowMs())
        if CoopSyncHitch then CoopSyncHitch.spent(os.clock() - t0, "marks") end
        if not ok then err("tick: " .. tostring(e)) end
    end)
    return "marks: on"
end

function M.stop()
    M.gen = (M.gen or 0) + 1
    if Players then Players.onMarks = nil end
    M.clear()
end

function M.short()
    local n = 0
    for _ in pairs(remote) do n = n + 1 end
    return string.format("%d/%d/%d:%d", st.sent, st.applied, n, st.taken)
end
function M.info()
    local n = 0
    for _ in pairs(remote) do n = n + 1 end
    return string.format("role=%s sent=%d applied=%d remote=%d spawned=%d adopted=%d removed=%d taken=%d painted=%d own=%d errors=%d %s",
        tostring(role), st.sent, st.applied, n, st.spawned, st.adopted or 0, st.removed, st.taken, st.painted, #ownMarks(), #st.errors, table.concat(st.errors, "; "))
end

CoopSyncMarks = M
return M
