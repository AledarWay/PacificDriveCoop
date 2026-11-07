-- The radio DJ's interstitials (BaseMusicManager.CurrentInterstitial, a DialogueSequence played by the dialogue manager
-- between / over tracks). DJ_OP: 'info' (default) the manager's interstitial state and the dialogue manager's sequence;
-- 'req' RequestInterstitial(); 'play' the dialogue manager's PlaySequence(DJ_SEQ) (a full name); 'stop'
-- StopCurrentSequence(); 'counters' sets both counters to DJ_N.
local mm = FindFirstOf("BP_MusicManager_C")
if not (mm and mm:IsValid()) then return "no music manager" end
local dm = FindFirstOf("BP_DialogueManager_C")
local op = DJ_OP or "info"
DJ_OP = nil
local o = {}
local function nm(x) local ok, s = pcall(function() return x:IsValid() and x:GetFullName() or "nil" end) return ok and s or "nil" end
if op == "req" then
    local ok, e = pcall(function() mm:RequestInterstitial() end)
    o[#o + 1] = "req " .. tostring(ok) .. " " .. tostring(e or "")
elseif op == "play" then
    local s = StaticFindObject(DJ_SEQ)
    local ok, e = pcall(function() dm:PlaySequence(s, 0, nil) end)
    o[#o + 1] = "play " .. tostring(s and s:IsValid()) .. " " .. tostring(ok) .. " " .. tostring(e or "")
elseif op == "stop" then
    local ok, e = pcall(function() dm:StopCurrentSequence() end)
    o[#o + 1] = "stop " .. tostring(ok) .. " " .. tostring(e or "")
elseif op == "counters" then
    mm.NextNaturalInterstitialCounter = DJ_N
    mm.NextManualInterstitialCounter = DJ_N
end
pcall(function() o[#o + 1] = "cur=" .. nm(mm.CurrentInterstitial) end)
pcall(function() o[#o + 1] = "natural=" .. mm.NextNaturalInterstitialCounter .. " manual=" .. mm.NextManualInterstitialCounter .. " timer=" .. string.format("%.1f", mm.NextInterstitialTimer) end)
pcall(function() o[#o + 1] = "playingInterstitial=" .. tostring(mm:IsPlayingInterstitial()) end)
pcall(function() o[#o + 1] = "radioOn=" .. tostring(mm.radioOn) .. " garage=" .. tostring(mm.GarageStereoOn) end)
pcall(function() o[#o + 1] = "dm cur=" .. nm(dm.CurrentlyPlayingSequence) end)
pcall(function() o[#o + 1] = "track=" .. nm(mm:CurrentRadioTrack()) end)
pcall(function() o[#o + 1] = "talking=" .. tostring(dm:IsAnyoneTalking()) end)
pcall(function() o[#o + 1] = "getcur=" .. nm(dm:GetCurrentlyPlayingSequence()) end)
pcall(function() o[#o + 1] = "speaker=" .. tostring(dm:GetCurrentSpeaker()) end)
pcall(function() local l = dm.SequenceLog o[#o + 1] = "log=" .. #l .. " last=" .. nm(l[#l]) end)
pcall(function() o[#o + 1] = "pending=" .. #dm.PendingSequences .. " queue=" .. #dm.DialogueSequenceQueue end)
pcall(function()
    for i = 1, #dm.SequenceLog do
        local s = dm.SequenceLog[i]
        o[#o + 1] = "\n  " .. nm(s) .. " ev=" .. s.DialogueEvent.Name:ToString() .. " mode=" .. tostring(s.Mode) .. " dur=" .. string.format("%.1f/%.1f", s.Duration, s.AutoDuration) .. " prio=" .. tostring(s.Priority) .. " set=" .. nm(dm:GetSequenceSet(s))
    end
end)
pcall(function() o[#o + 1] = "since=" .. string.format("%.1f", dm:GetTimeSinceSequencePlayed(dm.CurrentlyPlayingSequence)) end)
return table.concat(o, " ")
