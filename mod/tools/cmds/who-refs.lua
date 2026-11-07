-- Which object-reference properties of the usual singletons (managers, the player character, controller, game
-- instance) point at the actor REFS_TARGET (an object path), e.g. a spawned car copy that hijacked them.
-- Reads ObjectProperty values only (reading every property type generically crashed the game once).
local target = StaticFindObject(REFS_TARGET)
if not target then return "target not found" end
local tname = target:GetFullName()
local out, seen = {}, 0
local function scan(obj, label)
    local cls, guard = obj:GetClass(), 0
    while cls and cls:IsValid() and guard < 10 do
        pcall(function()
            cls:ForEachProperty(function(p)
                local okT, ty = pcall(function() return p:GetClass():GetFName():ToString() end)
                if okT and ty == "ObjectProperty" then
                    local n = p:GetFName():ToString()
                    local ok, v = pcall(function() return obj[n] end)
                    seen = seen + 1
                    if ok and v and type(v) == "userdata" then
                        local okN, fn = pcall(function() return v:GetFullName() end)
                        if okN and fn == tname then out[#out + 1] = label .. "." .. n end
                    end
                end
            end)
        end)
        local ok, sup = pcall(function() return cls:GetSuperStruct() end)
        if not ok or not sup or not sup:IsValid() then break end
        cls = sup
        guard = guard + 1
    end
end
local names = { "BP_CarManager_C", "BP_MainCharacterManager_C", "BP_ProgressionManager_C", "BP_SaveGameManager_C",
    "BP_HazardManager_C", "BP_GameModeDriving_C", "DrivingGameInstance", "PlayerController" }
for _, n in ipairs(names) do
    for _, o in ipairs(FindAllOf(n) or {}) do if o:IsValid() and not o:GetFullName():find("Default__", 1, true) then scan(o, n) end end
end
local pc = FindFirstOf("PlayerController")
if pc and pc.Pawn and pc.Pawn:IsValid() then scan(pc.Pawn, "Pawn") end
for _, o in ipairs(FindAllOf("BaseManager") or {}) do
    if o:IsValid() and not o:GetFullName():find("Default__", 1, true) then scan(o, o:GetClass():GetFName():ToString()) end
end
return string.format("scanned %d object props; pointing at the target: %s", seen, #out > 0 and table.concat(out, " ") or "none")
