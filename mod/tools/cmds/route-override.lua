-- In the garage: make the next leg(s) load a given map. ROUTE_TARGET_MAP = MapLocation object path,
-- e.g. "/Game/Maps/Rural/MapLocations/MLoc_Rural_Forest_Farm_Rooster_11.MLoc_Rural_Forest_Farm_Rooster_11".
local target = ROUTE_TARGET_MAP
if not target then return "ROUTE_TARGET_MAP not set" end
local ml = StaticFindObject(target)
if not (ml and ml:IsValid()) then
    pcall(function() ml = LoadAsset(target) end)
end
if not (ml and ml:IsValid()) then return "map location not found: " .. target end
local out = {}
for _, rs in ipairs(FindAllOf("BaseRouteState") or {}) do
    if rs:IsValid() and not rs:GetFullName():find("Default__", 1, true) then
        local cur = rs.CurrentLeg
        for _, l in ipairs(FindAllOf("BaseLegState") or {}) do
            local ok, info = pcall(function()
                if l:GetOuter():GetFullName() ~= rs:GetFullName() then return nil end
                if not l.Active or l.Visited or (cur and cur:IsValid() and l:GetFullName() == cur:GetFullName()) then return nil end
                l:OverrideMapLocation(ml)
                local now = l.MapLocation
                return l:GetFName():ToString() .. " -> " .. (now and now:IsValid() and now:GetFName():ToString() or "nil")
            end)
            if ok and info then out[#out + 1] = info elseif not ok then out[#out + 1] = "ERR " .. tostring(info) end
        end
    end
end
return "overridden: " .. (#out > 0 and table.concat(out, "; ") or "no leg")
