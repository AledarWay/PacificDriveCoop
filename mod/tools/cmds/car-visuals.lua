-- What the player car is drawn with, beyond plain meshes: component classes on the car and its attached actors,
-- and the glass / dash parts (names matching CAR_VIS_MATCH) with their materials, blend modes and texture
-- parameters that point at transient objects (render targets: a ghost cannot load those by path).
local Sync = dofile("C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua")
local match = CAR_VIS_MATCH or "[Ww]ind[sow]|[Gg]lass|[Dd]ash|[Gg]auge|[Ss]peedo|[Ss]creen|[Dd]isplay|[Mm]eter"
local car
for _, x in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
    if x:IsValid() and x:GetFullName():find(":PersistentLevel%.") then car = x break end
end
if not car then return "no car" end
local actors = { car }
for _, a in ipairs(FindAllOf("Actor") or {}) do
    local ok, p = pcall(function() return Sync.parentOf(a) end)
    local g = 0
    while ok and p and g < 6 do
        if p:GetAddress() == car:GetAddress() then actors[#actors + 1] = a break end
        ok, p = pcall(function() return Sync.parentOf(p) end)
        g = g + 1
    end
end
local SC = StaticFindObject("/Script/Engine.SceneComponent")
local PC = StaticFindObject("/Script/Engine.PrimitiveComponent")
local SMC = StaticFindObject("/Script/Engine.StaticMeshComponent")
local SKC = StaticFindObject("/Script/Engine.SkeletalMeshComponent")
local classes, hits = {}, {}
for _, a in ipairs(actors) do
    local comps = a:K2_GetComponentsByClass(SC)
    for i = 1, #comps do
        local c = comps[i]:get()
        local cn = c:GetClass():GetFName():ToString()
        classes[cn] = (classes[cn] or 0) + 1
        local name = c:GetFName():ToString() .. "@" .. a:GetFName():ToString()
        local mesh = ""
        -- (a property the class does not have crashes UE4SS natively: read StaticMesh / SkeletalMesh only on their classes)
        if c:IsA(SMC) then pcall(function() mesh = c.StaticMesh:GetFName():ToString() end)
        elseif c:IsA(SKC) then pcall(function() mesh = c.SkeletalMesh:GetFName():ToString() end) end
        if c:IsA(PC) and (name .. " " .. mesh):match(match) and #hits < 40 then
            local mats = {}
            pcall(function()
                for mi = 0, c:GetNumMaterials() - 1 do
                    local m = c:GetMaterial(mi)
                    if m and m:IsValid() then
                        local s = m:GetClass():GetFName():ToString():gsub("Material", "M") .. ":" .. m:GetFName():ToString()
                        pcall(function() s = s .. " base=" .. m:GetBaseMaterial():GetFName():ToString() end)
                        if m:GetClass():GetFName():ToString() ~= "Material" then pcall(function()
                            for k = 1, #m.TextureParameterValues do
                                local x = m.TextureParameterValues[k]
                                local t = x.ParameterValue
                                if t and t:IsValid() then
                                    local full = t:GetFullName()
                                    if full:find("Transient", 1, true) or full:find("RenderTarget", 1, true) then
                                        s = s .. " RT:" .. x.ParameterInfo.Name:ToString() .. "=" .. t:GetClass():GetFName():ToString()
                                    end
                                end
                            end
                        end) end
                        mats[#mats + 1] = s
                    end
                end
            end)
            local vis = ""
            pcall(function() vis = c:IsVisible() and "vis" or "hid" end)
            hits[#hits + 1] = cn .. " " .. name .. " mesh=" .. mesh .. " " .. vis .. " [" .. table.concat(mats, " ; ") .. "]"
        end
    end
end
local cl = {}
for k, v in pairs(classes) do cl[#cl + 1] = k .. "=" .. v end
table.sort(cl)
return "actors=" .. #actors .. " classes: " .. table.concat(cl, " ") .. "\n" .. table.concat(hits, "\n")
