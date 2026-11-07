-- The player's own radio files (Custom/Radio): RADIO_RESCAN = true rescans first; then how many files were scanned and
-- the playlist's entries with an ExternalUrl (id as twincar.trackId gives it).
local mm = FindFirstOf("BP_MusicManager_C")
if not (mm and mm:IsValid()) then return "no music manager" end
local o = {}
if RADIO_RESCAN then
    RADIO_RESCAN = nil
    o[#o + 1] = "rescan: " .. tostring(pcall(function() mm:RescanLocalFiles() end))
end
pcall(function() o[#o + 1] = "scanning=" .. tostring(mm:IsScanningForMusic()) .. " scanned=" .. tostring(mm:GetNumLocalFilesScanned()) end)
local pl = mm.RadioPlaylist
o[#o + 1] = "playlist=" .. #pl .. " default=" .. #mm.DefaultRadioPlaylist
for i = 1, #pl do
    local url = ""
    pcall(function() url = pl[i].ExternalUrl:ToString() end)
    if url ~= "" then o[#o + 1] = i .. ": " .. url .. " | " .. pl[i]:GetFullName() end
end
for i = 1, #mm.DefaultRadioPlaylist do
    local url = ""
    pcall(function() url = mm.DefaultRadioPlaylist[i].ExternalUrl:ToString() end)
    if url ~= "" then o[#o + 1] = "default " .. i .. ": " .. url end
end
return table.concat(o, "\n")
