-- The twin's door n (DOOR_N, default 1): the highlight components on it and on its interactive part, their OnInteract*
-- bindings (UE4SS multicast delegate property: GetBindings / Remove). UNBIND = true removes the bindings whose object
-- is the twin's door or its interactive part (the game's E there would then do nothing).
local T = _G.CoopPlayers.twinModule()
local twin
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then twin = c end end
if not twin then return "no twin" end
local n = DOOR_N or 1
local door = T.door(twin, n)
if not door then return "no door " .. n end
local HC = StaticFindObject("/Script/PenDriverPro.HighlightComponent")
local DELS = { "OnInteract", "OnInteractShort", "OnInteractLong", "OnInteractStartLong", "OnInteractStart", "OnInteractEnd", "OnStateChanged" }
local o = {}
local function actorsOf()
    local list = { door }
    for _, a in ipairs(FindAllOf("BP_CarPart_Interactive_C") or {}) do
        if a:IsValid() then
            local out = {}
            pcall(function() a:GetSlotComponent(out) end)
            local sc = out.SlotSceneComponent
            if sc and sc:IsValid() and sc:GetOwner():GetAddress() == twin:GetAddress() and sc.SlotName.TagName:ToString():find("Doors", 1, true) then
                local sa = sc.SpawnedActor
                if sa and sa:IsValid() and sa:GetAddress() == door:GetAddress() then list[#list + 1] = a end
            end
        end
    end
    return list
end
local removed = 0
for _, a in ipairs(actorsOf()) do
    local comps = a:K2_GetComponentsByClass(HC)
    for i = 1, #comps do
        local hc = comps[i]:get()
        for _, dn in ipairs(DELS) do
            local ok, b = pcall(function() return hc[dn]:GetBindings() end)
            if not ok then o[#o + 1] = a:GetClass():GetFName():ToString() .. "." .. hc:GetFName():ToString() .. "." .. dn .. " ERR " .. tostring(b)
            elseif b and #b > 0 then
                for _, e in ipairs(b) do
                    local obj, fn = e.Object, e.FunctionName
                    local on = obj and obj:IsValid() and obj:GetClass():GetFName():ToString() or "?"
                    local mine = obj and obj:IsValid() and (obj:GetAddress() == a:GetAddress() or obj:GetAddress() == door:GetAddress())
                    o[#o + 1] = string.format("%s.%s.%s -> %s:%s%s", a:GetClass():GetFName():ToString(), hc:GetFName():ToString(), dn, on, fn:ToString(), mine and " (twin)" or "")
                    if _G.UNBIND and mine and dn ~= "OnStateChanged" then
                        local okR, er = pcall(function() hc[dn]:Remove(obj, fn) end)
                        if okR then removed = removed + 1 else o[#o + 1] = "  remove failed: " .. tostring(er) end
                    end
                end
            end
        end
    end
end
o[#o + 1] = "removed " .. removed
UNBIND, DOOR_N = nil, nil
return table.concat(o, "\n")
