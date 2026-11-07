-- Route / leg / map-location state (what decides which zone map TravelToNextLeg loads).
-- ROUTE_PROBE_STAGE: "dump" (default) route states + current leg; "maps" loaded MapLocation assets.
local function nm(o)
    if not (o and o.IsValid and o:IsValid()) then return "nil" end
    local ok, s = pcall(function() return o:GetFullName() end)
    return ok and s or "?"
end
local function path(o)
    local s = nm(o)
    return (s:gsub("^%S+%s+", ""))
end
local function soft(sp)
    local ok, s = pcall(function() return sp.AssetPathName:ToString() .. (sp.SubPathString and sp.SubPathString:ToString() or "") end)
    if ok then return s end
    ok, s = pcall(function() return tostring(sp:ToString()) end)
    return ok and s or "?"
end
local function legInfo(leg)
    if not (leg and leg:IsValid()) then return "leg=nil" end
    local r = { "leg=" .. path(leg) }
    pcall(function()
        local ml = leg.MapLocation
        r[#r + 1] = "map=" .. path(ml)
        if ml and ml:IsValid() then r[#r + 1] = "level=" .. soft(ml.LevelAsset) end
    end)
    pcall(function() r[#r + 1] = "route=" .. path(leg.DestinationRoute) end)
    pcall(function() r[#r + 1] = "override=" .. tostring(leg.bOverrideRoute) .. ":" .. path(leg.OverrideRoute) end)
    pcall(function() r[#r + 1] = "shape=" .. path(leg.ShapeLeg) end)
    pcall(function() r[#r + 1] = "forcedNext=" .. path(leg.ForcedNextState) end)
    pcall(function() r[#r + 1] = "instance=" .. path(leg.LegInstance) end)
    pcall(function() r[#r + 1] = "archOverride=" .. path(leg.LegArchetypeOverride) end)
    pcall(function()
        local mods = {}
        for i = 1, #leg.AppliedModifiers do mods[#mods + 1] = path(leg.AppliedModifiers[i]) end
        r[#r + 1] = "mods=[" .. table.concat(mods, ",") .. "]"
    end)
    pcall(function() r[#r + 1] = string.format("active=%s visited=%s discovered=%s reveal=%s", tostring(leg.Active), tostring(leg.Visited), tostring(leg.Discovered), tostring(leg.RevealState)) end)
    return table.concat(r, " ")
end

local stage = ROUTE_PROBE_STAGE or "dump"
local out = {}
local gi = FindFirstOf("DrivingGameInstance")
pcall(function() out[#out + 1] = "world=" .. FindFirstOf("World"):GetFName():ToString() .. " seed=" .. tostring(gi:GetMasterSeed()) end)
if stage == "dump" then
    for _, rs in ipairs(FindAllOf("BaseRouteState") or {}) do
        if rs:IsValid() and not nm(rs):find("Default__", 1, true) then
            local n = 0
            pcall(function() rs.LegStates:ForEach(function() n = n + 1 end) end)
            out[#out + 1] = string.format("ROUTE %s phase=%s legs=%d shape=%s randSeed=%s", path(rs), tostring(rs.CurrentPhase), n, path(rs.WorldShape), tostring(rs.WorldShapeRandSeed))
            out[#out + 1] = "  current: " .. legInfo(rs.CurrentLeg)
        end
    end
    local nLeg = 0
    for _, l in ipairs(FindAllOf("BaseLegState") or {}) do
        if l:IsValid() and not nm(l):find("Default__", 1, true) then
            nLeg = nLeg + 1
            local ok, active = pcall(function() return l.Active end)
            if ok and active and nLeg <= 40 then out[#out + 1] = "  active leg: " .. legInfo(l) end
        end
    end
    out[#out + 1] = "leg states: " .. nLeg
    pcall(function()
        local cm = FindFirstOf("BP_ChartManager_C")
        local o = {}
        cm:GetActiveLegChart(o)
        out[#out + 1] = "active leg chart: " .. path(o.LegInstance or o["Leg Instance"])
    end)
elseif stage == "maps" then
    local n = 0
    for _, ml in ipairs(FindAllOf("MapLocation") or {}) do
        if ml:IsValid() and not nm(ml):find("Default__", 1, true) then
            n = n + 1
            local okL, lvl = pcall(function() return soft(ml.LevelAsset) end)
            local okV, vis = pcall(function() return ml.Visited end)
            out[#out + 1] = string.format("MAP %s level=%s visited=%s", path(ml), okL and lvl or "?", tostring(okV and vis))
        end
    end
    out[#out + 1] = "map locations: " .. n
end
return table.concat(out, "\n")
