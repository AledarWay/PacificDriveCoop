-- the twin's side mirrors: twincar stats, then mirrorDoors called now (errors shown) and the door materials after it
local o = {}
local T = _G.CoopPlayers and _G.CoopPlayers.twinModule()
if not T then return "no twin module" end
local own = T.ownCar()
o[#o + 1] = "stats: mirror=" .. tostring(T.stats.mirror) .. " mirrorDoors=" .. tostring(T.stats.mirrorDoors) .. " mirrorHidden=" .. tostring(T.stats.mirrorHidden) .. " err=" .. tostring(T.stats.mirrorErr)
local function rtOfDoors(car)
    local t = {}
    for _, d in ipairs(FindAllOf("BP_CarPart_Door_Base_C") or {}) do
        local par = d:IsValid() and d:GetAttachParentActor()
        if par and par:IsValid() and par:GetAddress() == car:GetAddress() then
            pcall(function()
                local m = d.MainMesh:GetMaterial(6)
                for k = 1, #m.TextureParameterValues do
                    local x = m.TextureParameterValues[k]
                    if x.ParameterInfo.Name:ToString() == "RearviewMirrorRT" then
                        t[#t + 1] = m:GetFName():ToString() .. "=" .. (x.ParameterValue:IsValid() and x.ParameterValue:GetFName():ToString() or "nil")
                    end
                end
            end)
        end
    end
    return table.concat(t, " ")
end
for _, car in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
    if car:IsValid() and T.isTwin(car) then
        o[#o + 1] = "twin capRT=" .. car.ScenecaptureMirror.TextureTarget:GetFName():ToString()
        o[#o + 1] = "  before: " .. rtOfDoors(car)
        local ok, n = pcall(T._mirrorDoors, car)
        o[#o + 1] = "  mirrorDoors: " .. tostring(ok) .. " " .. tostring(n)
        o[#o + 1] = "  after: " .. rtOfDoors(car)
        if own then
            local ok2, h = pcall(T._mirrorHidden, own, car)
            o[#o + 1] = "  mirrorHidden: " .. tostring(ok2) .. " " .. tostring(h) .. " " .. tostring(T.stats.mirrorHidden)
        end
    end
end
return table.concat(o, "\n")
