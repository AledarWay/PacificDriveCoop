-- A player's own file played by id through twincar (customTrack / playTrack), its media player time and a seek.
-- CUSTOM_ID = "x:<file name>"; CUSTOM_SEEK = ms seeks the playing track there.
-- (twincar's delayed steps: CoopSync's own CoopSyncAfter is not in CoopDev's Lua state)
CoopSyncAfter = CoopSyncAfter or function(ms, f) Dev.after(ms, f) end
if not CoopDevTwin then
    local S = dofile("C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua")
    CoopDevTwin = dofile(S.DIR .. "twincar.lua")
    if CoopDevTwin.init then pcall(CoopDevTwin.init, S) end
end
local T = CoopDevTwin
local o = {}
if CUSTOM_ID then
    o[#o + 1] = "dir-made=" .. tostring(T.customTrack(CUSTOM_ID))
    o[#o + 1] = "play=" .. tostring(T.playTrack(CUSTOM_ID))
    CUSTOM_ID = nil
end
if CUSTOM_SEEK then
    o[#o + 1] = "seek=" .. tostring(T.seekTrack(CUSTOM_SEEK))
    CUSTOM_SEEK = nil
end
local id, pos, len = T.trackPos()
o[#o + 1] = string.format("cur=%s pos=%s len=%s pl=%d", tostring(id), tostring(pos and math.floor(pos)), tostring(len and math.floor(len)), #FindFirstOf("BP_MusicManager_C").RadioPlaylist)
return table.concat(o, " ")
