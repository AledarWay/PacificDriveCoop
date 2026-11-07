-- Every actor within NEAR_R (default 600) of NEAR_X, NEAR_Y: class, name, location, attach parent.
CoopSync = CoopSync or dofile("C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua")
local x, y, r = NEAR_X or 0, NEAR_Y or 0, NEAR_R or 600
local out = {}
for _, a in ipairs(FindAllOf("Actor") or {}) do
    if CoopSyncUsable(a) and a:GetFullName():find(":PersistentLevel.", 1, true) then
        local ok, l = pcall(function() return a:K2_GetActorLocation() end)
        if ok and l and math.abs(l.X - x) < r and math.abs(l.Y - y) < r then
            local c = CoopSync.clsName(a)
            if CoopSync.matches(c) or NEAR_ALL then
                local p = CoopSync.parentOf(a)
                out[#out + 1] = string.format("%s %s %.0f,%.0f,%.0f parent=%s", c, a:GetFName():ToString(), l.X, l.Y, l.Z,
                    p and CoopSync.clsName(p) or "-")
            end
        end
    end
end
return #out .. " actors\n" .. table.concat(out, "\n")
