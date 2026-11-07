if not (CoopSync and CoopSync.zoneReady) then CoopSync = nil end
CoopSync = CoopSync or dofile("C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua")
local by, n = {}, 0
for _, a in ipairs(CoopSync.collect()) do local c = a:GetClass():GetFName():ToString() by[c] = (by[c] or 0) + 1 n = n + 1 end
local ready, markers, origin = CoopSync.zoneReady()
return string.format("total=%d mines=%d cascades=%d items=%d ready=%s markers=%d origin=%d", n, by["BP_Hazard_Landmine_C"] or 0,
    by["BP_VolCascade_Radiation_C"] or 0, by["BP_WorldItem_C"] or 0, tostring(ready), markers, origin)
