-- The native fast helpers against the Lua walks, in a zone: the same answers, and how long each takes.
-- Two copies of the modules: one loaded with the native functions hidden (the Lua path), one with them.
local DIR = "C:/PacificDriveCoop/mod/CoopSync/Scripts/"
local hide = { "CoopNative_Find", "CoopNative_OuterMap", "CoopNative_ParentMap", "CoopNative_Under", "CoopNative_TreePaths" }
local saved = {}
for _, k in ipairs(hide) do saved[k] = _G[k] _G[k] = nil end
local L = dofile(DIR .. "spawnsync.lua")
local LG = dofile(DIR .. "carghost.lua")
for _, k in ipairs(hide) do _G[k] = saved[k] end
local Nn = dofile(DIR .. "spawnsync.lua")
local NG = dofile(DIR .. "carghost.lua")
LG.init(L) NG.init(Nn)
local out = { "native=" .. tostring(Nn.native) .. " lua=" .. tostring(L.native) }

local function ms(f, ...)
    local t0 = os.clock()
    local r = table.pack(f(...))
    return (os.clock() - t0) * 1000, table.unpack(r, 1, r.n)
end
local function set(list, key)
    local s, n = {}, 0
    for _, x in ipairs(list) do s[key and key(x) or x] = true n = n + 1 end
    return s, n
end
local function diff(a, b)
    local onlyA, onlyB = 0, 0
    for k in pairs(a) do if not b[k] then onlyA = onlyA + 1 end end
    for k in pairs(b) do if not a[k] then onlyB = onlyB + 1 end end
    return onlyA, onlyB
end
local function line(name, tl, tn, same, extra)
    out[#out + 1] = string.format("%s: Lua %.1f ms | C++ %.1f ms (x%.0f) | %s%s", name, tl, tn, tl / math.max(tn, 0.01), same, extra or "")
end

-- 1. collect
local tl, la = ms(L.collect)
local tn, na = ms(Nn.collect)
local sl, nl = set(la, L.ref)
local sn, nn = set(na, Nn.ref)
local a1, b1 = diff(sl, sn)
line("1. collect", tl, tn, string.format("lua %d c++ %d, only lua %d, only c++ %d", nl, nn, a1, b1))

-- 2. dressing (with each actor's look: the look stays Lua work in both)
tl, la = ms(L.dressing)
tn, na = ms(Nn.dressing)
sl, nl = set(la, function(d) return L.ref(d.a) end)
sn, nn = set(na, function(d) return Nn.ref(d.a) end)
a1, b1 = diff(sl, sn)
line("2. dressing", tl, tn, string.format("lua %d c++ %d, only lua %d, only c++ %d", nl, nn, a1, b1))

-- 3. zoneReady
local tl3, r1, m1, o1 = ms(L.zoneReady)
local tn3, r2, m2, o2 = ms(Nn.zoneReady)
line("3. zoneReady", tl3, tn3, string.format("lua %s/%d/%d c++ %s/%d/%d", tostring(r1), m1, o1, tostring(r2), m2, o2))

-- 4. what hangs under the car (destroyTrees' list, roots included) and carghost descendants
local car = FindFirstOf("BP_CarManager_C").NewCarActor
local full = car:GetFullName()
local cl, cn = {}, {}
tl = ms(L.destroyTrees, { full }, cl)
tn = ms(Nn.destroyTrees, { full }, cn)
sl, nl = set(cl.list) sn, nn = set(cn.list)
a1, b1 = diff(sl, sn)
line("4. tree under the car", tl, tn, string.format("lua %d c++ %d, only lua %d, only c++ %d", nl, nn, a1, b1))
tl, la = ms(LG.descendants, car)
tn, na = ms(NG.descendants, car)
line("   car descendants", tl, tn, string.format("lua %d c++ %d", #la, #na))

-- 5. the host's export (loot maps: containers by owner, template parts by parent)
local tmp = os.getenv("TEMP") or "C:/Windows/Temp"
local pl, pn = tmp .. "/coop-exp-lua.tsv", tmp .. "/coop-exp-cpp.tsv"
tl = ms(L.export, pl)
tn = ms(Nn.export, pn)
local function read(p) local f = io.open(p, "rb") local s = f:read("*a") f:close() return s end
local el, en = read(pl), read(pn)
local rl, rn = {}, {}
for l in el:gmatch("[^\n]+") do rl[l] = true end
for l in en:gmatch("[^\n]+") do rn[l] = true end
a1, b1 = diff(rl, rn)
line("5. export", tl, tn, string.format("%d / %d bytes, rows only lua %d, only c++ %d", #el, #en, a1, b1))

-- 6. a path looked up 2000 times (deref: StaticFindObject vs a weak handle)
local p = L.ref(car)
tl = ms(function() for _ = 1, 2000 do L.deref(p) end end)
tn = ms(function() for _ = 1, 2000 do Nn.deref(p) end end)
line("6. deref x2000", tl, tn, tostring(Nn.deref(p) ~= nil))
return table.concat(out, "\n")
