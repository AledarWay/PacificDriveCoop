-- The radio's music: the music manager's playlist, current track (title / artist / url / event), the track player's
-- track and source, the external media player's time. MUSIC_SKIP = n calls the manager's SkipTrack(n) first;
-- MUSIC_LIST = true lists the playlist.
local mm = FindFirstOf("BP_MusicManager_C")
if not (mm and mm:IsValid()) then return "no music manager" end
local o = {}
local function trk(t)
    if not (t and t:IsValid()) then return "nil" end
    local s = {}
    pcall(function() s[#s + 1] = "title=" .. t.Title:ToString() end)
    pcall(function() s[#s + 1] = "artist=" .. t.Artist:ToString() end)
    pcall(function() s[#s + 1] = "url=" .. t.ExternalUrl:ToString() end)
    pcall(function() s[#s + 1] = "name=" .. t:GetFullName() end)
    return table.concat(s, " ")
end
if MUSIC_SKIP then
    local ok, e = pcall(function() mm:SkipTrack(MUSIC_SKIP) end)
    o[#o + 1] = "skip " .. tostring(MUSIC_SKIP) .. ": " .. tostring(ok) .. (ok and "" or (" " .. tostring(e)))
    MUSIC_SKIP = nil
end
pcall(function() o[#o + 1] = "playlist=" .. #mm.RadioPlaylist .. " default=" .. #mm.DefaultRadioPlaylist end)
pcall(function() o[#o + 1] = "radioOn=" .. tostring(mm.radioOn) .. " meant=" .. tostring(mm.MusicMeantToBePlaying) .. " playingId=" .. tostring(mm.MusicPlayingID) end)
local ok, cur = pcall(function() return mm:CurrentRadioTrack() end)
o[#o + 1] = "current: " .. (ok and trk(cur) or ("err " .. tostring(cur)))
pcall(function()
    local p = mm.MusicTrackPlayer
    o[#o + 1] = "player track: " .. trk(p.Track)
    pcall(function() o[#o + 1] = "player event=" .. (p.AudioEvent:IsValid() and p.AudioEvent:GetFullName() or "nil") end)
    pcall(function() o[#o + 1] = "player source=" .. (p.PlaybackSource:IsValid() and p.PlaybackSource:GetFullName() or "nil") end)
end)
pcall(function()
    local mp = mm.ExternalMediaPlayer
    o[#o + 1] = "media valid=" .. tostring(mp:IsValid())
    pcall(function() local t = mp:GetTime() o[#o + 1] = "media time ticks=" .. tostring(t.Ticks) end)
    pcall(function() o[#o + 1] = "media playing=" .. tostring(mp:IsPlaying()) .. " url=" .. mp:GetUrl():ToString() end)
end)
if MUSIC_LIST then
    pcall(function()
        for i = 1, #mm.RadioPlaylist do o[#o + 1] = i .. ": " .. trk(mm.RadioPlaylist[i]) end
    end)
    MUSIC_LIST = nil
end
return table.concat(o, "\n")
