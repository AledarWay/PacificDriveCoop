-- The own car's live bits that froze on the host in the owner's alpha 18 test (items 34, 35): the rear-view mirror
-- capture (active / every frame / its target) and the steering wheel (its mesh's yaw vs the car's steering input),
-- per car (own / twin), plus the manager's context and the controller's car.
local function first(c) return (CoopSyncFirst or FindFirstOf)(c) end
local m = first("BP_CarManager_C")
local ctl = first("BP_Controller_PlayerCar_C")
local twins = _G.CoopSyncTwins or {}
local out = {}
local function nm(a) return a and a:IsValid() and a:GetFName():ToString() or "none" end
out[#out + 1] = "mgr=" .. nm(m and m.NewCarActor) .. " ctl=" .. nm(ctl and ctl.PlayerCarReference)
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
    pcall(function()
        local r = c.RootComponent
        if not (c:IsValid() and r and r:IsValid()) then return end
        local s = nm(c) .. (twins[c:GetAddress()] and "(twin)" or "")
        local cap = c.ScenecaptureMirror
        if cap and cap:IsValid() then
            local rt = cap.TextureTarget
            s = s .. string.format(" mirror active=%s every=%s move=%s rt=%s", tostring(cap:IsActive()), tostring(cap.bCaptureEveryFrame),
                tostring(cap.bCaptureOnMovement), nm(rt))
        end
        for _, a in ipairs(FindAllOf("BP_CarPart_SteeringWheel_Base_C") or {}) do
            local p = a:IsValid() and a:GetAttachParentActor()
            if p and p:IsValid() and p:GetAddress() == c:GetAddress() then
                local rr = a.MainMesh.RelativeRotation
                s = s .. string.format(" wheel=%.1f,%.1f,%.1f", rr.Pitch, rr.Yaw, rr.Roll)
            end
        end
        pcall(function()
            local vm = c.VehicleMovement or c:GetVehicleMovementComponent()
            s = s .. string.format(" steer_in=%.2f thr=%.2f", vm:GetSteeringInput(), vm:GetThrottleInput())
        end)
        out[#out + 1] = s
    end)
end
return table.concat(out, " | ")
