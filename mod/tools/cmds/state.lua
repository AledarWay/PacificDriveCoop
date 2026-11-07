local gi = FindFirstOf("DrivingGameInstance")
if not gi or not gi:IsValid() then
    for _, o in ipairs(FindAllOf("GameInstance") or {}) do gi = o end
end
Dev.out("GI", Dev.name(gi))
Dev.out("MasterSeed", gi.MasterSeed, "State", gi.CurrentGameplayState, "InGarage", gi.bIsInGarage)
local w = gi:GetWorld()
Dev.out("World", Dev.name(w))
local n = gi.ActiveManagers:GetArrayNum()
for i = 1, n do Dev.out("mgr", Dev.name(gi.ActiveManagers[i])) end
return n
