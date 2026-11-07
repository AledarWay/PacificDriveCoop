-- The zone's level transitions (entrances / exits / closed gates) with their state, and where the own car is:
-- to compare host and guest (owner: "different exits marked on the map, we appeared at different places").
local out = {}
local function L(v) return string.format("%.0f,%.0f,%.0f", v.X, v.Y, v.Z) end
for _, e in ipairs(FindAllOf("BP_LevelTransition_Base_C") or {}) do
    if e:IsValid() and not e:GetFullName():find("Default__", 1, true) then
        local r = { e:GetFName():ToString(), e:GetClass():GetFName():ToString(), L(e:K2_GetActorLocation()) }
        for _, f in ipairs({ "ExitActive", "EntranceActive", "Exit Visible", "Entrance Visible", "Closed Visible", "IsGarageExit", "Can Embark" }) do
            local ok, v = pcall(function() return e[f] end)
            if ok and v ~= nil then r[#r + 1] = f:gsub(" ", "") .. "=" .. tostring(v) end
        end
        out[#out + 1] = table.concat(r, " ")
    end
end
table.sort(out)
local car = FindFirstOf("BP_CarManager_C").NewCarActor
out[#out + 1] = "car " .. L(car:K2_GetActorLocation()) .. " yaw=" .. string.format("%.0f", car:K2_GetActorRotation().Yaw)
out[#out + 1] = "world " .. FindFirstOf("DrivingGameInstance"):GetWorld():GetFName():ToString()
return table.concat(out, "\n")
