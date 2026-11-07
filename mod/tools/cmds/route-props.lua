-- Reflection dump of the route model in the garage: properties of the main BaseRouteState, one BaseLegState and
-- (ROUTE_PROPS_CLASS) any other class by short name - name, type and a short value.
local function path(o)
    if not (o and o.IsValid and o:IsValid()) then return "nil" end
    local ok, s = pcall(function() return o:GetFullName() end)
    return ok and (s:gsub("^%S+%s+", "")) or "?"
end
local function short(v)
    local t = type(v)
    if t == "number" or t == "boolean" or t == "string" then return tostring(v) end
    if t == "userdata" then
        local ok, s = pcall(function() return v:ToString() end)
        if ok and type(s) == "string" then return s end
        ok, s = pcall(function() return path(v) end)
        if ok and s ~= "nil" and s ~= "?" then return s end
        ok, s = pcall(function() return "#" .. tostring(#v) end)
        if ok then return s end
    end
    return t
end
local out = {}
local function dump(obj, label)
    out[#out + 1] = "== " .. label .. " " .. path(obj)
    local cls = obj:GetClass()
    while cls and cls:IsValid() do
        local cn = cls:GetFName():ToString()
        cls:ForEachProperty(function(p)
            local name = p:GetFName():ToString()
            local okT, ty = pcall(function() return p:GetClass():GetFName():ToString() end)
            local okV, v = pcall(function() return obj[name] end)
            out[#out + 1] = string.format("  %s.%s : %s = %s", cn, name, okT and ty or "?", okV and short(v) or "ERR")
        end)
        local ok, sup = pcall(function() return cls:GetSuperStruct() end)
        if not ok or not sup or not sup:IsValid() then break end
        cls = sup
        if cn == "Object" then break end
    end
end
if not ROUTE_PROPS_ONLY then
local pm = FindFirstOf("BP_ProgressionManager_C")
dump(pm, "PROGRESSION")
local main, exped, nEx = nil, nil, 0
for _, r in ipairs(FindAllOf("BaseRouteState") or {}) do
    local n = r:GetFullName()
    if n:find("BP_ProgressionManager_C", 1, true) and not main then main = r end
    if n:find("Expedition", 1, true) then nEx = nEx + 1 exped = exped or r end
end
out[#out + 1] = "expedition route states: " .. nEx
for _, pair in ipairs({ { main, "ROUTE" }, { exped, "EXPEDITION" } }) do
    local rs = pair[1]
    if rs and rs:IsValid() then
        dump(rs, pair[2])
        local leg
        pcall(function() leg = rs.CurrentLeg end)
        if leg and leg:IsValid() then dump(leg, pair[2] .. " CURRENT LEG") end
        local n, picked = 0, nil
        pcall(function() rs.LegStates:ForEach(function(i, l) n = n + 1 if n == 2 then picked = l:get() end end) end)
        if picked and picked:IsValid() then dump(picked, pair[2] .. " LEG #2") end
    end
end
end
ROUTE_PROPS_CLASS = ROUTE_PROPS_CLASS or ROUTE_PROPS_ONLY
if ROUTE_PROPS_CLASS then
    local o = FindFirstOf(ROUTE_PROPS_CLASS)
    if o and o:IsValid() then dump(o, ROUTE_PROPS_CLASS) else out[#out + 1] = "no " .. ROUTE_PROPS_CLASS end
end
return table.concat(out, "\n")
