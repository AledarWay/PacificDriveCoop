-- Hazards in the current zone: classes with counts, and per class (and its Blueprint supers up to BP_Base_Hazard)
-- the functions / properties that look like targeting (player, car, target, chase, attack, aggro, range, pawn).
-- Anomaly sync: how each hazard picks whom to go after.
local counts, sample = {}, {}
for _, a in ipairs(FindAllOf("Actor") or {}) do
    local ok, c = pcall(function() return a:GetClass():GetFName():ToString() end)
    if ok and c and (c:find("^BP_Hazard") or c:find("Hazard") or c:find("Anomal")) then
        counts[c] = (counts[c] or 0) + 1
        sample[c] = sample[c] or a
    end
end
local pat = { "player", "car", "target", "chase", "attack", "aggro", "range", "pawn", "victim", "latch", "grab",
    "detect", "sense", "notice", "hunt", "follow", "lock" }
local function hit(n)
    local l = n:lower()
    for _, p in ipairs(pat) do if l:find(p, 1, true) then return true end end
end
local names = {}
for c in pairs(counts) do names[#names + 1] = c end
table.sort(names)
local out = {}
for _, c in ipairs(names) do
    out[#out + 1] = string.format("%s x%d", c, counts[c])
end
out[#out + 1] = ""
local seen = {}
for _, c in ipairs(names) do
    local cls = sample[c]:GetClass()
    local guard = 0
    while cls and cls:IsValid() and guard < 6 do
        local cn = cls:GetFName():ToString()
        if seen[cn] or cn == "Actor" then break end
        seen[cn] = true
        local fn, props = {}, {}
        pcall(function() cls:ForEachFunction(function(f) local n = f:GetFName():ToString() if hit(n) then fn[#fn + 1] = n end end) end)
        pcall(function() cls:ForEachProperty(function(p) local n = p:GetFName():ToString() if hit(n) then props[#props + 1] = n end end) end)
        out[#out + 1] = string.format("== %s\n  fn: %s\n  props: %s", cn, table.concat(fn, " | "), table.concat(props, " | "))
        local ok, sup = pcall(function() return cls:GetSuperStruct() end)
        if not ok or not sup or not sup:IsValid() then break end
        cls = sup
        guard = guard + 1
    end
end
return table.concat(out, "\n")
