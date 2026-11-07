-- what the game highlights right now: the component, its owner (and the owner's root car: own / twin), the manager's
-- state; PRESS_MS > 0: press the highlight interaction (HighlightPress) and release it after PRESS_MS
local T = _G.CoopPlayers.twinModule()
local hm = FindFirstOf("BP_HighlightManager_C")
if not hm then return "no highlight manager" end
local h = hm.CurrentHighlight
local s = "highlighting=" .. tostring(hm.IsCurrentlyHighlighting)
if h and h:IsValid() then
    local a = h:GetOwner()
    local root, g = a, 0
    while g < 10 do local p = root:GetAttachParentActor() if not (p and p:IsValid()) then break end root, g = p, g + 1 end
    local kind = T.isTwin(root) and "TWIN" or (root:GetClass():GetFName():ToString() == "BP_PlayerCarNew_C" and "OWN" or root:GetClass():GetFName():ToString())
    s = s .. string.format(" comp=%s owner=%s car=%s", h:GetFName():ToString(), a:GetClass():GetFName():ToString(), kind)
    pcall(function()
        local out = {}
        a:GetSlotComponent(out)
        local sc = out.SlotSceneComponent
        s = s .. " slot=" .. (sc and sc:IsValid() and sc.SlotName.TagName:ToString() or "?")
    end)
else
    s = s .. " comp=none"
end
if PRESS_MS and PRESS_MS > 0 then
    local ok, e = pcall(function() hm:HighlightPress(true, {}) end)
    s = s .. " press=" .. tostring(ok) .. (ok and "" or (" " .. tostring(e)))
    Dev.after(PRESS_MS, function() pcall(function() FindFirstOf("BP_HighlightManager_C"):HighlightPress(false, {}) end) end)
end
return s
