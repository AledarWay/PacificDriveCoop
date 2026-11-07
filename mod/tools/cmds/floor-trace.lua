-- The car's floor under the seated puppet's feet: line traces (multi, complex) straight down through the own car at
-- car-local points (FLOOR_PTS: {X, Y} list; default the puppet's feet at seats 1 and 3), from Z +60 to Z -120.
-- Every hit: car-local Z, actor class, component.
local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local car = _G.CoopPlayers and _G.CoopPlayers.ownCarActor() or FindFirstOf("BP_PlayerCarNew_C")
local xf = car:GetTransform()
local CH = FLOOR_CH or 0
local pts = FLOOR_PTS or { { 81, -69, "s1 heel" }, { 97, -72, "s1 toe" }, { 60, -46, "s1 under seat" }, { -25, -69, "s3 heel" }, { -9, -72, "s3 toe" }, { -60, -46, "s3 under seat" }, { 81, -100, "s1 sill" }, { 0, 0, "centre" } }
local o = {}
for _, p in ipairs(pts) do
    local a = KML:TransformLocation(xf, { X = p[1], Y = p[2], Z = 60 })
    local b = KML:TransformLocation(xf, { X = p[1], Y = p[2], Z = FLOOR_LOW or -400 })
    local hits = {}
    local ok, e = pcall(function()
        KSL:LineTraceMulti(car, a, b, CH, true, {}, 0, hits, false, { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0)
    end)
    local t = {}
    if not ok then t[1] = "ERR " .. tostring(e) end
    for i = 1, #hits do
        pcall(function()
            local h = hits[i]:get()
            local l = KML:InverseTransformLocation(xf, h.ImpactPoint)
            local act = h.Actor:Get()
            local comp = h.Component:Get()
            t[#t + 1] = string.format("%.0f %s.%s", l.Z, act and act:IsValid() and act:GetClass():GetFName():ToString() or "?", comp and comp:IsValid() and comp:GetFName():ToString() or "?")
        end)
    end
    o[#o + 1] = string.format("%s (%d,%d): %s", p[3], p[1], p[2], #t > 0 and table.concat(t, " | ") or "no hits")
end
return table.concat(o, "\n")
