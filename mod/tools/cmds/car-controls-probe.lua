-- Where the car keeps ignition / gearbox / handbrake state: every property of the player car and of its
-- components whose name mentions Ignition, Gear, Reverse, Handbrake or Shifter (name and property type).
local car = FindFirstOf("BP_PlayerCarNew_C")
if not car then return "no car" end
local out = {}
local function scan(obj, label)
    local cls = obj:GetClass()
    local guard = 0
    while cls and cls:IsValid() and guard < 8 do
        pcall(function()
            cls:ForEachProperty(function(p)
                local n = p:GetFName():ToString()
                if n:find("Ignition") or n:find("Gear") or n:find("Reverse") or n:find("Handbrake") or n:find("HandBrake") or n:find("Shift") then
                    -- names and types only: reading every property generically crashed the game
                    local okT, ty = pcall(function() return p:GetClass():GetFName():ToString() end)
                    out[#out + 1] = string.format("%s.%s : %s", label, n, okT and ty or "?")
                end
            end)
        end)
        local ok, sup = pcall(function() return cls:GetSuperStruct() end)
        if not ok or not sup or not sup:IsValid() then break end
        cls = sup
        guard = guard + 1
    end
end
scan(car, "car")
for _, c in ipairs({ "BP_Carpart_Shifter_Base_C", "BP_Attach_Handbrake_C", "BP_CarPart_SteeringWheel_Base_C" }) do
    for _, a in ipairs(FindAllOf(c) or {}) do if a:IsValid() then scan(a, c) end end
end
return table.concat(out, "\n")
