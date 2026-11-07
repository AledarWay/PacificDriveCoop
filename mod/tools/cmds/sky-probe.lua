-- Sky / light state of this game (for comparing host and guest): ToD manager north, wind, light mults, sun actor.
local m = FindFirstOf("BP_ToDManager_C")
local o = {}
local function v3(v) return v and string.format("%.3f,%.3f,%.3f", v.X, v.Y, v.Z) or "-" end
local function r3(r) return r and string.format("%.2f,%.2f,%.2f", r.Pitch, r.Yaw, r.Roll) or "-" end
local t = {} m["Get Current Time Of Day"](m, t)
o[#o + 1] = "tod=" .. string.format("%.4f", t["Returned Time Of Day"] or -1)
o[#o + 1] = "north=" .. v3(m.CurrentTrueNorth) .. " northRot=" .. r3(m["Current North As Rotator"])
o[#o + 1] = "randNorth=" .. tostring(m.DataBlock_IsUsingRandomNorth) .. " picked=" .. r3(m.DataBlock_PickedRandomNorth)
o[#o + 1] = "windDir=" .. v3(m.CurrentWindDirection) .. " windVar=" .. string.format("%.3f", m.CurrentWindVariance)
o[#o + 1] = string.format("dirMult=%.3f skyMult=%.3f tone=%.3f trans=%.3f overwriteDL=%s days=%d", m.DirectionalLightMult, m.SkyLightMult, m.PostProcessToneCurveAmount, m.PostProcessTransitionValue, tostring(m.OverwriteDirectionalLight), m.DaysSinceEpoch)
local a = m.ToDSimulationActor
if a and a:IsValid() then o[#o + 1] = "todActor=" .. a:GetClass():GetFName():ToString() .. " rot=" .. r3(a:K2_GetActorRotation()) end
for _, cls in ipairs({ "DirectionalLight", "SkyLight", "ExponentialHeightFog", "SkyAtmosphere", "VolumetricCloud" }) do
    local n = 0
    for _, x in ipairs(FindAllOf(cls) or {}) do
        if x:IsValid() and x:GetFullName():find("PersistentLevel", 1, true) then
            n = n + 1
            if n <= 2 then o[#o + 1] = cls .. "#" .. n .. " rot=" .. r3(x:K2_GetActorRotation()) end
        end
    end
    o[#o + 1] = cls .. "s=" .. n
end
local s = {} pcall(function() m:GetSunlightIntensity(s) end)
o[#o + 1] = "sun=" .. tostring(s.NormalizedIntensity)
return table.concat(o, " | ")
