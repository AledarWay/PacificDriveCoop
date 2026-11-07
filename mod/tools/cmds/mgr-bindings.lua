-- The car manager's delegates and who is bound to them: class.function [own | TWIN | other | -] (own / twin: an actor
-- or component of that car). Only actors and components are walked (an actor's function on a widget raises an error
-- through Lua: that broke the Lua state - two crashed probes).
local T = _G.CoopPlayers.twinModule()
local own = T.ownCar()
local m = FindFirstOf("BP_CarManager_C")
local ACT, COMP = StaticFindObject("/Script/Engine.Actor"), StaticFindObject("/Script/Engine.ActorComponent")
local function whose(o)
    local root
    if o and o:IsValid() then
        if o:IsA(ACT) then root = o elseif o:IsA(COMP) then root = o:GetOwner() end
    end
    if not root then return "-" end
    local g = 0
    while root and root:IsValid() and g < 10 do
        local p = root:GetAttachParentActor()
        if not (p and p:IsValid()) then break end
        root, g = p, g + 1
    end
    if T.isTwin(root) then return "TWIN" end
    if own and root:GetAddress() == own:GetAddress() then return "own" end
    return "other"
end
local out = {}
for _, dn in ipairs(MB_DELS or { "OnPlayerStartExitCar", "OnPlayerFinishExitCar", "OnDoorChanged" }) do
    local b = {}
    local ok, e = pcall(function()
        for _, x in ipairs(m[dn]:GetBindings() or {}) do
            local o = x.Object
            local cls = o and o:IsValid() and o:GetClass():GetFName():ToString() or "nil"
            b[#b + 1] = cls .. "." .. x.FunctionName:ToString():sub(1, 50) .. "[" .. whose(o) .. "]"
        end
    end)
    out[#out + 1] = dn .. " (" .. #b .. (ok and "" or " ERR " .. tostring(e)) .. "): " .. table.concat(b, " ")
end
MB_DELS = nil
return table.concat(out, "\n")
