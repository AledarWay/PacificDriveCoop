-- The own car's steering wheel (owner's alpha 18 item 35: the host's own wheel did not turn): SteerLeftRight(1) every
-- frame for STEER_S s through the car's own input function (STEER_VIA = "ctl": the input controller's axis event), then the wheel's state - the car's
-- SteeringWheelRotationCurrent / Target and the wheel part's mesh roll - read into STEER_OUT (global) after it.
local car = FindFirstOf("BP_CarManager_C").NewCarActor
local t0 = os.clock()
STEER_OUT = "running"
local h
h = LoopInGameThreadWithDelay(16, function()
    local dt = os.clock() - t0
    if dt < (STEER_S or 1.5) then
        if STEER_VIA == "ctl" then pcall(function() local c = FindFirstOf("BP_Controller_PlayerCar_C") c["InpAxisEvt_Left/Right_K2Node_InputAxisEvent_7"](c, 1.0) end)
        else pcall(function() car:SteerLeftRight(1.0) end) end
        return
    end
    CancelDelayedAction(h)
    local s = string.format("cur=%.1f target=%.1f axis=%.2f user=%.2f", car.SteeringWheelRotationCurrent, car.SteeringWheelRotationTarget, car.CurrentSteeringAxis, car.UserSteerInput)
    for _, a in ipairs(FindAllOf("BP_CarPart_SteeringWheel_Base_C") or {}) do
        local p = a:IsValid() and a:GetAttachParentActor()
        if p and p:IsValid() and p:GetAddress() == car:GetAddress() then
            -- (the vehicle code moves the wheel by its world transform: read car-relative)
            local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
            local r = KML:InverseTransformRotation(car:GetTransform(), a.MainMesh:K2_GetComponentRotation())
            s = s .. string.format(" mesh=%.1f,%.1f,%.1f", r.Pitch, r.Yaw, r.Roll)
        end
    end
    pcall(function() local r = car.SLOT_Cosmetic_SteeringWheel.RelativeRotation s = s .. string.format(" slot=%.1f,%.1f,%.1f", r.Pitch, r.Yaw, r.Roll) end)
    STEER_OUT = s
end)
return "steering " .. car:GetFName():ToString()
