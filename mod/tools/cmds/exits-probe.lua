-- Zone exits: junction gates (BP_LevelTransition_EnterExit_C) and exit portals (BP_LevelTransition_ExitPortal_C)
-- with their flags and distance to the car. EXITS_GO = "gate" calls DoLevelTransition on the nearest active
-- exit gate (what driving through it ends in).
local car
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
    if c:IsValid() and c:GetFullName():find(":PersistentLevel.", 1, true) then car = c end
end
local cl = car and car:K2_GetActorLocation() or { X = 0, Y = 0, Z = 0 }
local function dist(a) local l = a:K2_GetActorLocation() return math.sqrt((l.X - cl.X) ^ 2 + (l.Y - cl.Y) ^ 2) end
local function flag(a, f) local ok, v = pcall(function() return a[f] end) return ok and tostring(v) or "?" end
local out, gates = {}, {}
for _, a in ipairs(FindAllOf("BP_LevelTransition_EnterExit_C") or {}) do
    if CoopSyncUsable(a) and a:GetFullName():find(":PersistentLevel.", 1, true) then
        gates[#gates + 1] = a
        out[#out + 1] = string.format("GATE %s d=%.0f exit=%s entrance=%s closed=%s canEmbark=%s autoAdvance=%s separate=%s",
            a:GetFName():ToString(), dist(a), flag(a, "ExitActive"), flag(a, "EntranceActive"), flag(a, "Closed Visible"),
            flag(a, "Can Embark"), flag(a, "AutomaticLevelAdvance"), flag(a, "SeparatePlayerFromCar"))
    end
end
for _, a in ipairs(FindAllOf("BP_LevelTransition_ExitPortal_C") or {}) do
    if CoopSyncUsable(a) and a:GetFullName():find(":PersistentLevel.", 1, true) then
        out[#out + 1] = string.format("PORTAL %s d=%.0f active=%s dbActive=%s opened=%s picked=%s",
            a:GetFName():ToString(), dist(a), flag(a, "Active"), flag(a, "DataBlock_IsActive"), flag(a, "DataBlock_IsOpened"), flag(a, "IsPickedExit"))
    end
end
if EXITS_GO == "setgate" then
    -- open the first non-entrance gate as an exit (what the ARC exit choice does), then drive through
    for _, g in ipairs(gates) do
        local okE, ent = pcall(function() return g.EntranceActive end)
        if okE and not ent then
            local ok1, e1 = pcall(function() g:SetExit(0) end)
            out[#out + 1] = "SetExit(0) on " .. g:GetFName():ToString() .. ": " .. tostring(ok1) .. " " .. tostring(e1 or "") .. " -> exit=" .. flag(g, "ExitActive")
            local ok2, e2 = pcall(function() g:DoLevelTransition() end)
            out[#out + 1] = "DoLevelTransition: " .. tostring(ok2) .. " " .. tostring(e2 or "")
            break
        end
    end
elseif EXITS_GO == "portal" then
    for _, p in ipairs(FindAllOf("BP_LevelTransition_ExitPortal_C") or {}) do
        if CoopSyncUsable(p) and p:GetFullName():find(":PersistentLevel.", 1, true) then
            local r = {}
            for _, step in ipairs({ "SetExitPortalActive", "Activate", "PressComplete" }) do
                local ok, e = pcall(function() if step == "SetExitPortalActive" then p:SetExitPortalActive(true) else p[step](p) end end)
                r[#r + 1] = step .. "=" .. tostring(ok) .. (e and (" " .. tostring(e)) or "")
            end
            out[#out + 1] = "portal " .. p:GetFName():ToString() .. ": " .. table.concat(r, ", ") .. " -> active=" .. flag(p, "Active")
            break
        end
    end
elseif EXITS_GO == "nextleg" then
    local h = StaticFindObject("/Game/Systems/ScriptingLibraries/BFL_ProgressionHelpers.Default__BFL_ProgressionHelpers_C")
    local ok, e = pcall(function() h:TravelToNextLeg(FindFirstOf("PlayerController")) end)
    out[#out + 1] = "TravelToNextLeg from the zone: " .. tostring(ok) .. " " .. tostring(e or "")
elseif EXITS_GO == "travelto" then
    -- the run's own route state (the one whose current leg has a map): its active, unvisited legs are where
    -- the car can go next; give the first one a map (EXITS_MAP) and travel there
    local target = EXITS_MAP or "/Game/Maps/Rural/MapLocations/MLoc_Rural_Forest_Farm_Rooster_11.MLoc_Rural_Forest_Farm_Rooster_11"
    local ml = StaticFindObject(target)
    if not (ml and ml:IsValid()) then pcall(function() ml = LoadAsset(target) end) end
    -- one route only: after a leg travel the previous zone's route state lingers with a mapped leg too
    local zrs, zcur = dofile("C:/PacificDriveCoop/mod/CoopSync/Scripts/runsync.lua").zoneRoute()
    for _, rs in ipairs({ zrs }) do
        local cur = zcur
        do
            local cands = {}
            for _, l in ipairs(FindAllOf("BaseLegState") or {}) do
                pcall(function()
                    if l:GetOuter():GetFullName() == rs:GetFullName() and (l.Active or EXITS_ANY_LEG) and not l.Visited and l:GetFullName() ~= cur:GetFullName() then cands[#cands + 1] = l end
                end)
            end
            out[#out + 1] = "run route " .. rs:GetFName():ToString() .. ": " .. #cands .. " active unvisited legs"
            -- prefer a leg that already has a map (a progressed run reveals them); EXITS_MAP = "keep" = no override
            table.sort(cands, function(x, y)
                local okx, mx = pcall(function() return x.MapLocation:IsValid() end)
                local oky, my = pcall(function() return y.MapLocation:IsValid() end)
                return (okx and mx and 1 or 0) > (oky and my and 1 or 0)
            end)
            if cands[1] then
                local l = cands[1]
                if EXITS_MAP ~= "keep" then pcall(function() l:OverrideMapLocation(ml) end) end
                pcall(function() ml = l.MapLocation end)
                local ok, e = pcall(function() rs:TravelTo(l, 0) end)
                out[#out + 1] = "TravelTo(" .. l:GetFName():ToString() .. ", Completed) with map " .. tostring(ml and ml:GetFName():ToString()) .. ": " .. tostring(ok) .. " " .. tostring(e or "")
            end
        end
    end
elseif EXITS_GO == "gate" then
    local best, bd
    for _, g in ipairs(gates) do
        local ok, ex = pcall(function() return g.ExitActive end)
        if ok and ex and (not bd or dist(g) < bd) then best, bd = g, dist(g) end
    end
    if best then
        local ok, e = pcall(function() best:DoLevelTransition() end)
        out[#out + 1] = "DoLevelTransition on " .. best:GetFName():ToString() .. ": " .. tostring(ok) .. " " .. tostring(e or "")
    else
        out[#out + 1] = "no active exit gate"
    end
end
return #out > 0 and table.concat(out, "\n") or "no gates/portals"
