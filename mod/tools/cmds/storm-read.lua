-- This side's instability storm (owner's alpha 21 test: "at an unstable junction my siren started and the instability
-- came, my friend's not") and the sky's storm blend (the sun's strength differed ~5 % in nextzone-test). One line.
local out = {}
local function add(k, v) out[#out + 1] = k .. "=" .. tostring(v) end
local function f2(x) return type(x) == "number" and string.format("%.2f", x) or tostring(x) end
pcall(function()
    local m = FindFirstOf("BP_StormManager_C")
    if not (m and m:IsValid()) then add("storm", "none") return end
    add("state", tostring(m.CurrentStormState))
    add("newtimer", tostring(m.NewInstabilityTimerActive))
    add("before", f2(m.TimeBeforeInstabilityStarts))
    local t = {} pcall(function() m:GetCurrentInstabilityTime(t) end)
    add("insttime", f2(t.CurrentInstabilityTime))
    add("tol", f2(m.FinalInstabilityTollerance))
    add("avint", f2(m.StormAudioVisualIntensity))
    add("speed", f2(m.StormPlaybackSpeed))
    local s = m.SpawnedStormIfValid
    add("spawned", (s and s:IsValid()) and (s:GetFName():ToString() .. "@" .. string.format("%.0f,%.0f", s:K2_GetActorLocation().X, s:K2_GetActorLocation().Y)) or "-")
    local a, b = {}, {}
    pcall(function() m:IsStormActive(a) end) pcall(function() m:IsWeakStormActive(b) end)
    add("active", tostring(a.StormIsActive)) add("weak", tostring(b.Result))
    add("inweak", tostring(m.PlayerInsideWeakStorm)) add("instrong", tostring(m.PlayerInsideStrongStorm))
    add("left", tostring(m.PlayerLeftStartingArea)) add("redwall", tostring(m.RedWallActive))
    add("wall", f2(m.FirstWallRadius))
    local g = m.EvolvedGatewayExit
    add("exit", (g and g:IsValid()) and g:GetFName():ToString() or "-")
end)
pcall(function()
    local n = 0
    for _, s in ipairs(FindAllOf("BP_ZoneStorm_Base_C") or {}) do if s:IsValid() and not s:GetFullName():find("Default__", 1, true) then n = n + 1 end end
    add("storms", n)
end)
pcall(function()
    local sim = FindFirstOf("BP_ToDManager_C").ToDSimulationActor
    add("weakov", f2(sim.WeakStormOverride))
    add("simstorm", f2(sim["TOD Override Zone Storm Current"]))
    add("simdark", f2(sim["TOD Override Darkness Current"]))
    add("simfog", f2(sim["TOD Override Fog Current"]))
    add("exposure", f2(sim.CurrentExposure))
    local p = sim.CurrentPresetObject
    add("preset", (p and p:IsValid()) and p:GetClass():GetFName():ToString() or "-")
    local r = {} sim:GetDirectionalIntensity(r)
    add("dirint", f2(r.FinalIntensity) .. "/" .. f2(r["Resulting Mult"]))
    add("pptrans", f2(sim.LocalPostProcessTransitionValue))
end)
pcall(function()
    local m = FindFirstOf("BP_ToDManager_C")
    add("dlm", f2(m.DirectionalLightMult)) add("slm", f2(m.SkyLightMult))
    local o = {}
    for _, w in ipairs(m.TargetWeatherOverrideArray and (function() local r = {} m.TargetWeatherOverrideArray:ForEach(function(_, e) r[#r + 1] = e:get() end) return r end)() or {}) do
        pcall(function() o[#o + 1] = w.Identifier_26_37794E45404F7D45933471B6A50F260C:ToString() .. ":" .. f2(w.Priority_2_E0B18C1F4F7065861D754CBC1717C0F4) end)
    end
    add("overrides", #o > 0 and table.concat(o, ",") or "-")
end)
return table.concat(out, " ")
