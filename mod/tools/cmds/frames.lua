-- FRAMES_OUT: every building frame of the current level as "classpath|x|y|z|pitch|yaw|roll|parentclass".
-- FRAMES_SWAP (client): host frames file; frames on a host frame's spot with another class are replaced by
-- the host's class (frame + everything attached under it destroyed, the host's class spawned there).
CoopSync = CoopSync or dofile("C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua")
local function frames()
    local out = {}
    for _, a in ipairs(FindAllOf("Actor") or {}) do
        if CoopSyncUsable(a) and a:GetFullName():find(":PersistentLevel.", 1, true) and CoopSync.clsName(a):find("^BP_BuildingFrame_") then
            out[#out + 1] = a
        end
    end
    return out
end
if FRAMES_OUT then
    local f = io.open(FRAMES_OUT, "wb")
    for _, a in ipairs(frames()) do
        local l, r = a:K2_GetActorLocation(), a:K2_GetActorRotation()
        local p = CoopSync.parentOf(a)
        f:write(string.format("%s|%.2f|%.2f|%.2f|%.3f|%.3f|%.3f|%s\n", a:GetClass():GetFullName():gsub("^%S+ ", ""), l.X, l.Y, l.Z,
            r.Pitch, r.Yaw, r.Roll, p and CoopSync.clsName(p) or "-"))
    end
    f:close()
    return "written"
end
local host = {}
for line in io.lines(FRAMES_SWAP) do
    local c, x, y, z, pi, ya, ro = line:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)")
    host[#host + 1] = { cls = c, loc = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, rot = { Pitch = tonumber(pi), Yaw = tonumber(ya), Roll = tonumber(ro) } }
end
local swapped, doomed, todo = 0, {}, {}
for _, a in ipairs(frames()) do
    local l = a:K2_GetActorLocation()
    for _, h in ipairs(host) do
        if (l.X - h.loc.X) ^ 2 + (l.Y - h.loc.Y) ^ 2 + (l.Z - h.loc.Z) ^ 2 < 25 then
            if a:GetClass():GetFullName():gsub("^%S+ ", "") ~= h.cls then doomed[a:GetFullName()] = true todo[#todo + 1] = h end
            break
        end
    end
end
local removed = CoopSync.destroyTrees(doomed)
for _, h in ipairs(todo) do
    local b = CoopSync.spawnEntry({ cls = h.cls, loc = h.loc, rot = h.rot, scale = { X = 1, Y = 1, Z = 1 }, loot = "" })
    if b then swapped = swapped + 1 end
end
return string.format("mismatched=%d destroyed=%d spawned=%d", #todo, removed, swapped)
