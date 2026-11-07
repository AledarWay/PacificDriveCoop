-- Replicated-class actors of the current world at the origin: pooled? attached? hidden? (why collect() skips them)
CoopSync = CoopSync or dofile("C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua")
local Pooled = StaticFindObject("/Script/PenDriverUtils.PooledActor")
local gi = FindFirstOf("DrivingGameInstance")
local level = gi:GetWorld():GetFullName():gsub("^%S+ ", "") .. ":PersistentLevel."
local stats, samples = {}, {}
for _, a in ipairs(FindAllOf("Actor") or {}) do
    if CoopSyncUsable(a) and a:GetFullName():find(level, 1, true) and CoopSync.matches(CoopSync.clsName(a)) then
        local l = a:K2_GetActorLocation()
        if l.X == 0 and l.Y == 0 and l.Z == 0 then
            local pooled = Pooled and a:IsA(Pooled) or false
            local okP, bp = pcall(function() return a.bPooled end)
            local okI, inUse = pcall(function() return a.bInUse end)
            local p = CoopSync.parentOf(a)
            local k = string.format("pooled=%s bPooled=%s inUse=%s parent=%s hidden=%s", tostring(pooled), tostring(okP and bp),
                tostring(okI and inUse), p and CoopSync.clsName(p) or "-", tostring(a.bHidden))
            stats[k] = (stats[k] or 0) + 1
            if #samples < 4 then samples[#samples + 1] = a:GetFName():ToString() end
        end
    end
end
local t = {}
for k, v in pairs(stats) do t[#t + 1] = v .. "x " .. k end
return table.concat(t, "\n") .. "\n" .. table.concat(samples, " ")
