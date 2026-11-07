local K = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local before = K:RandomFloat()
RegisterHook("/Script/Engine.KismetMathLibrary:RandomFloat", function() return 0.25 end)
local a = K:RandomFloat()
Dev.out("before", before, "after hook (want 0.25)", a)
return "x"
