-- Weather and time of day: the host's sky for both. The guest's own weather events are paused; the host sends,
-- on the player channel (playersync.send / onWeather):
--   W   every SEND_MS: time of day, the target ToD preset, the 7 current override values (rain, fog, wind,
--       darkness, zone storm, acid, speed), precipitation, wetness, wind speed, the sky's two cloud layer
--       positions (ToD_Simulation_C UVBase/SecondLayerPosition: they pile up from the map's load, so each game had
--       its own clouds and cloud shadows - light and gaps differed though sun and intensities matched)
--   WE  a weather event started (its class) - the guest starts the same one (sounds, lightning, effects)
--   WC  the event was cleared / ended
-- and in W the north (owner, alpha 19 item 9: "the ARC map's orientation differs, the compass points do not match"):
-- some zones (Wilderness_*) pick a random north (BP_ToDManager_C RandomizeNorth: DataBlock_IsUsingRandomNorth /
-- DataBlock_PickedRandomNorth -> CurrentTrueNorth, "Current North As Rotator", the ToD actor's yaw); the guest's
-- manager kept its own (probed in Wilderness_Swamp_14: host picked 180, guest none). The guest takes the host's pick
-- and runs RandomizeNorth too (with a pick in its data block it uses that one: probed), else SetTrueNorth.
-- The guest holds the host's override values as its own top-priority weather override ("CoopSync"), so its
-- ToD manager eases toward the host's sky instead of its own; time of day is set when it drifts.
local M = {}
-- the game's functions hooked only once they exist (hooks.lua)
local Hook = CoopSyncHook or dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "hooks.lua").hook
-- path lookups: the native one answers a miss at once (UE4SS walks every object then: ~50 ms)
local SFO = StaticFindObject
if CoopNative_HasPath then SFO = function(p) if CoopNative_HasPath(p) then return StaticFindObject(p) end return nil end end

local SEND_MS = 2000
local TOD_DRIFT = 0.001 -- of a day (~a game minute and a half): closer than this is left alone
local OVERRIDE_TAG = "CoopSync"
local FN = "/Game/Systems/Directors/BP_ToDDirector.BP_ToDDirector_C:"

local Players, role
local st = { sent = 0, applied = 0, events = 0, todSets = 0, errors = {} }
local lastPreset

local function err(m) if #st.errors < 10 then st.errors[#st.errors + 1] = tostring(m) end end
local function loop(ms, fn)
    local h
    h = LoopInGameThreadWithDelay(ms, function()
        -- (an error escaping here made UE4SS drop the loop for good: the co-op menu item never came back, alpha 9)
        local t0 = os.clock()
        local ok, r = pcall(fn)
        if CoopSyncHitch then CoopSyncHitch.spent(os.clock() - t0, "weather") end
        if not ok then
            if CoopSyncHitch then CoopSyncHitch.note("loop error: " .. tostring(r):sub(1, 200)) end
            return
        end
        if r == true and h then CancelDelayedAction(h) end
    end)
    return h
end
local function manager() return FindFirstOf("BP_ToDManager_C") end
local function director() return FindFirstOf("BP_ToDDirector_C") end
local function short(o) return (o:GetFullName():gsub("^%S+ ", "")) end
-- this world's name (the persistent level's map), and the ARC map view in it
local function worldName()
    local pc = FindFirstOf("PlayerController")
    local p = pc and pc.Pawn
    if not (p and p:IsValid()) then return nil end
    return p:GetFullName():match("^%S+%s+/[^.]*%.([^:]+):PersistentLevel")
end
-- (FindAllOf walks every object, ~3.5 ms: the views found are kept, looked up again every 20 s or when one is gone)
-- (an actor of the last world stays IsValid until the GC: only the views of this world)
local mvCache, mvAt, mvWorld = {}, -100, nil
local function mapviews()
    local w = worldName()
    local fresh = os.clock() - mvAt < 20 and w == mvWorld
    for _, a in ipairs(mvCache) do if not a:IsValid() then fresh = false end end
    if fresh then return mvCache end
    local r = {}
    for _, a in ipairs(FindAllOf("BP_GobblerMapview_C") or {}) do
        if a:IsValid() and w and a:GetFullName():find("." .. w .. ":PersistentLevel", 1, true) then r[#r + 1] = a end
    end
    mvCache, mvAt, mvWorld = r, os.clock(), w
    return r
end
local function mapview() return mapviews()[1] end

-- the override struct's member names carry the blueprint's GUID suffixes
local O = {
    priority = "Priority_2_E0B18C1F4F7065861D754CBC1717C0F4",
    rain = "RainAmount_6_1DF01C624F8A4DABBCF2D9B45FEE5251",
    fog = "FogAmount_7_DF39641648DD1C067F04379E79B4AC5F",
    wind = "WindAmount_11_AA5396694831838AD8399192FA714B4C",
    dark = "DarknessAmount_12_C1E6970E406443EC371A029B6E403FA3",
    storm = "ZoneStormAmount_29_0E19DE884D969BB97E764EBE017A5607",
    acid = "AcidAmount_31_1713ABA54AE616BBBC74EEB59EFF6CF2",
    id = "Identifier_26_37794E45404F7D45933471B6A50F260C",
    speed = "OverrideSpeedMult_34_B5D9F9C34E787BDD5826CA97FDFF7EFA",
}
local LAYERS = { "UVBaseLayerPosition", "UVSecondLayerPosition" }
local OUT = { "TOD_Override_Rain_Current", "TOD_Override_Fog_Current", "TOD_Override_Wind_Current", "TOD_Override_Darkness_Current",
    "TOD Override Zone Storm Current", "TOD Override Acid Current", "TOD_Override_SpeedMult" }

-- host: the sky now, as one W line's fields
local function snapshot()
    local m = manager()
    if not m then return nil end
    local t, p, pr, we, ws = {}, {}, {}, {}, {}
    m["Get Current Time Of Day"](m, t)
    m["Get Target to D Preset"](m, p)
    local o = { {}, {}, {}, {}, {}, {}, {} }
    m["Get Current Weather Override Values"](m, o[1], o[2], o[3], o[4], o[5], o[6], o[7])
    m:GetCurrentPrecipitation(pr) m:GetCurrentWetnessBuildup(we) m:GetCurrentWindSpeed(ws)
    local preset = p["Target TOD Preset"]
    local f = { string.format("%.5f", t["Returned Time Of Day"] or 0), (preset and preset:IsValid()) and short(preset) or "-" }
    for i = 1, 7 do f[#f + 1] = string.format("%.3f", o[i][OUT[i]] or 0) end
    f[#f + 1] = string.format("%.3f", pr.Percipitation or 0)
    f[#f + 1] = string.format("%.3f", we.CurrentWetnessBuildup or 0)
    f[#f + 1] = string.format("%.3f", ws.CurrentWindSpeed or 0)
    local sim = m.ToDSimulationActor
    if sim and sim:IsValid() then
        for _, k in ipairs(LAYERS) do
            local c = sim[k]
            f[#f + 1] = string.format("%.5f,%.5f,%.5f,%.5f", c.R, c.G, c.B, c.A)
        end
    else
        f[#f + 1], f[#f + 1] = "-", "-"
    end
    -- the north: random?, its pick's yaw, the yaw in use
    f[#f + 1] = string.format("%d,%.1f,%.1f", m.DataBlock_IsUsingRandomNorth and 1 or 0, m.DataBlock_PickedRandomNorth.Yaw,
        m["Current North As Rotator"].Yaw)
    -- the ARC map's view and the world it is in (owner's alpha 21 test: the ARC maps turned 90 degrees between the
    -- two): BP_GobblerMapview_C takes its yaw from the north once, when it spawns (Rocky_07: north 180, yaw -90) - a
    -- north set afterwards leaves it as it was; and a line from the host's next zone must not turn the guest's
    local mv = mapview()
    f[#f + 1] = mv and string.format("%.1f", mv:K2_GetActorRotation().Yaw) or "-"
    f[#f + 1] = worldName() or "-"
    return table.concat(f, "\t")
end

local function hookEvents()
    CoopSyncWeatherHooks = CoopSyncWeatherHooks or {}
    CoopSyncWeatherHooks.notify = function(tag, fields) if role == "host" then Players.send(tag, fields) st.events = st.events + 1 end end
    if CoopSyncWeatherHooks.done then return end
    CoopSyncWeatherHooks.done = true
    Hook(FN .. "StartTODEvent", function() end, function(_, ev)
        local ok, path = pcall(function() local c = ev:get() return c and c:IsValid() and short(c) or nil end)
        if ok and path then CoopSyncWeatherHooks.notify("WE", path) end
    end)
    for _, fn in ipairs({ "ClearCurrentTODEvent", "OnTODEventEnded" }) do
        Hook(FN .. fn, function() end, function() CoopSyncWeatherHooks.notify("WC", "") end)
    end
end

local assetCache = {}
local function asset(path)
    local a = assetCache[path]
    if a == nil then
        a = SFO(path)
        if not (a and a:IsValid()) then pcall(function() LoadAsset(path) end) a = SFO(path) end
        a = (a and a:IsValid()) and a or false
        assetCache[path] = a
    end
    return a or nil
end

-- guest: a line from the host
function M.apply(t)
    local m = manager()
    if not m then return end
    if t[1] == "WE" then
        local cls = asset(t[3])
        local d = director()
        if cls and d then d:StartTODEvent(cls) st.events = st.events + 1 end
        return
    elseif t[1] == "WC" then
        local d = director()
        if d then d:ClearCurrentTODEvent() st.events = st.events + 1 end
        return
    end
    local tod = tonumber(t[3])
    if tod then
        local cur = {}
        m["Get Current Time Of Day"](m, cur)
        local now = cur["Returned Time Of Day"] or 0
        local d = math.abs(now - tod)
        if math.min(d, 1 - d) > TOD_DRIFT then m["Set Current Time Of Day"](m, tod) st.todSets = st.todSets + 1 end
    end
    if t[4] and t[4] ~= "-" and t[4] ~= lastPreset then
        local cls = asset(t[4])
        if cls then m["Set New TOD Target"](m, cls) lastPreset = t[4] end
    end
    local v = {}
    for i = 5, 11 do v[#v + 1] = tonumber(t[i]) or 0 end
    local ov = { [O.priority] = 1000, [O.rain] = v[1], [O.fog] = v[2], [O.wind] = v[3], [O.dark] = v[4], [O.storm] = v[5],
        [O.acid] = v[6], [O.id] = FName(OVERRIDE_TAG), [O.speed] = v[7] }
    m:QuickSetWeatherOverrideAndCurrent(ov)
    if tonumber(t[12]) then m:SetCurrentPrecipitation(tonumber(t[12])) end
    if tonumber(t[13]) then m:SetCurrentWetnessBuildup(tonumber(t[13])) end
    if tonumber(t[14]) then m:SetCurrentWindSpeed(tonumber(t[14])) end
    local sim = m.ToDSimulationActor
    if t[15] and sim and sim:IsValid() then
        for i, k in ipairs(LAYERS) do
            local r, g, b, a = (t[14 + i] or ""):match("^([^,]+),([^,]+),([^,]+),([^,]+)$")
            if a then sim[k] = { R = tonumber(r), G = tonumber(g), B = tonumber(b), A = tonumber(a) } end
        end
        st.clouds = (st.clouds or 0) + 1
    end
    local rnd, pick, yaw = (t[17] or ""):match("^(%d),([-%d.]+),([-%d.]+)$")
    -- (a line from another world - the host already in its next zone - leaves the north and the ARC map alone)
    if t[19] and t[19] ~= "-" and t[19] ~= worldName() then st.applied = st.applied + 1 return end
    local before = m["Current North As Rotator"].Yaw
    if rnd and math.abs((before - tonumber(yaw) + 180) % 360 - 180) > 0.5 then
        m.DataBlock_IsUsingRandomNorth = rnd == "1"
        m.DataBlock_PickedRandomNorth = { Pitch = 0, Yaw = tonumber(pick), Roll = 0 }
        if rnd == "1" then
            m:RandomizeNorth(true)
        else
            local y = math.rad(tonumber(yaw))
            m:SetTrueNorth({ X = math.cos(y), Y = math.sin(y), Z = 0 }, { Pitch = 0, Yaw = tonumber(yaw), Roll = 0 })
            if sim and sim:IsValid() then sim:K2_SetActorRotation({ Pitch = 0, Yaw = tonumber(yaw), Roll = 0 }, false) end
        end
        st.north = (st.north or 0) + 1
        -- (into the report: owner's alpha 21 test, the ARC map turned 90 degrees between the two)
        if CoopSyncHitch and (st.north <= 5 or st.north % 20 == 0) then
            CoopSyncHitch.note(string.format("north %d: %.1f -> host %s (random %s, pick %s), now %.1f", st.north, before, yaw, rnd, pick,
                m["Current North As Rotator"].Yaw))
        end
    end
    local mvYaw = tonumber(t[18])
    if mvYaw then
        for _, mv in ipairs(mapviews()) do
            local y = mv:K2_GetActorRotation().Yaw
            if math.abs((y - mvYaw + 180) % 360 - 180) > 0.5 then
                mv:K2_SetActorRotation({ Pitch = 0, Yaw = mvYaw, Roll = 0 }, false)
                st.mapview = (st.mapview or 0) + 1
                if CoopSyncHitch and st.mapview <= 5 then CoopSyncHitch.note(string.format("ARC map view %d: %.1f -> host %.1f", st.mapview, y, mvYaw)) end
            end
        end
    end
    st.applied = st.applied + 1
end

function M.start(playersModule, r)
    Players, role = playersModule, r
    st = { sent = 0, applied = 0, events = 0, todSets = 0, errors = {} }
    lastPreset = nil
    local ok, e = pcall(hookEvents)
    if not ok then err("hooks: " .. tostring(e)) end
    if role == "client" then
        -- the guest's own events would start their own rain: only the host's run
        pcall(function() director():ToggleWeatherEventsPaused(true, true) end)
        Players.onWeather = function(t)
            local okA, eA = pcall(M.apply, t)
            if not okA then err("apply: " .. tostring(eA)) end
        end
        return "weather: following the host"
    end
    -- one sender: a restart (resync, restart from the debug menu) ends the earlier loop by its generation
    M.gen = (M.gen or 0) + 1
    local gen = M.gen
    loop(SEND_MS, function()
        if Players.stopped or gen ~= M.gen then return true end
        local okS, f = pcall(snapshot)
        if okS and f then
            if Players.send("W", f) then st.sent = st.sent + 1 end
        elseif not okS then err("snapshot: " .. tostring(f)) end
    end)
    return "weather: host sends"
end

-- the guest's own sky back (session over, single player): its events run again, our override goes
function M.release()
    pcall(function() director():ToggleWeatherEventsPaused(false, false) end)
    pcall(function() manager():RemoveTODWeatherOverride(FName(OVERRIDE_TAG)) end)
    -- (and its own gameplay events: statesync's CoopSyncEvent held its director off while it followed the host's)
    pcall(function() FindFirstOf("BP_GameplayEventDirector_C").ForceNoEvents = false end)
    if Players then Players.onWeather = nil end
end

-- for the session's status line: lines sent (host) / applied (guest)
function M.short()
    -- (and the north in use here, with how many times the guest set the host's: "sent/applied/<yaw>:<sets>")
    local ok, y = pcall(function() return manager()["Current North As Rotator"].Yaw end)
    return string.format("%d/%d/%s:%d", st.sent, st.applied, ok and string.format("%.0f", y) or "-", st.north or 0)
end

function M.info()
    local ok, snap = pcall(snapshot)
    return string.format("role=%s sent=%d applied=%d events=%d tod_sets=%d clouds=%d north=%d errors=%d now=%s %s", tostring(role), st.sent, st.applied,
        st.events, st.todSets, st.clouds or 0, st.north or 0, #st.errors, ok and tostring(snap):gsub("\t", ",") or "?", table.concat(st.errors, "; "))
end

return M
