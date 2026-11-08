-- The light of this side's world, for a host / guest comparison (owner's alpha 20 test: "the host's zone looked
-- brighter, the guest's darker"): time of day, the north, the sun (directional lights: direction, intensity,
-- colour), the sky light, the height fog, the weather overrides' darkness. One line: key=value ...
local out = {}
local function add(k, v) out[#out + 1] = k .. "=" .. tostring(v) end
local function r2(x) return x and string.format("%.2f", x) or "?" end
pcall(function()
    local m = FindFirstOf("BP_ToDManager_C")
    local t = {}
    m["Get Current Time Of Day"](m, t)
    add("tod", string.format("%.4f", t["Returned Time Of Day"]))
end)
-- (the north: CurrentTrueNorth is a vector - read as a number it failed and both fields were missing)
pcall(function()
    local m = FindFirstOf("BP_ToDManager_C")
    add("north", string.format("%d,%.1f,%.1f", m.DataBlock_IsUsingRandomNorth and 1 or 0, m.DataBlock_PickedRandomNorth.Yaw, m["Current North As Rotator"].Yaw))
    local v = m.CurrentTrueNorth
    add("truenorth", string.format("%.2f,%.2f", v.X, v.Y))
    -- (the ARC map's view: its yaw comes from the north when it spawns)
    local w = FindFirstOf("PlayerController").Pawn:GetFullName():match("^%S+%s+/[^.]*%.([^:]+):PersistentLevel")
    local mv = "-"
    for _, a in ipairs(FindAllOf("BP_GobblerMapview_C") or {}) do
        if a:IsValid() and w and a:GetFullName():find("." .. w .. ":PersistentLevel", 1, true) then mv = r2(a:K2_GetActorRotation().Yaw) end
    end
    add("arcyaw", mv)
    add("todyaw", r2(m:K2_GetActorRotation().Yaw))
    local sim = m.ToDSimulationActor
    if sim and sim:IsValid() then add("simyaw", r2(sim:K2_GetActorRotation().Yaw)) end
end)
local suns = {}
for _, c in ipairs(FindAllOf("DirectionalLightComponent") or {}) do
    pcall(function()
        if not c:IsValid() or c:GetFullName():find("Default__", 1, true) then return end
        local owner = c:GetOwner()
        if not (owner and owner:IsValid()) then return end
        local r = c:K2_GetComponentRotation()
        local col = c.LightColor
        suns[#suns + 1] = string.format("%s:p%.0f/y%.0f/i%.2f/c%d,%d,%d/v%s", (owner:GetFName():ToString():gsub("_C_%d+$", "")),
            r.Pitch, r.Yaw, c.Intensity, col.R, col.G, col.B, tostring(c:IsVisible()))
    end)
end
table.sort(suns)
add("suns", #suns > 0 and table.concat(suns, ";") or "-")
local sky = {}
for _, c in ipairs(FindAllOf("SkyLightComponent") or {}) do
    pcall(function()
        if c:IsValid() and not c:GetFullName():find("Default__", 1, true) then sky[#sky + 1] = string.format("i%.2f", c.Intensity) end
    end)
end
table.sort(sky)
add("sky", #sky > 0 and table.concat(sky, ",") or "-")
local fog = {}
for _, c in ipairs(FindAllOf("ExponentialHeightFogComponent") or {}) do
    pcall(function()
        if c:IsValid() and not c:GetFullName():find("Default__", 1, true) then fog[#fog + 1] = string.format("d%.4f", c.FogDensity) end
    end)
end
table.sort(fog)
add("fog", #fog > 0 and table.concat(fog, ",") or "-")
return table.concat(out, " ")
