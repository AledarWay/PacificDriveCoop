-- Wiper blades of the own car and the twin: the wiper timeline's position / playing and the left blade's relative
-- rotation. WIPER_SET = position: the twin's SetWiperTimeline(position) first.
local T = _G.CoopPlayers.twinModule()
local own, twin = T.ownCar(), nil
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then twin = c end end
if WIPER_SET and twin then local ok, e = pcall(function() twin:SetWiperTimeline(WIPER_SET) end) if not ok then return "set: " .. tostring(e) end end
WIPER_SET = nil
local function info(tag, c)
    if not c then return tag .. "=-" end
    local tl = c.Timeline_wiperblade
    local pos, play = -1, "?"
    pcall(function() pos = tl:GetPlaybackPosition() play = tostring(tl:IsPlaying()) end)
    local r = c.WiperBlade_L.RelativeRotation
    return string.format("%s_pos=%.3f %s_play=%s %s_rot=%.1f/%.1f/%.1f", tag, pos, tag, play, tag, r.Pitch, r.Yaw, r.Roll)
end
return info("own", own) .. " " .. info("twin", twin)
