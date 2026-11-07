local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local f = io.open(os.getenv("COOPDEV_DIR") .. "/classdump.txt", "wb")
for _, cls in ipairs({"BP_TpoleTool_C","BP_TpoleTool_Roadside_C","BP_TpoleTool_Roadside_NoGroundingCable_C","BP_Hazard_Tesla_C","BP_WorldItem_Resource_GasPumpHandle_C","BP_Resource_GasPumpBase_C","BP_VolCascade_Radiation_C","BP_Hazard_PhysicsGrabber_C"}) do
  for _, a in ipairs(FindAllOf(cls) or {}) do
    if KSL:IsValid(a) and a:GetFullName():find(":PersistentLevel%.") then
      local l = a:K2_GetActorLocation()
      f:write(string.format("%s\t%s\t%.0f\t%.0f\t%.0f\t%s\n", cls, a:GetFName():ToString(), l.X, l.Y, l.Z, tostring(a.bHidden)))
    end
  end
end
f:close()
return "ok"
