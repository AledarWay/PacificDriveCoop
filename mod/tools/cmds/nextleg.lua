local lib = StaticFindObject("/Game/Systems/ScriptingLibraries/BFL_ProgressionHelpers.Default__BFL_ProgressionHelpers_C")
local pc = FindFirstOf("PlayerController")
Dev.out("lib", Dev.name(lib), "pc", Dev.name(pc))
lib:TravelToNextLeg(pc)
return "TravelToNextLeg called"
