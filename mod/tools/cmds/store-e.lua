-- E on a car's trunk storage (the box in the trunk) the game's way: the highlight manager's SetHighlight on the
-- storage part's highlight, the character's Command Interact(true), 100 ms later (false). SE_CAR = "own" | "twin";
-- SE_CLASS: the storage part's class (default the basic trunk storage).
local T = _G.CoopPlayers.twinModule()
local car
if SE_CAR == "twin" then
    for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then car = c end end
else
    car = T.ownCar()
end
if not car then return "no " .. tostring(SE_CAR) .. " car" end
local want = SE_CLASS or "BP_Storage_Trunk_Base_C"
SE_CAR, SE_CLASS = nil, nil
local HC = StaticFindObject("/Script/PenDriverPro.HighlightComponent")
local att = {}
car:GetAttachedActors(att, true)
local hc
for i = 1, #att do
    local a = att[i]:get()
    if a:IsValid() and a:GetClass():GetFName():ToString() == want then
        local hs = a:K2_GetComponentsByClass(HC)
        if #hs > 0 then hc = hs[1]:get() end
    end
end
if not hc then return "no " .. want end
-- (the storage opens on the release, OnInteract: the highlight held every frame till then - the game's own trace, not
-- aimed at the storage, cleared it in between)
local hm = FindFirstOf("BP_HighlightManager_C")
local ok, e = pcall(function()
    hm:SetHighlight(hc)
    local p = FindFirstOf("PlayerController").Pawn
    p["Command Interact"](p, true)
end)
local t0 = os.clock()
local h
h = LoopInGameThreadWithDelay(1, function()
    local dt = os.clock() - t0
    pcall(function() if hm.CurrentHighlight ~= hc then hm:SetHighlight(hc) end end)
    if dt > 0.1 then
        CancelDelayedAction(h)
        pcall(function() local q = FindFirstOf("PlayerController").Pawn q["Command Interact"](q, false) end)
    end
end)
return "E on " .. want .. ": " .. tostring(ok) .. (ok and "" or " " .. tostring(e))
