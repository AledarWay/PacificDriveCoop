-- Cars of this world (owner's alpha 17 / 18 tests: the guest had its own car TWICE, a hood floated by the host's car):
-- every BP_PlayerCarNew_C of the player's level (own / twin, where), and car parts lying loose near them.
-- Returns "own=<n> twin=<n> loose=<n> cars=<kind@x,y,z;...> parts=<class@dist;...>".
local pawn = FindFirstOf("PlayerController").Pawn
local lvl = pawn:GetFullName():match("^%S+%s+(.-:PersistentLevel)%.")
-- (twins: twincar.lua's CoopSyncTwins, by address - only where this runs in the mod's own Lua state; from the dev
-- mod's state the twins count as "own": tests take the mod's twin count from status.txt, twins=)
local twins = _G.CoopSyncTwins or {}
-- (a destroyed actor waits for the GC for minutes and is still IsValid() - to KismetSystemLibrary too; it has no root
-- component any more: a removed twin read as a car at 0,0,0, its parts as loose parts there)
local function live(a)
    if not a:IsValid() then return false end
    local r = a.RootComponent
    if not (r ~= nil and r:IsValid()) then return false end
    -- (the root field may still read valid: the place is exactly 0,0,0 then)
    local l = a:K2_GetActorLocation()
    return l.X ~= 0 or l.Y ~= 0 or l.Z ~= 0
end
local own, twin, list, cars = 0, 0, {}, {}
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
    if live(c) and lvl and c:GetFullName():find(lvl, 1, true) and not c:IsActorBeingDestroyed() then
        local tw = twins[c:GetAddress()] ~= nil
        if tw then twin = twin + 1 else own = own + 1 end
        local l = c:K2_GetActorLocation()
        cars[#cars + 1] = l
        list[#list + 1] = string.format("%s:%s@%.0f,%.0f,%.0f", tw and "twin" or "own", c:GetFName():ToString(), l.X, l.Y, l.Z)
    end
end
-- loose parts: car part actors with no parent, within 15 m of a car (a hood / door that came off and floats or lies)
local loose, parts = 0, {}
local seen = {}
for _, cls in ipairs({ "BP_Manifestation_CarEquipment_C", "BP_CarPart_Door_Base_C", "BP_CarPart_Interactive_C" }) do
    for _, p in ipairs(FindAllOf(cls) or {}) do
        local ok = pcall(function()
            if not (live(p) and p:GetFullName():find(lvl, 1, true)) or seen[p:GetAddress()] then return end
            seen[p:GetAddress()] = true
            local par = p:GetAttachParentActor()
            if par and par:IsValid() then return end
            local l = p:K2_GetActorLocation()
            for _, c in ipairs(cars) do
                local d = math.sqrt((l.X - c.X) ^ 2 + (l.Y - c.Y) ^ 2 + (l.Z - c.Z) ^ 2)
                if d < 1500 then
                    loose = loose + 1
                    parts[#parts + 1] = string.format("%s@%.0f", p:GetClass():GetFName():ToString(), d)
                    break
                end
            end
        end)
    end
end
return string.format("own=%d twin=%d loose=%d cars=%s parts=%s", own, twin, loose, table.concat(list, ";"), #parts > 0 and table.concat(parts, ";") or "-")
