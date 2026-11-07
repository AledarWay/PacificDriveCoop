-- Twin rework: the game's own E on one of the twin's car body highlights (BODY_HL = "Key" | "TopLight" | "EnterDoor" |
-- "ExitDoor" | "LeftHandle" | "RightHandle" | "Radio": the radio part's button), the real path: the highlight manager's SetHighlight on it, then
-- the character's Command Interact(true) and (BODY_HOLD_MS later, default 100) Command Interact(false). BODY_HL = nil only prints the state.
-- State: the manager's car / ignition / lights, the local pawn's parent car, both cars' top light.
local T = _G.CoopPlayers.twinModule()
local twin
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then twin = c end end
if not twin then return "no twin" end
local o = {}
local function state()
    local cm = FindFirstOf("BP_CarManager_C")
    local nc = cm and cm.NewCarActor
    local p = FindFirstOf("PlayerController").Pawn
    local par = p:GetAttachParentActor()
    local function kind(a) return (a and a:IsValid()) and (T.isTwin(a) and "TWIN" or a:GetClass():GetFName():ToString()) or "none" end
    local own = T.ownCar()
    local function top(c) local ok, v = pcall(function() return c.LightTargetValue_TopLight end) return ok and string.format("%.0f", v) or "?" end
    return string.format("manager=%s ign=%s lightsOn=%s pawnParent=%s inCar=%s ownTop=%s twinTop=%s", kind(nc), tostring(cm.CarIgnitionState),
        tostring(cm.CarLightsOn), kind(par), tostring(p.PercentInCar), own and top(own) or "-", top(twin))
end
o[#o + 1] = "before: " .. state()
if BODY_HL then
    local hc = twin["Highlight_" .. BODY_HL]
    if BODY_HL == "Radio" then local r = T.radioOf(twin) hc = r and r.Highlight1 end -- (the radio part's button)
    local hm = FindFirstOf("BP_HighlightManager_C")
    if not (hc and hc:IsValid() and hm) then return "no highlight " .. BODY_HL end
    local ok, e = pcall(function()
        hm:SetHighlight(hc)
        local p = FindFirstOf("PlayerController").Pawn
        p["Command Interact"](p, true)
    end)
    o[#o + 1] = "press " .. BODY_HL .. ": " .. tostring(ok) .. (ok and "" or (" " .. tostring(e))) .. " current=" .. tostring(hm.CurrentHighlight and hm.CurrentHighlight:IsValid() and hm.CurrentHighlight:GetFName():ToString())
    Dev.after(BODY_HOLD_MS or 100, function() pcall(function() local q = FindFirstOf("PlayerController").Pawn q["Command Interact"](q, false) end) end)
end
BODY_HL, BODY_HOLD_MS = nil, nil
return table.concat(o, "\n")
