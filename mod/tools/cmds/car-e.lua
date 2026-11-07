-- The game's own E on a highlight of a car, like a player: the highlight manager's SetHighlight on it, the character's
-- Command Interact(true), CE_HOLD_MS later (default 100) Command Interact(false).
--   CE_CAR = "own" | "twin"      which car
--   CE_HL  = "ExitDoor" | "EnterDoor" | ... (a highlight of the car body: Highlight_<name>) | "door<n>" (the highlight
--            of door actor n: 1 FL, 2 FR, 3 RL, 4 RR, 5 trunk)
-- CE_HL = nil: the car body's highlights and their bindings (which game handlers E runs there).
local T = _G.CoopPlayers.twinModule()
local car
if CE_CAR == "twin" then
    for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then car = c end end
else
    car = T.ownCar()
end
if not car then return "no " .. tostring(CE_CAR) .. " car" end
local HC = StaticFindObject("/Script/PenDriverPro.HighlightComponent")
local hc
local n = CE_HL and tonumber(CE_HL:match("^door(%d)$"))
if n then
    local d = T.door(car, n)
    if not d then return "no door " .. n end
    local comps = d:K2_GetComponentsByClass(HC)
    hc = #comps > 0 and comps[1]:get() or nil
elseif CE_HL then
    hc = car["Highlight_" .. CE_HL]
else
    local o = {}
    local comps = car:K2_GetComponentsByClass(HC)
    for i = 1, #comps do
        local h = comps[i]:get()
        local b = {}
        for _, dn in ipairs({ "OnInteract", "OnInteractShort", "OnInteractLong", "OnInteractStart", "OnInteractEnd" }) do
            pcall(function()
                for _, e in ipairs(h[dn]:GetBindings() or {}) do b[#b + 1] = dn:gsub("OnInteract", "") .. ":" .. e.FunctionName:ToString() end
            end)
        end
        o[#o + 1] = h:GetFName():ToString() .. " [" .. table.concat(b, " ") .. "]"
    end
    return table.concat(o, "\n")
end
if not (hc and hc:IsValid()) then return "no highlight " .. tostring(CE_HL) end
local hm = FindFirstOf("BP_HighlightManager_C")
local ok, e = pcall(function()
    hm:SetHighlight(hc)
    local p = FindFirstOf("PlayerController").Pawn
    p["Command Interact"](p, true)
end)
local hold = CE_HOLD_MS or 100
Dev.after(hold, function() pcall(function() local q = FindFirstOf("PlayerController").Pawn q["Command Interact"](q, false) end) end)
CE_HL, CE_HOLD_MS = nil, nil
return string.format("E on %s %s: %s %s", tostring(CE_CAR), hc:GetFName():ToString(), tostring(ok), ok and "" or tostring(e))
