-- the twin's door mirror targets over 4 s after this call (no fix from here): _G.MirrorWatch, read with mirror-watch-read
local T = _G.CoopPlayers.twinModule()
_G.MirrorWatch = { "calls0=" .. tostring(T.stats.mirrorDoorsCalls) }
local function rd(tag)
    local t = { tag }
    for _, car in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
        if car:IsValid() and T.isTwin(car) then
            for _, d in ipairs(FindAllOf("BP_CarPart_Door_Base_C") or {}) do
                local par = d:IsValid() and d:GetAttachParentActor()
                if par and par:IsValid() and par:GetAddress() == car:GetAddress() then
                    pcall(function()
                        local m = d.MainMesh:GetMaterial(6)
                        for k = 1, #m.TextureParameterValues do
                            local x = m.TextureParameterValues[k]
                            if x.ParameterInfo.Name:ToString() == "RearviewMirrorRT" then
                                t[#t + 1] = m:GetFName():ToString():sub(-5) .. "=" .. (x.ParameterValue:IsValid() and x.ParameterValue:GetFName():ToString():sub(1, 6) or "nil")
                            end
                        end
                    end)
                end
            end
        end
    end
    t[#t + 1] = "calls=" .. tostring(T.stats.mirrorDoorsCalls)
    _G.MirrorWatch[#_G.MirrorWatch + 1] = table.concat(t, " ")
end
rd("0ms")
for ms = 250, 9000, 250 do Dev.after(ms, function() rd(ms .. "ms") end) end
return "watching"
