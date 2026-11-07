-- Every live car of this world with what the owner saw differ (alpha 18 items 21, 25, 26, 27): the wiper timeline,
-- the part actors hanging on it (by class), its place. Works from the dev mod's state (no mod globals).
-- "<name>@x,y,z wipers=<pos> parts=<n> doors=<n> | ..."
local out = {}
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
    pcall(function()
        local r = c.RootComponent
        if not (c:IsValid() and r and r:IsValid()) then return end
        local l = c:K2_GetActorLocation()
        if l.X == 0 and l.Y == 0 and l.Z == 0 then return end
        local wt = -1
        pcall(function() wt = c.Timeline_wiperblade:GetPlaybackPosition() end)
        local parts, doors = 0, 0
        local att = {}
        pcall(function() c:GetAttachedActors(att, true) end)
        for _, a in ipairs(att) do
            local x = a.get and a:get() or a
            if x and x:IsValid() then
                parts = parts + 1
                if x:GetClass():GetFName():ToString():find("Door", 1, true) then doors = doors + 1 end
            end
        end
        out[#out + 1] = string.format("%s@%.0f,%.0f,%.0f wipers=%.2f parts=%d doors=%d", c:GetFName():ToString(), l.X, l.Y, l.Z, wt, parts, doors)
    end)
end
return table.concat(out, " | ")
