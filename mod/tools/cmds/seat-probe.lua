-- The car's seat geometry as built (plan item "the seats' coordinates as constants", owner 2026-11-14): every
-- component of the own car whose name speaks of a seat / exit / entry / passenger, with its place relative to the car
-- (actor space), and the body mesh's sockets of that kind. Read-only: no setter is called.
local car = CoopPlayers and CoopPlayers.twinModule().ownCar()
if not car then
    for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() then car = c break end end
end
if not (car and car:IsValid()) then return "no car" end
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local inv = car:GetTransform()
local out = {}
local function rel(w)
    local l = KML:InverseTransformLocation(inv, w)
    return string.format("%.1f,%.1f,%.1f", l.X, l.Y, l.Z)
end
local SC = StaticFindObject("/Script/Engine.SceneComponent")
local comps = car:K2_GetComponentsByClass(SC)
for i = 1, #comps do
    local c = comps[i]:get()
    if c and c:IsValid() then
        local n = c:GetFName():ToString()
        local low = n:lower()
        if low:find("seat") or low:find("exit") or low:find("entry") or low:find("passeng") or low:find("door") then
            local ok, w = pcall(function() return c:K2_GetComponentLocation() end)
            out[#out + 1] = n .. " " .. (ok and rel(w) or "?")
        end
    end
end
pcall(function()
    local mesh = car.Mesh or car.RootComponent
    local names = mesh:GetAllSocketNames()
    for i = 1, #names do
        local s = names[i]:get():ToString()
        local low = s:lower()
        if low:find("seat") or low:find("pass") or low:find("exit") or low:find("door") or low:find("driver") then
            local w = mesh:GetSocketLocation(names[i]:get())
            out[#out + 1] = "socket " .. s .. " " .. rel(w)
        end
    end
end)
table.sort(out)
return #out .. " found\n" .. table.concat(out, "\n")
