-- Compact dump of every leg of the main route state (the garage map): shape leg key, destination route, map
-- location, modifiers (the map's "conditions"), instability, reveal / discovered / visited, anchors, pools.
local function path(o)
    if not (o and o.IsValid and o:IsValid()) then return "-" end
    local ok, s = pcall(function() return o:GetFullName() end)
    return ok and (s:gsub("^%S+%s+", "")) or "?"
end
local function name(o) return (path(o):match("[^%.:/]+$") or "-") end
local function arr(a, f)
    local r = {}
    pcall(function() for i = 1, #a do local e = a[i] local ok, g = pcall(function() return e:get() end) r[#r + 1] = f(ok and g or e) end end)
    return table.concat(r, ",")
end
local main
for _, r in ipairs(FindAllOf("BaseRouteState") or {}) do
    if r:GetFullName():find("BP_ProgressionManager_C", 1, true) then main = r break end
end
if not main then return "no main route" end
local out = { string.format("route shape=%s seed=%s phase=%s current=%s", name(main.WorldShape), tostring(main.WorldShapeRandSeed),
    tostring(main.CurrentPhase), name(main.CurrentLeg.ShapeLeg)) }
local rows = {}
main.LegStates:ForEach(function(k, v)
    local key, leg = k:get(), v:get()
    local s = string.format("%s route=%s map=%s inst=%s anch=%s rev=%s disc=%s vis=%s act=%s mods=[%s] haz=%d boon=%d ev=%d core=%s",
        name(key), name(leg.DestinationRoute), name(leg.MapLocation), tostring(leg.Instability), tostring(leg.AnchorRequirement),
        tostring(leg.RevealState), tostring(leg.Discovered), tostring(leg.Visited), tostring(leg.Active),
        arr(leg.AppliedModifiers, name), #leg.CurrentHazardPoolClasses, #leg.CurrentBoonPoolClasses, #leg.CurrentGameplayEventPool,
        name(leg.CoreJunctionModifier))
    rows[#rows + 1] = s
end)
table.sort(rows, function(a, b) return (tonumber(a:match("^RouteShapeLeg_(%d+)")) or 0) < (tonumber(b:match("^RouteShapeLeg_(%d+)")) or 0) end)
for _, r in ipairs(rows) do out[#out + 1] = r end
return table.concat(out, "\n")
