-- The world of this side in one form (world-compare.ps1 diffs the host's and the guest's): owner's alpha 18 test -
-- the sun, clouds, a street lamp, the abandoned cars' colours and doors, a whole trial zone differed between the two.
-- Lines written to WORLD_OUT:
--   tod <time of day 0..1>
--   sun <pitch>,<yaw> of the directional light(s)
--   event <the ToD director's current weather event or ->
--   cls <class> <count> <x,y,z;...>  every actor of the player's world by class, places to 1 m (sorted, at most 300)
--   mat <class> <material names of the first mesh component;...>  the looks of some classes (CLS_LOOKS)
local pc = FindFirstOf("PlayerController")
local world = pc:GetWorld():GetAddress()
local out = {}
local function put(k, v) out[#out + 1] = k .. " " .. tostring(v == nil and "-" or v):gsub("[\r\n]", " ") end

local m = FindFirstOf("BP_ToDManager_C")
if m and m:IsValid() then
    local cur = {}
    pcall(function() m["Get Current Time Of Day"](m, cur) end)
    put("tod", string.format("%.4f", cur["Returned Time Of Day"] or -1))
end
local suns = {}
for _, l in ipairs(FindAllOf("DirectionalLight") or {}) do
    if l:IsValid() and l:GetWorld():GetAddress() == world then
        local r = l:K2_GetActorRotation()
        suns[#suns + 1] = string.format("%.0f,%.0f", r.Pitch, r.Yaw)
    end
end
table.sort(suns)
put("sun", #suns > 0 and table.concat(suns, ";") or "-")
local d = FindFirstOf("BP_ToDDirector_C")
local ev = "-"
pcall(function() local c = d.CurrentTODEvent if c and c:IsValid() then ev = c:GetClass():GetFName():ToString() end end)
put("event", ev)

-- classes whose looks are compared too (materials of the first mesh)
local LOOKS = { "BP_AbandonedCar", "Abandoned", "StreetLight", "Lamp" }
local function wantLooks(c) for _, k in ipairs(LOOKS) do if c:find(k, 1, true) then return true end end return false end
local by = {}
for _, a in ipairs(FindAllOf("Actor") or {}) do
    pcall(function()
        if not a:IsValid() or a:GetWorld():GetAddress() ~= world then return end
        local r = a.RootComponent
        if not (r and r:IsValid()) then return end
        local c = a:GetClass():GetFName():ToString()
        local e = by[c]
        if not e then e = { n = 0, at = {} } by[c] = e end
        e.n = e.n + 1
        if #e.at < 300 then
            local l = a:K2_GetActorLocation()
            e.at[#e.at + 1] = string.format("%.0f,%.0f,%.0f", l.X / 100, l.Y / 100, l.Z / 100)
        end
        if wantLooks(c) and not e.mats then
            local mats = {}
            pcall(function()
                local mc = a:GetComponentByClass(StaticFindObject("/Script/Engine.MeshComponent"))
                for i = 0, mc:GetNumMaterials() - 1 do
                    local mi = mc:GetMaterial(i)
                    mats[#mats + 1] = mi and mi:IsValid() and mi:GetFName():ToString() or "-"
                end
            end)
            e.mats = table.concat(mats, ";")
        end
    end)
end
local names = {}
for c in pairs(by) do names[#names + 1] = c end
table.sort(names)
for _, c in ipairs(names) do
    local e = by[c]
    table.sort(e.at)
    put("cls", c .. " " .. e.n .. " " .. table.concat(e.at, ";"))
    if e.mats then put("mat", c .. " " .. e.mats) end
end
local f = io.open(WORLD_OUT, "wb")
f:write(table.concat(out, "\n") .. "\n")
f:close()
WORLD_OUT = nil
return "world " .. #names .. " classes"
