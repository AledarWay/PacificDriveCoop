-- Micro-benchmark of the building blocks of a sync tick (ms). Run on a host in a zone.
CoopSync = CoopSync or dofile('C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua')
local function ms(f, n)
    n = n or 1
    local t0 = os.clock()
    local r
    for _ = 1, n do r = f() end
    return (os.clock() - t0) * 1000 / n, r
end
local out = {}
local function add(name, v, extra) out[#out + 1] = string.format("%s=%.2f%s", name, v, extra and (" (" .. extra .. ")") or "") end

local tA, actors = ms(function() return FindAllOf("Actor") end)
add("FindAllOf_Actor", tA, #actors .. " objects")
local tI, items = ms(function() return FindAllOf("ItemContainer") end)
add("FindAllOf_ItemContainer", tI, #(items or {}) .. "")
local tP, parts = ms(function() return FindAllOf("LootableTemplatePart") end)
add("FindAllOf_TemplatePart", tP, #(parts or {}) .. "")
local tC, list = ms(function() return CoopSync.collect() end)
add("collect_total", tC, #list .. " roots")
add("collect_filtering", tC - tA)
local p = CoopSync.ref(list[1])
local tS = ms(function() return StaticFindObject(p) end, 20)
add("StaticFindObject_each", tS)
local tL = ms(function() for _, a in ipairs(list) do a:K2_GetActorLocation() end end)
add("GetLocation_all_roots", tL)
local tN = ms(function() for _, a in ipairs(list) do a:GetFullName() end end)
add("GetFullName_all_roots", tN)
local tPre = ms(function() CoopSync.Loot.beginPass() end)
add("loot_beginPass", tPre)
local tSer = ms(function() for _, a in ipairs(list) do CoopSync.Loot.serialize(a) end end)
CoopSync.Loot.endPass()
add("loot_serialize_all", tSer)
-- per actor filter costs
local a = actors[1]
add("IsValid_x1000", ms(function() for _ = 1, 1000 do a:IsValid() end end))
add("GetClass_GetFName_x1000", ms(function() for _ = 1, 1000 do a:GetClass():GetFName():ToString() end end))
add("GetFullName_x1000", ms(function() for _ = 1, 1000 do a:GetFullName() end end))
return table.concat(out, " | ")
