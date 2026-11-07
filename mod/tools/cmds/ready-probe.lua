-- Zone readiness after a load or leg travel: replicated roots in total and how many still stand at the
-- origin (spawned by the zone generator but not placed yet).
CoopSync = CoopSync or dofile("C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua")
local gi = FindFirstOf("DrivingGameInstance")
local n, origin, cls = 0, 0, {}
for _, a in ipairs(CoopSync.collect()) do
    n = n + 1
    local l = a:K2_GetActorLocation()
    if l.X == 0 and l.Y == 0 and l.Z == 0 then
        origin = origin + 1
        local c = CoopSync.clsName(a)
        cls[c] = (cls[c] or 0) + 1
    end
end
local t = {}
for c, k in pairs(cls) do t[#t + 1] = c .. "=" .. k end
return string.format("state=%s world=%s roots=%d origin=%d %s", tostring(gi.CurrentGameplayState),
    gi:GetWorld():GetFName():ToString(), n, origin, table.concat(t, " "))
