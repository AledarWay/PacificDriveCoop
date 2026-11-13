-- What the game spawns by itself over time (the guest's own sites after a zone-save load, 2026-11-13).
--   NA_OP = 'snap'  remember every actor now
--   NA_OP = 'diff'  the actors new since the snap: count by class, and for the first NA_SHOW of NA_CLASS (a pattern)
--                   their spot, owner, outer and the nearest new actors of other classes
local op = NA_OP or "diff"
local function all()
    local t = {}
    for _, a in ipairs(FindAllOf("Actor") or {}) do
        local ok, n = pcall(function() return a:GetFullName() end)
        if ok and n then t[n] = a end
    end
    return t
end
if op == "snap" then
    NA_SNAP = {}
    local n = 0
    for k in pairs(all()) do NA_SNAP[k] = true n = n + 1 end
    NA_SNAP_AT = os.clock()
    return "snap " .. n
end
local now, new, by = all(), {}, {}
for k, a in pairs(now) do
    if not (NA_SNAP or {})[k] then
        local c = k:match("^(%S+)") or "?"
        by[c] = (by[c] or 0) + 1
        new[#new + 1] = { k = k, a = a, c = c }
    end
end
local rows = {}
for c, n in pairs(by) do rows[#rows + 1] = { c, n } end
table.sort(rows, function(x, y) return x[2] > y[2] end)
local out = { string.format("%.0f s after the snap, %d new actors", os.clock() - (NA_SNAP_AT or 0), #new) }
for i = 1, math.min(#rows, 40) do out[#out + 1] = rows[i][2] .. " " .. rows[i][1] end
local pat, shown = NA_CLASS or "Lootable", 0
for _, x in ipairs(new) do
    if shown < (NA_SHOW or 4) and x.k:find(pat) then
        shown = shown + 1
        local l = { X = 0, Y = 0, Z = 0 }
        pcall(function() l = x.a:K2_GetActorLocation() end)
        local own, att = "-", "-"
        pcall(function() local o = x.a:GetOwner() if o and o:IsValid() then own = o:GetFullName() end end)
        pcall(function() local o = x.a:GetAttachParentActor() if o and o:IsValid() then att = o:GetFullName() end end)
        out[#out + 1] = string.format("== %s at %.0f,%.0f,%.0f owner=%s attach=%s", x.k, l.X, l.Y, l.Z, own, att)
        local near = {}
        for _, y in ipairs(new) do
            if y ~= x then
                local m
                pcall(function() m = y.a:K2_GetActorLocation() end)
                if m then
                    local d = math.sqrt((m.X - l.X) ^ 2 + (m.Y - l.Y) ^ 2 + (m.Z - l.Z) ^ 2)
                    if d < 3000 then near[#near + 1] = { d, y.c } end
                end
            end
        end
        table.sort(near, function(p, q) return p[1] < q[1] end)
        local s = {}
        for i = 1, math.min(#near, 25) do s[#s + 1] = string.format("%s@%.0f", near[i][2], near[i][1]) end
        out[#out + 1] = "   near new: " .. table.concat(s, " ")
        -- old (pre-snap) actors close by: the spawner that may have built it
        local olds = {}
        for k, a in pairs(now) do
            if (NA_SNAP or {})[k] and (k:find("Spawn") or k:find("Prefab") or k:find("Site") or k:find("Building")) then
                local m
                pcall(function() m = a:K2_GetActorLocation() end)
                if m then
                    local d = math.sqrt((m.X - l.X) ^ 2 + (m.Y - l.Y) ^ 2 + (m.Z - l.Z) ^ 2)
                    if d < 2500 then olds[#olds + 1] = { d, k:match("^%S+%s+%S-([^%.:]+)$") or k } end
                end
            end
        end
        table.sort(olds, function(p, q) return p[1] < q[1] end)
        s = {}
        for i = 1, math.min(#olds, 12) do s[#s + 1] = string.format("%s@%.0f", olds[i][2], olds[i][1]) end
        out[#out + 1] = "   old spawners near: " .. table.concat(s, " ")
    end
end
return table.concat(out, "\n")
