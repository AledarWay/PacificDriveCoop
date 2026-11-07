-- Logs the exit's calls (car manager / car / character functions around getting out) into EXIT_TRACE; EXIT_TRACE_READ
-- returns + clears it. Who: [TWIN] / [OWN] by the object's attach root. (SetDoorState is not hooked: that crashed.)
if EXIT_TRACE_READ then local s = table.concat(EXIT_TRACE or {}, "\n") EXIT_TRACE = {} return s end
EXIT_TRACE = EXIT_TRACE or {}
if EXIT_TRACE_HOOKED then return "already hooked" end
EXIT_TRACE_HOOKED = true
local T = _G.CoopPlayers.twinModule()
local t0 = os.clock()
local function log(s) EXIT_TRACE[#EXIT_TRACE + 1] = string.format("%7.3f %s", os.clock() - t0, s) end
local function who(o)
    local ok, r = pcall(function()
        local root, g = o, 0
        while g < 8 and root.GetAttachParentActor do local p = root:GetAttachParentActor() if not (p and p:IsValid()) then break end root, g = p, g + 1 end
        return T.isTwin(root) and "[TWIN]" or (root:GetClass():GetFName():ToString() == "BP_PlayerCarNew_C" and "[OWN]" or "")
    end)
    return ok and r or ""
end
local function val(x)
    local ok, v = pcall(function() return x:get() end)
    if not ok then return "?" end
    if type(v) == "userdata" and v.IsValid then
        local ok2, s = pcall(function() return v:GetFName():ToString() .. who(v) end)
        if ok2 then return s end
        local ok3, s3 = pcall(function() return v.TagName:ToString() end)
        return ok3 and s3 or "obj"
    end
    return tostring(v)
end
local n = 0
local function H(cls, fn)
    local path = cls .. ":" .. fn
    local fo = StaticFindObject(path)
    local okc, c = pcall(function() return fo:GetClass():GetFName():ToString() end)
    if not (okc and c == "Function") then log("no function " .. path) return end
    local ok = pcall(RegisterHook, path, function(self, ...)
        local a = { ... }
        pcall(function()
            local args = {}
            for i = 1, math.min(#a, 4) do args[#args + 1] = val(a[i]) end
            log(who(self:get()) .. " " .. fn .. " (" .. table.concat(args, ", ") .. ")")
        end)
    end)
    if ok then n = n + 1 end
end
local function C(name) local a = FindFirstOf(name) return a and (a:GetClass():GetFullName():gsub("^%S+%s+", "")) end
local cm, car, ch = C("BP_CarManager_C"), C("BP_PlayerCarNew_C"), C("PDP_MainCharacter_C")
-- (GetDoorState hooked: the game died at the next exit - not hooked)
for _, f in ipairs({ "AttemptOpenOrShutDoor", "OnPlayerStartExitCar_Event", "OnPlayerExitCar_Event" }) do H(cm, f) end
for _, f in ipairs({ "LocateSafeExitPoint", "ManualActivate_ExitDoor", "UpdateExitDoorHighlight", "Player Left Car" }) do H(car, f) end
for _, f in ipairs({ "GetExitPoint", "FindSafeExitPoint", "Exit Car", "CarExitAnimAttemptComplete" }) do H(ch, f) end
-- the door's exit functions (EXIT_DOORS = true)
if EXIT_DOORS then
    local dc = C("BP_CarPart_Door_Base_C")
    for _, f in ipairs({ "AttemptOpen", "AttemptDoorExit", "ExitValid", "GiveUptryingToExit", "GetFLDoorAngle", "AttemptShut" }) do H(dc, f) end
end
return "hooked " .. n
