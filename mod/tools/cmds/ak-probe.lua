-- The radio track in Wwise: the track player's AkComponent (game object = its address), what plays on it (playing id,
-- event id), the track event's short id, the playing source's position. AK_SEEK = ms seeks the track event there first.
local mm = FindFirstOf("BP_MusicManager_C")
if not (mm and mm:IsValid()) then return "no music manager" end
local o = {}
local p = mm.MusicTrackPlayer
local src = p.PlaybackSource
local go = src and src:IsValid() and src:GetAddress() or 0
o[#o + 1] = string.format("source=%s go=%d", src and src:IsValid() and src:GetFullName() or "nil", go)
local ev = p.AudioEvent
local evId = 0
pcall(function() evId = ev:GetWwiseShortID() end)
o[#o + 1] = "event=" .. (ev and ev:IsValid() and ev:GetFName():ToString() or "nil") .. " short=" .. tostring(evId)
local list = CoopNative_AkPlaying(go)
o[#o + 1] = "playing:\n" .. list
for pid, eid in list:gmatch("(%d+) (%d+)\n") do
    local ms, r = CoopNative_AkPos(tonumber(pid))
    o[#o + 1] = string.format("pid %s event %s pos=%s r=%s", pid, eid, tostring(ms), tostring(r))
end
if AK_SEEK then
    o[#o + 1] = "seek " .. AK_SEEK .. " -> " .. tostring(CoopNative_AkSeek(evId, go, AK_SEEK, 0))
    AK_SEEK = nil
end
return table.concat(o, "\n")
