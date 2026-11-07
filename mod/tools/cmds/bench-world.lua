-- Cost of the calls the sync loops make every 100 ms / every second (ms per call).
local function ms(f, n)
    local t0 = os.clock()
    for _ = 1, n do f() end
    return (os.clock() - t0) * 1000 / n
end
local r = {}
r[#r + 1] = string.format("FindFirstOf(DrivingGameInstance)=%.3f", ms(function() return FindFirstOf("DrivingGameInstance") end, 20))
local gi = FindFirstOf("DrivingGameInstance")
r[#r + 1] = string.format("gi:GetWorld()=%.3f", ms(function() return gi:GetWorld() end, 20))
r[#r + 1] = string.format("GetWorld():GetFName():ToString()=%.3f", ms(function() return gi:GetWorld():GetFName():ToString() end, 20))
r[#r + 1] = string.format("gi.CurrentGameplayState=%.3f", ms(function() return gi.CurrentGameplayState end, 20))
r[#r + 1] = string.format("FindFirstOf(PlayerController)=%.3f", ms(function() return FindFirstOf("PlayerController") end, 20))
r[#r + 1] = string.format("FindFirstOf(BP_InventoryManager_C)=%.3f", ms(function() return FindFirstOf("BP_InventoryManager_C") end, 20))
r[#r + 1] = string.format("FindFirstOf(World)=%.3f", ms(function() return FindFirstOf("World") end, 5))
return table.concat(r, " | ")
