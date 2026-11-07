-- The car radio: the manager's on/off (RADIO_SET = true/false sets it first), and per radio part (own / twin) its
-- AkComponents' active events and the radio component's channel.
local T = _G.CoopPlayers.twinModule()
local m = FindFirstOf("BP_CarManager_C")
if RADIO_SET ~= nil then m:SetCarRadioOnOffState(RADIO_SET, true) RADIO_SET = nil end
local st = {}
m:GetCarRadioOnOffState(st)
local o = { "manager radio=" .. tostring(st.CarState_Radio) }
for _, r in ipairs(FindAllOf("BP_CarPart_Internal_Radio_C") or {}) do
    local p = r:GetAttachParentActor()
    local tag = (p and p:IsValid() and T.isTwin(p)) and "TWIN" or "OWN"
    local ok1, a = pcall(function() return r.AK_RadioSource:HasActiveEvents() end)
    local ok2, b = pcall(function() return r.AK_ExternalMediaPlayer:HasActiveEvents() end)
    local ok3, c = pcall(function() return r.BP_RadioComponent.CurrentChannel end)
    o[#o + 1] = string.format("%s src_active=%s media_active=%s channel=%s", tag, tostring(ok1 and a), tostring(ok2 and b), tostring(ok3 and c))
end
return table.concat(o, " | ")
