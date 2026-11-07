-- Mirrors and screens of the own car vs the twin (the manager's car while sitting in it): scene captures, their
-- render targets, capture flags; screen part actors and their tick / electrical helper.
local cm = FindFirstOf("BP_CarManager_C")
local own = _G.CoopPlayers.ownCarActor()
local tw = cm.NewCarActor
local SCC = StaticFindObject("/Script/Engine.SceneCaptureComponent2D")
local function under(a, car) local p = a:GetAttachParentActor() return p and p:IsValid() and p:GetAddress() == car:GetAddress() end
local function caps(car, tag)
    local o = {}
    local list = { car }
    for _, a in ipairs(FindAllOf("Actor") or {}) do if a:IsValid() and under(a, car) then list[#list + 1] = a end end
    for _, a in ipairs(list) do
        local cs = a:K2_GetComponentsByClass(SCC)
        for i = 1, #cs do
            local c = cs[i]:get()
            local rt = c.TextureTarget
            o[#o + 1] = string.format("%s %s/%s rt=%s every=%s move=%s active=%s vis=%s", tag, a:GetClass():GetFName():ToString(), c:GetFName():ToString(),
                rt and rt:IsValid() and rt:GetFName():ToString() or "-", tostring(c.bCaptureEveryFrame), tostring(c.bCaptureOnMovement), tostring(c:IsActive()), tostring(c:IsVisible()))
        end
    end
    return o
end
local out = {}
for _, l in ipairs(caps(own, "OWN")) do out[#out + 1] = l end
if tw:GetAddress() ~= own:GetAddress() then for _, l in ipairs(caps(tw, "TWIN")) do out[#out + 1] = l end end
return table.concat(out, "\n")
