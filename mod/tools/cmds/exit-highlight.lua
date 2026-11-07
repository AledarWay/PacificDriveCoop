-- What the cars' exit highlight outlines (owner's alpha 18 items 13 / 19: a passenger getting out saw the DRIVER's door
-- highlighted): Highlight_ExitDoor's HighlightVisuals / HighlightCollision, per live car.
local out = {}
local function nm(x)
    if not (x and x:IsValid()) then return "-" end
    local o = x:GetOwner()
    return (o and o:IsValid() and o:GetFName():ToString() or "?") .. "." .. x:GetFName():ToString()
end
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
    pcall(function()
        local r = c.RootComponent
        if not (c:IsValid() and r and r:IsValid()) then return end
        local h = c.Highlight_ExitDoor
        local v, k = {}, {}
        pcall(function() for i = 1, h.HighlightVisuals:GetArrayNum() do v[#v + 1] = nm(h.HighlightVisuals[i]) end end)
        pcall(function() for i = 1, h.HighlightCollision:GetArrayNum() do k[#k + 1] = nm(h.HighlightCollision[i]) end end)
        out[#out + 1] = c:GetFName():ToString() .. " visuals=" .. table.concat(v, ",") .. " collision=" .. table.concat(k, ",")
    end)
end
return table.concat(out, " | ")
