-- Which render target each car's mirrors read (owner's alpha 18 item 34: the host's own mirrors froze on a picture
-- from the start): the interior's and the front doors' RearviewMirrorRT against the car's own capture target and the
-- other car's. "<car>: cap=<rt> interior=<rt|OTHER|OWN> doors=<...>"
local cars = {}
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
    local r = c:IsValid() and c.RootComponent
    if r and r:IsValid() then cars[#cars + 1] = c end
end
local function rtOf(car) local ok, rt = pcall(function() return car.ScenecaptureMirror.TextureTarget end) return ok and rt and rt:IsValid() and rt or nil end
local function who(rt, car)
    if not (rt and rt:IsValid()) then return "none" end
    for _, c in ipairs(cars) do
        local x = rtOf(c)
        if x and x:GetAddress() == rt:GetAddress() then return (c:GetAddress() == car:GetAddress() and "OWN:" or "OTHER:") .. rt:GetFName():ToString() end
    end
    return rt:GetFName():ToString()
end
local function mirrorParams(mesh, car, acc)
    for mi = 0, mesh:GetNumMaterials() - 1 do
        pcall(function()
            local mat = mesh:GetMaterial(mi)
            for k = 1, #mat.TextureParameterValues do
                local x = mat.TextureParameterValues[k]
                if x.ParameterInfo.Name:ToString() == "RearviewMirrorRT" then acc[#acc + 1] = who(x.ParameterValue, car) end
            end
        end)
    end
end
local out = {}
for _, car in ipairs(cars) do
    local inter, doors = {}, {}
    pcall(mirrorParams, car.Interior, car, inter)
    for _, d in ipairs(FindAllOf("BP_CarPart_Door_Base_C") or {}) do
        local p = d:IsValid() and d:GetAttachParentActor()
        if p and p:IsValid() and p:GetAddress() == car:GetAddress() and d.MainMesh then pcall(mirrorParams, d.MainMesh, car, doors) end
    end
    out[#out + 1] = string.format("%s cap=%s mgr=%s: interior=%s doors=%s", car:GetFName():ToString(), rtOf(car) and rtOf(car):GetFName():ToString() or "-", tostring(FindFirstOf("BP_CarManager_C").NewCarActor:GetAddress() == car:GetAddress()), table.concat(inter, ","), table.concat(doors, ","))
end
return table.concat(out, " | ")
