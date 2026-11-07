-- ToD_Simulation_C state: cloud layer positions, sun, exposure, light intensities (host vs guest comparison)
local a = FindFirstOf("BP_ToDManager_C").ToDSimulationActor
local function c4(c) return string.format("%.3f,%.3f,%.3f,%.3f", c.R, c.G, c.B, c.A) end
local function r3(r) return string.format("%.2f,%.2f,%.2f", r.Pitch, r.Yaw, r.Roll) end
local o = {}
o[#o + 1] = "base=" .. c4(a.UVBaseLayerPosition) .. " second=" .. c4(a.UVSecondLayerPosition)
o[#o + 1] = "sunRot=" .. r3(a.SunWorldRotation) .. string.format(" sunVec=%.3f,%.3f,%.3f", a.SunlightVector.X, a.SunlightVector.Y, a.SunlightVector.Z)
o[#o + 1] = string.format("exposure=%.3f localToD=%.4f weakStorm=%.3f fluffy=%.3f bloom=%.3f", a.CurrentExposure, a.LocalActorTimeOfDay, a.WeakStormOverride, a.CloudsFluffy, a.CloudsBloom)
o[#o + 1] = string.format("ovr rain=%.3f fog=%.3f wind=%.3f dark=%.3f", a["TOD Override Rain Current"], a["TOD Override Fog Current"], a["TOD Override Wind Current"], a["TOD Override Darkness Current"])
local dl, sl = a.DirectionalLight, a.SkyLight
o[#o + 1] = string.format("dl=%.3f dlRot=%s sky=%.3f", dl.Intensity, r3(dl:K2_GetComponentRotation()), sl.Intensity)
local f = a.ExponentialHeightFog
o[#o + 1] = string.format("fog=%.4f", f.FogDensity)
return table.concat(o, " | ")
