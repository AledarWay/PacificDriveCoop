local pm = FindFirstOf("BP_ProgressionManager_C")
local out = {}
pm:TravelToGarage(0, true, false, false, 1, out)
for k, v in pairs(out) do Dev.out("out", k, tostring(v)) end
return "TravelToGarage called"
