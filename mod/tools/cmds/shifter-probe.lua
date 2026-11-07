-- The gear levers: each shifter's MainMesh pitch relative to its car (own / twin), the manager's gear, what the own
-- car's GetGearboxActor answers. SHIFT_DO = true: the own car's ToggleGearBoxState(current, false) first (the game's
-- lever with its animation: drive <-> park).
local T = _G.CoopPlayers.twinModule()
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local m = FindFirstOf("BP_CarManager_C")
local own = T.ownCar()
local o = {}
if SHIFT_DO and own then
    local ok, e = pcall(function() own:ToggleGearBoxState(m.MyCarGearBox, false) end)
    o[#o + 1] = "toggle=" .. tostring(ok) .. (ok and "" or ("_" .. tostring(e)))
    SHIFT_DO = nil
end
o[#o + 1] = "gear=" .. tostring(m.MyCarGearBox)
for _, a in ipairs(FindAllOf("BP_Carpart_Shifter_Base_C") or {}) do
    local p = a:IsValid() and a:GetAttachParentActor()
    if p and p:IsValid() then
        local r = KML:InverseTransformRotation(p:GetTransform(), a.MainMesh:K2_GetComponentRotation())
        o[#o + 1] = string.format("%s=%.1f", T.isTwin(p) and "twin" or "own", r.Pitch)
    end
end
pcall(function()
    local ga = {}
    own:GetGearboxActor(ga, {})
    local p = ga.GearboxActor:GetAttachParentActor()
    o[#o + 1] = "own_asks=" .. ((p and p:IsValid()) and (T.isTwin(p) and "twin" or "own") or "none")
end)
return table.concat(o, " ")
