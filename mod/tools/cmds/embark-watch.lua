-- Garage departure watch: hooks on the embark / gate / travel functions log into EmbarkLog (read it back with
-- "return table.concat(EmbarkLog, ' | ')"), plus the current door / exit / progression state.
EmbarkLog = rawget(_G, "EmbarkLog") or {}
local function log(s) EmbarkLog[#EmbarkLog + 1] = string.format("%.1f %s", os.clock(), s) end
local function state()
    local door, exit, pm = FindFirstOf("BP_GarageDoor_C"), nil, FindFirstOf("BP_ProgressionManager_C")
    for _, e in ipairs(FindAllOf("BP_LevelTransition_EnterExit_C") or {}) do if e:IsValid() and e.IsGarageExit then exit = e end end
    local r = {}
    pcall(function()
        for _, d in ipairs(FindAllOf("BP_GarageDoor_C") or {}) do
            r[#r + 1] = string.format("door %s open=%s canEmbark=%s try=%s pos=%.2f", d:GetFName():ToString(), tostring(d.IsOpen), tostring(d["Can Embark"]), tostring(d.TryOpening), d.CurrentDoorPosition)
        end
    end)
    pcall(function() r[#r + 1] = string.format("exit canEmbark=%s exitActive=%s entranceActive=%s", tostring(exit["Can Embark"]), tostring(exit.ExitActive), tostring(exit.EntranceActive)) end)
    pcall(function() r[#r + 1] = string.format("pm left=%s restrictions=%s", tostring(pm.HasLeftGarage), tostring(pm.StartRunRestrictionsActive)) end)
    return table.concat(r, "; ")
end
EmbarkState = state
if not rawget(_G, "EmbarkHooked") then
    EmbarkHooked = true
    local P = "/Game/Systems/Managers/BP_ProgressionManager.BP_ProgressionManager_C:"
    local X = "/Game/Gameplay/LevelTransition/BP_LevelTransition_EnterExit.BP_LevelTransition_EnterExit_C:"
    local D = "/Game/Gameplay/CarGarage/BP_GarageDoor.BP_GarageDoor_C:"
    local hooks = {
        { P .. "OnEmbarkStateChange", function(_, can) log("OnEmbarkStateChange " .. tostring(can:get())) end },
        { P .. "CheckEmbarkConditions", function() log("CheckEmbarkConditions") end },
        { P .. "OnCarExitShed_Successful__DelegateSignature", function() log("ExitShed ok") end },
        { "/Script/PenDriverPro.BaseRouteState:TravelTo", function(_, dest) local ok, n = pcall(function() return dest:get():GetFName():ToString() end) log("TravelTo " .. tostring(ok and n)) end },
        { "/Script/PenDriverPro.BaseRouteState:NotifyPlayerMapSelection", function() log("NotifyPlayerMapSelection") end },
        { P .. "Open Map UI", function() log("Open Map UI") end },
    }
    for _, h in ipairs(hooks) do
        local ok, e = pcall(RegisterHook, h[1], h[2])
        log((ok and "hooked " or "hook failed ") .. h[1]:match("[^:]+$") .. (ok and "" or (" " .. tostring(e))))
    end
    -- the exit's and the door's own functions (class paths found at run time)
    for _, cls in ipairs({ "BP_LevelTransition_EnterExit_C", "BP_GarageDoor_C" }) do
        local o = FindFirstOf(cls)
        if o then
            local cp = o:GetClass():GetFullName():gsub("^%S+ ", "")
            for _, fn in ipairs({ "DoLevelTransition", "CarEnteredExitVol_Event", "CloseGate", "OpenDoor", "CloseDoor", "FrontDoorExpeditionCheck", "ExitGateGSS", "Garage Gate State Changed", "DoorStateRequested" }) do
                if pcall(RegisterHook, cp .. ":" .. fn, function() log(cls .. ":" .. fn) end) then log("hooked " .. fn) end
            end
        end
    end
end
log("state: " .. state())
return table.concat(EmbarkLog, " | ")
