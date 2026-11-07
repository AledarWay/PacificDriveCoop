-- The headlight parts of the own car and the twin: the scalar fields (bool / float / byte / int) of the part actor and
-- of its BP_BatteryConsumerComponent / AC_ElectricalHelper, and the main light's intensity - what differs between a
-- lit own headlight and the twin's dark one. HP_FUNCS = true also lists the consumer component's functions.
local T = _G.CoopPlayers.twinModule()
local own, twin = T.ownCar(), nil
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then twin = c end end
local function headlight(car)
    if not car then return nil end
    local arr = {}
    car:GetAttachedActors(arr, true)
    for i = 1, #arr do
        local a = arr[i]:get()
        if a:GetClass():GetFName():ToString():find("Headlight", 1, true) then return a end
    end
end
local SCALAR = { BoolProperty = true, FloatProperty = true, ByteProperty = true, IntProperty = true, EnumProperty = true }
local function fields(obj)
    local t = {}
    if not (obj and obj:IsValid()) then return t end
    local cls = obj:GetClass()
    while cls and cls:IsValid() do
        cls:ForEachProperty(function(p)
            local n = p:GetFName():ToString()
            if SCALAR[p:GetClass():GetFName():ToString()] and t[n] == nil then
                local ok, v = pcall(function() return obj[n] end)
                if ok then t[n] = type(v) == "number" and string.format("%.2f", v) or tostring(v) end
            end
        end)
        local ok, s = pcall(function() return cls:GetSuperStruct() end)
        cls = ok and s or nil
        if cls and cls:GetFName():ToString():find("^Actor") then break end
    end
    return t
end
local function comp(a, cname)
    if not a then return nil end
    local all = a:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.ActorComponent"))
    for i = 1, #all do local c = all[i]:get() if c:GetClass():GetFName():ToString() == cname then return c end end
end
local o = {}
local ho, ht = headlight(own), headlight(twin)
for _, w in ipairs({ { "part", function(a) return a end }, { "consumer", function(a) return comp(a, "BP_BatteryConsumerComponent_C") end },
    { "electrical", function(a) return comp(a, "AC_ElectricalHelper_C") end } }) do
    local fo, ft = fields(w[2](ho)), fields(w[2](ht))
    local diff, same = {}, 0
    local keys = {}
    for k in pairs(fo) do keys[#keys + 1] = k end
    for k in pairs(ft) do if fo[k] == nil then keys[#keys + 1] = k end end
    table.sort(keys)
    for _, k in ipairs(keys) do
        if fo[k] ~= ft[k] then diff[#diff + 1] = k .. "=" .. tostring(fo[k]) .. "|" .. tostring(ft[k]) else same = same + 1 end
    end
    o[#o + 1] = w[1] .. " (own|twin) differ: " .. table.concat(diff, " ") .. "  (" .. same .. " same)"
end
local function inten(a) local ok, v = pcall(function() return a.MainLight_01.Intensity end) return ok and string.format("%.0f", v) or "?" end
o[#o + 1] = "intensity own=" .. inten(ho) .. " twin=" .. inten(ht)
if HP_FUNCS and ho then
    local c = comp(ho, "BP_BatteryConsumerComponent_C")
    local fs = {}
    c:GetClass():ForEachFunction(function(f) fs[#fs + 1] = f:GetFName():ToString() end)
    o[#o + 1] = "consumer functions: " .. table.concat(fs, ", ")
end
HP_FUNCS = nil
return table.concat(o, "\n")
