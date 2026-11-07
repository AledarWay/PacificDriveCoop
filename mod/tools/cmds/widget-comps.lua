-- Every WidgetComponent: owner class, the owner's root actor (own / twin / other), its render target and widget.
local T = _G.CoopPlayers.twinModule()
local own = T.ownCar()
local o = {}
for _, w in ipairs(FindAllOf("WidgetComponent") or {}) do
    if w:IsValid() then
        local a = w:GetOwner()
        local r, g = a, 0
        while r and r:IsValid() and g < 6 do
            local p = r:GetAttachParentActor()
            if not (p and p:IsValid()) then break end
            r, g = p, g + 1
        end
        local tag = "other"
        if r and r:IsValid() then
            if own and r:GetAddress() == own:GetAddress() then tag = "OWN" elseif T.isTwin(r) then tag = "TWIN" end
        end
        local rt = w:GetRenderTarget()
        local wi = w:GetUserWidgetObject()
        o[#o + 1] = tag .. " " .. ((a and a:IsValid()) and a:GetClass():GetFName():ToString() or "?") .. " d" .. g .. " " .. w:GetFName():ToString()
            .. " rt=" .. ((rt and rt:IsValid()) and rt:GetFName():ToString() or "-") .. " w=" .. ((wi and wi:IsValid()) and wi:GetClass():GetFName():ToString() or "-")
    end
end
table.sort(o)
return table.concat(o, "\n")
