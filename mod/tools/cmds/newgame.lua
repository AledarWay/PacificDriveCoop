local sg = FindFirstOf("BP_SaveGameManager_C")
Dev.out("SG", Dev.name(sg))
sg:UserNewGame(1, 1)
return "UserNewGame called"
