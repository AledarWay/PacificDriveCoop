-- Snapshot / diff of everything the garage map could keep a selection in: every leg's scalar fields, the route
-- state's and progression manager's scalars, the route display / cursor widgets' fields.
-- MAP_DIFF = "snap" stores a snapshot (global), "diff" prints what changed since.
local function str(v)
    local t = type(v)
    if t ~= "userdata" then return tostring(v) end
    local ok, s = pcall(function() return v:GetFullName() end)
    if ok and type(s) == "string" then return (s:match("[^%.:]+$")) end
    ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" then return s end
    ok, s = pcall(function() return "#" .. #v end)
    return ok and s or "ud"
end
local function fields(o, prefix, into, stopAt)
    if not (o and o:IsValid()) then return end
    local cls = o:GetClass()
    while cls and cls:IsValid() do
        local cn = cls:GetFName():ToString()
        if cn == stopAt then break end
        cls:ForEachProperty(function(p)
            local n = p:GetFName():ToString()
            local ty = p:GetClass():GetFName():ToString()
            if not ty:find("Delegate") and n ~= "UberGraphFrame" then
                local ok, v = pcall(function() return o[n] end)
                into[prefix .. n] = ok and str(v) or "ERR"
            end
        end)
        cls = cls:GetSuperStruct()
    end
end
local snap = {}
local main
for _, r in ipairs(FindAllOf("BaseRouteState") or {}) do if r:GetFullName():find("BP_ProgressionManager_C", 1, true) then main = r break end end
fields(main, "route.", snap, "Object")
main.LegStates:ForEach(function(k, v) fields(v:get(), k:get():GetFName():ToString() .. ".", snap, "Object") end)
fields(FindFirstOf("BP_ProgressionManager_C"), "pm.", snap, "BaseManager")
fields(FindFirstOf("UMG_RouteDisplay_Main_C"), "disp.", snap, "UserWidget")
fields(FindFirstOf("UMG_RouteShape_Cursor_C"), "cursor.", snap, "UserWidget")
fields(FindFirstOf("BP_ChartManager_C"), "chart.", snap, "Object")
if MAP_DIFF == "snap" then
    MapDiffSnap = snap
    local n = 0 for _ in pairs(snap) do n = n + 1 end
    return "snapshot: " .. n .. " fields"
end
local out = {}
for k, v in pairs(snap) do
    local was = MapDiffSnap and MapDiffSnap[k]
    if was ~= v then out[#out + 1] = k .. ": " .. tostring(was) .. " -> " .. v end
end
for k, v in pairs(MapDiffSnap or {}) do if snap[k] == nil then out[#out + 1] = k .. ": " .. v .. " -> (gone)" end end
table.sort(out)
return #out .. " changed\n" .. table.concat(out, "\n")
