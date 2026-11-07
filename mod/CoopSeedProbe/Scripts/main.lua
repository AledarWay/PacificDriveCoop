-- CoopSeedProbe: logs every seed-setting call so we can see where spawn randomness comes from.
local LOG = (os.getenv("COOPDEV_DIR") or "C:/PacificDriveCoop/local/coopdev") .. "/seedprobe.log"

local function log(s)
    local f = io.open(LOG, "ab")
    if f then f:write(os.date("%H:%M:%S ") .. s .. "\n") f:close() end
end

local function val(p)
    local ok, v = pcall(function() return p:get() end)
    if not ok then return "?" end
    if type(v) == "userdata" then
        local ok2, n = pcall(function() return v:GetFullName() end)
        if ok2 then return n end
    end
    return tostring(v)
end

local function hook(path, fmt)
    local ok, err = pcall(function()
        RegisterHook(path, function(ctx, ...)
            local args = {}
            for i, p in ipairs({...}) do args[i] = val(p) end
            local who = "?"
            pcall(function() who = ctx:get():GetFName():ToString() end)
            log(fmt .. " ctx=" .. who .. " args=" .. table.concat(args, ","))
        end)
    end)
    log((ok and "hooked " or ("hook FAILED " .. tostring(err) .. " ")) .. path)
end

log("=== probe loaded")
hook("/Script/PenDriverPro.DrivingGameInstance:SetMasterSeed", "SetMasterSeed")
hook("/Script/PenDriverPro.DrivingGameInstance:RollMasterSeed", "RollMasterSeed")
hook("/Script/PenDriverPro.RandomState:SetSeed", "RandomState.SetSeed")
hook("/Script/PenDriverPro.BlueNoiseUtils:Reset", "BlueNoise.Reset")
hook("/Script/Engine.KismetMathLibrary:SeedRandomStream", "SeedRandomStream")
hook("/Script/Engine.KismetMathLibrary:SetRandomStreamSeed", "SetRandomStreamSeed")
hook("/Script/Engine.KismetMathLibrary:MakeRandomStream", "MakeRandomStream")

-- Unseeded BP random nodes (global FMath::Rand) are only counted, they fire too often to log.
local unseeded = {}
for _, fn in ipairs({ "RandomInteger", "RandomIntegerInRange", "RandomFloat", "RandomFloatInRange",
                      "RandomBool", "RandomBoolWithWeight", "RandomUnitVector", "RandomPointInBoundingBox" }) do
    pcall(function()
        RegisterHook("/Script/Engine.KismetMathLibrary:" .. fn, function()
            unseeded[fn] = (unseeded[fn] or 0) + 1
        end)
    end)
end
LoopAsync(10000, function()
    local t = {}
    for k, v in pairs(unseeded) do t[#t + 1] = k .. "=" .. v end
    if #t > 0 then log("unseeded random calls so far: " .. table.concat(t, " ")) end
    return false
end)
