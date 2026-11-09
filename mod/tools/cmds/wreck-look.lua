-- An abandoned car's paint as each side draws it (2026-11-09, owner: "all the guest's abandoned cars are orange-blue,
-- for a long time"): the wreck (BP_Template_BaseVehicle_C) nearest WL_AT (or the player); its palettes, and for its own
-- mesh components and each attached part's: material 0 (MID = built by SetupMaterials, else the mesh's own) and its
-- first colour parameter. WL_LOOK: the player is put 6 m from it and turned to it (for a screenshot).
local at = WL_AT or FindFirstOf("PlayerController").Pawn:K2_GetActorLocation()
local best, bd
for _, c in ipairs(FindAllOf("BP_Template_BaseVehicle_C") or {}) do
    if c:IsValid() and c:GetFullName():find(":PersistentLevel.", 1, true) then
        local l = c:K2_GetActorLocation()
        local d = (l.X - at.X) ^ 2 + (l.Y - at.Y) ^ 2
        if math.abs(l.X) + math.abs(l.Y) > 1000 and (not bd or d < bd) then best, bd = c, d end
    end
end
if not best then return "no wreck" end
local l = best:K2_GetActorLocation()
local function n(x) local ok, v = pcall(function() return x:GetFName():ToString() end) return ok and v or "nil" end
local out = { string.format("%s at %.0f,%.0f,%.0f paint=%s decal=%s mids=%d", n(best), l.X, l.Y, l.Z, n(best.SelectedPaintPalette),
    n(best.SelectedDecalPalette), #best.DynamicMaterialInstances) }
local MESH = StaticFindObject("/Script/Engine.MeshComponent")
local function mats(a, label)
    local comps = a:K2_GetComponentsByClass(MESH)
    for i = 1, #comps do
        local m = comps[i]
        local okM, mat = pcall(function() return m:GetMaterial(0) end)
        if okM and mat and mat:IsValid() then
            local cls = mat:GetClass():GetFName():ToString()
            local col = ""
            if cls == "MaterialInstanceDynamic" then
                pcall(function()
                    local arr = mat.VectorParameterValues
                    for j = 1, arr:GetArrayNum() do
                        local e = arr[j]
                        local pn = e.ParameterInfo.Name:ToString()
                        if pn:find("Color") then local v = e.ParameterValue col = string.format(" %s=%.2f,%.2f,%.2f", pn, v.R, v.G, v.B) break end
                    end
                end)
            end
            out[#out + 1] = string.format("%s.%s: %s %s%s", label, n(m), cls == "MaterialInstanceDynamic" and "MID" or cls, n(mat), col)
        end
    end
end
mats(best, "body")
for _, p in ipairs(FindAllOf("LootableTemplatePart") or {}) do
    local par = p:IsValid() and p:GetAttachParentActor()
    if par and par:IsValid() and par:GetAddress() == best:GetAddress() then
        local ok, s = pcall(function() return p.MySocket:ToString() end)
        mats(p, ok and s or "part")
    end
end
if WL_LOOK then
    local pc = FindFirstOf("PlayerController")
    local pawn = pc.Pawn
    pcall(function() local a = pawn:GetAttachParentActor() if a and a:IsValid() then pawn["Command Interact"](pawn, true) end end)
    local ang = math.rad(WL_ANGLE or 30)
    local px, py, pz = l.X + 600 * math.cos(ang), l.Y + 600 * math.sin(ang), l.Z + 150
    pawn:K2_SetActorLocation({ X = px, Y = py, Z = pz }, false, {}, true)
    pc:SetControlRotation({ Pitch = -10, Yaw = math.deg(math.atan(l.Y - py, l.X - px)), Roll = 0 })
    out[#out + 1] = "looking"
end
return table.concat(out, " || ")
