local gi = FindFirstOf("DrivingGameInstance")
return string.format("seed=%d state=%d world=%s", gi.MasterSeed, gi.CurrentGameplayState, gi:GetWorld():GetFName():ToString())
