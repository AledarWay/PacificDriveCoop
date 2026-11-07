-- Which car components move while it drives: relative transforms of every scene component of the car and its wheel /
-- steering wheel part actors, sampled before and during a drive (MOVING_PHASE = "a" stores, "b" diffs).
local car = FindFirstOf("BP_CarManager_C").NewCarActor
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local SC = StaticFindObject("/Script/Engine.SceneComponent")
local inv = KML:InvertTransform(car:GetTransform())
local function sample()
    local s = {}
    local actors = { car }
    for _, a in ipairs(FindAllOf("Actor") or {}) do
        if a:IsValid() then
            local p = a:GetAttachParentActor()
            if p and p:IsValid() and p:GetAddress() == car:GetAddress() then
                local c = a:GetClass():GetFName():ToString()
                if c:find("Wheel") or c:find("Steering") then actors[#actors + 1] = a end
            end
        end
    end
    for _, a in ipairs(actors) do
        local comps = a:K2_GetComponentsByClass(SC)
        for i = 1, #comps do
            local c = comps[i]:get()
            local rel = KML:ComposeTransforms(c:K2_GetComponentToWorld(), inv)
            local r = KML:Quat_Rotator(rel.Rotation)
            s[a:GetFName():ToString() .. "." .. c:GetFName():ToString()] = { rel.Translation, r }
        end
    end
    return s
end
if MOVING_PHASE == "a" then MOVING_A = sample() return "stored" end
local b = sample()
local o = {}
for k, v in pairs(b) do
    local a = MOVING_A[k]
    if a then
        local dl = math.sqrt((a[1].X - v[1].X) ^ 2 + (a[1].Y - v[1].Y) ^ 2 + (a[1].Z - v[1].Z) ^ 2)
        local dr = math.abs(a[2].Pitch - v[2].Pitch) + math.abs(a[2].Yaw - v[2].Yaw) + math.abs(a[2].Roll - v[2].Roll)
        if dl > 0.5 or dr > 1 then o[#o + 1] = string.format("%s dl=%.1f dr=%.0f (%.0f,%.0f,%.0f)", k, dl, dr, v[2].Pitch, v[2].Yaw, v[2].Roll) end
    end
end
table.sort(o)
return #o .. " moved\n" .. table.concat(o, "\n")
