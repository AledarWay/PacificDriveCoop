-- Time of day and weather as the ToD manager holds them (for the weather / time sync).
local m = FindFirstOf("BP_ToDManager_C")
if not m then return "no ToD manager" end
local out = {}
local function call(fn, ...)
    local ok, e = pcall(function(...) m[fn](m, ...) end, ...)
    if not ok then out[#out + 1] = fn .. " ERR " .. tostring(e) end
end
local t = {}
call("Get Current Time Of Day", t)
out[#out + 1] = "tod=" .. tostring(t["Returned Time Of Day"])
local p = {}
call("Get Target to D Preset", p)
local preset = p["Target TOD Preset"]
out[#out + 1] = "preset=" .. tostring(preset and preset:IsValid() and preset:GetFullName() or preset)
local w = { {}, {}, {}, {}, {}, {}, {} }
call("Get Current Weather Override Values", w[1], w[2], w[3], w[4], w[5], w[6], w[7])
local vals = {}
for i = 1, 7 do for k, v in pairs(w[i]) do vals[#vals + 1] = k .. "=" .. string.format("%.3f", v) end end
out[#out + 1] = "overrides " .. table.concat(vals, " ")
local pr, we, ws = {}, {}, {}
call("GetCurrentPrecipitation", pr) call("GetCurrentWetnessBuildup", we) call("GetCurrentWindSpeed", ws)
out[#out + 1] = string.format("precip=%s wet=%s wind=%s", tostring(pr.Percipitation), tostring(we.CurrentWetnessBuildup), tostring(ws.CurrentWindSpeed))
out[#out + 1] = "targets=" .. tostring(#m.TargetWeatherOverrideArray) .. " isDay=" .. tostring(m.IsDay) .. " speedMult=" .. tostring(m.LocalTODSpeedMultiplier)
return table.concat(out, " | ")
