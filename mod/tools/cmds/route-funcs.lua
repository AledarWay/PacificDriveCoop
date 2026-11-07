-- UFunctions of the route / leg / progression / planner classes (names + params), to find selection and refresh.
-- ROUTE_FUNCS_FILTER: optional Lua pattern on the function name.
local classes = {
    "/Game/Systems/Routes/States/BP_RouteStateBase.BP_RouteStateBase_C",
    "/Game/Systems/Routes/States/BP_LegStateBase.BP_LegStateBase_C",
    "/Script/PenDriverPro.BaseRouteState",
    "/Script/PenDriverPro.BaseLegState",
    "/Game/Systems/Managers/BP_ProgressionManager.BP_ProgressionManager_C",
    "/Script/PenDriverPro.BaseProgressionManager",
}
for _, extra in ipairs(ROUTE_FUNCS_CLASSES or {}) do classes[#classes + 1] = extra end
local out = {}
for _, cp in ipairs(classes) do
    local c = StaticFindObject(cp)
    if c and c:IsValid() then
        local names = {}
        c:ForEachFunction(function(f)
            local n = f:GetFName():ToString()
            if not ROUTE_FUNCS_FILTER or n:find(ROUTE_FUNCS_FILTER) then
                local ps = {}
                pcall(function() f:ForEachProperty(function(p) ps[#ps + 1] = p:GetFName():ToString() end) end)
                names[#names + 1] = ROUTE_FUNCS_FILTER and (n .. "(" .. table.concat(ps, ",") .. ")") or n
            end
        end)
        table.sort(names)
        out[#out + 1] = "== " .. cp:match("[^%.]+$") .. " (" .. #names .. "): " .. table.concat(names, "  ")
    else
        out[#out + 1] = "== missing " .. cp
    end
end
return table.concat(out, "\n")
