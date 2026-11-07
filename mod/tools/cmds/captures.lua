-- the cars' mirror captures: whose actors the HiddenActors list holds (this car / its parts, the other car / its
-- parts, other, invalid)
local o = {}
local own = _G.CoopPlayers and _G.CoopPlayers.ownCarActor() or nil
local function rootOf(a)
    local cur, g = a, 0
    while g < 10 do
        local p = cur:GetAttachParentActor()
        if not (p and p:IsValid()) then return cur end
        cur, g = p, g + 1
    end
    return cur
end
for _, c in ipairs(FindAllOf("SceneCaptureComponent2D") or {}) do
    if c:IsValid() and c:GetFName():ToString() == "ScenecaptureMirror" then
        local a = c:GetOwner()
        local an = a:GetFName():ToString()
        if own and a:GetAddress() == own:GetAddress() then an = "OWN:" .. an end
        local self, other, misc, bad, selfDirect = 0, 0, 0, 0, false
        local arr = c.HiddenActors
        for i = 1, arr:GetArrayNum() do
            local ok = pcall(function()
                local v = arr[i]
                if not (v and v:IsValid()) then bad = bad + 1 return end
                if v:GetAddress() == a:GetAddress() then selfDirect = true end
                local r = rootOf(v)
                if r:GetAddress() == a:GetAddress() then self = self + 1
                elseif r:GetClass():GetFName():ToString() == "BP_PlayerCarNew_C" then other = other + 1
                else misc = misc + 1 end
            end)
            if not ok then bad = bad + 1 end
        end
        o[#o + 1] = string.format("%s hidden=%d: this car's=%d (car itself %s) other car's=%d misc=%d invalid=%d mode=%s",
            an, arr:GetArrayNum(), self, tostring(selfDirect), other, misc, bad, tostring(c.PrimitiveRenderMode))
    end
end
return table.concat(o, "\n")
