-- Twin rework: the highlight components on the twin's car body itself (not its part actors) and their OnInteract*
-- bindings - which game handlers the E key would run there (Key, TopLight, EnterDoor, ExitDoor, Gearbox, ...).
local T = _G.CoopPlayers.twinModule()
local twin
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then twin = c end end
if not twin then return "no twin" end
local HC = StaticFindObject("/Script/PenDriverPro.HighlightComponent")
local DELS = { "OnInteract", "OnInteractShort", "OnInteractLong", "OnInteractStartLong", "OnInteractStart", "OnInteractEnd" }
local o = {}
local comps = twin:K2_GetComponentsByClass(HC)
for i = 1, #comps do
    local hc = comps[i]:get()
    local b = {}
    for _, dn in ipairs(DELS) do
        local ok, list = pcall(function() return hc[dn]:GetBindings() end)
        if ok and list then
            for _, e in ipairs(list) do
                local obj = e.Object
                local who = obj and obj:IsValid() and (obj:GetAddress() == twin:GetAddress() and "car" or obj:GetClass():GetFName():ToString()) or "?"
                b[#b + 1] = dn:gsub("OnInteract", "") .. "->" .. who .. ":" .. e.FunctionName:ToString()
            end
        end
    end
    o[#o + 1] = string.format("%s [%s]", hc:GetFName():ToString(), table.concat(b, " "))
end
o[#o + 1] = "total " .. #comps
return table.concat(o, "\n")
