-- The game's own save of a zone (owner, 2026-10-29: "how does the game keep a zone when you pause mid-run and quit?").
--   SP_OP = 'hook'  : log the save manager's save / load / checkpoint / bookmark calls and the pause menu's quit
--                     handlers into SP_LOG (SP_OP = 'log' returns + clears it)
--   SP_OP = 'info'  : the save manager's state here (slot, checkpoints, can save, the quit-mid-run setting)
--   SP_OP = 'save'  : SaveGame(SP_SLOT or the current slot, "", SP_TYPE or 1 MANUAL) right here
--   SP_OP = 'chkp'  : SaveCheckpoint()          SP_OP = 'mark': MakeBookmark(SP_NAME or "coop", true, false)
local op, slotArg, typeArg, nameArg = SP_OP or "info", SP_SLOT, SP_TYPE, SP_NAME
SP_OP, SP_SLOT, SP_TYPE, SP_NAME = nil, nil, nil, nil
local sm = FindFirstOf("BP_SaveGameManager_C")
if not (sm and sm:IsValid()) then return "no save manager" end
local function try(f) local ok, v = pcall(f) return ok and tostring(v) or ("ERR " .. tostring(v)) end

if op == "log" then local s = table.concat(SP_LOG or {}, "\n") SP_LOG = {} return s end
if op == "hook" then
    SP_LOG = SP_LOG or {}
    if SP_HOOKED then return "already hooked" end
    SP_HOOKED = true
    local t0 = os.clock()
    local n = 0
    local function H(path)
        local fo = StaticFindObject(path)
        local okc, c = pcall(function() return fo:GetClass():GetFName():ToString() end)
        if not (okc and c == "Function") then SP_LOG[#SP_LOG + 1] = "no function " .. path return end
        local name = path:match("[^:]+$")
        if pcall(RegisterHook, path, function(self, ...)
            local a = { ... }
            local args = {}
            for i = 1, math.min(#a, 4) do args[#args + 1] = try(function() return a[i]:get() end) end
            SP_LOG[#SP_LOG + 1] = string.format("%7.2f %s(%s)", os.clock() - t0, name, table.concat(args, ", "))
        end) then n = n + 1 end
    end
    local base = "/Script/PenDriverPro.BaseSaveGameManager:"
    for _, f in ipairs({ "SaveGame", "SaveCheckpoint", "Rinse", "QuitToMenu", "MakeBookmark", "LoadGame", "LoadFromCheckpoint",
        "LoadBookmarkCmd", "ShouldUseCheckpoints", "ShouldLoadTransforms" }) do H(base .. f) end
    local bp = "/Game/Systems/Managers/BP_SaveGameManager.BP_SaveGameManager_C:"
    for _, f in ipairs({ "UserLoadGame", "LoadOrCreateGame", "CanUserSaveGame" }) do H(bp .. f) end
    local pm = "/Game/UI/PauseMenu/PDP_PauseMenu.PDP_PauseMenu_C:"
    for _, f in ipairs({ "SaveQuitClicked", "RunQuitResponse", "OnReturnGarageSelected",
        "BndEvt__PDP_PauseMenu_PDP_MenuItem_SuspendAndQuit_K2Node_ComponentBoundEvent_10_Pressed__DelegateSignature" }) do H(pm .. f) end
    return "hooked " .. n .. "\n" .. table.concat(SP_LOG, "\n")
end
if op == "info" then
    local out = {}
    out[#out + 1] = "slot=" .. try(function() return sm.CurrentSaveSlot end)
    out[#out + 1] = "using_checkpoints=" .. try(function() return sm:IsUsingCheckpoints() end)
    out[#out + 1] = "levels_with_checkpoints=" .. try(function()
        local t = {}
        local arr = sm["Levels With Checkpoints"]
        for i = 1, arr:GetArrayNum() do t[#t + 1] = arr[i]:ToString() end
        return table.concat(t, ",")
    end)
    out[#out + 1] = "can_save=" .. try(function() local r = {} sm["CanUserSaveGame"](sm, r) return r["Can Save"] end)
    out[#out + 1] = "loaded_from_rinse=" .. try(function() return sm.bLoadedFromRinse end)
    out[#out + 1] = "loaded_scene=" .. try(function() local s = sm.LoadedScene return s and s:IsValid() and s:GetFullName() or "none" end)
    out[#out + 1] = "save_quit_consequences=" .. try(function()
        for _, o in ipairs(FindAllOf("DrivingGameUserSettings") or {}) do
            if o:IsValid() and not o:GetFullName():find("Default__", 1, true) then return o.AbandonSaveQuitConsequences .. " (abandon run " .. o.AbandonRunConsequences .. ")" end
        end
        return "no settings object"
    end)
    return table.concat(out, "\n")
end
if op == "save" then
    local slot = slotArg or sm.CurrentSaveSlot
    return "SaveGame(" .. tostring(slot) .. "): " .. try(function() sm:SaveGame(slot, "", typeArg or 1) return "called" end)
end
if op == "chkp" then return "SaveCheckpoint: " .. try(function() sm:SaveCheckpoint() return "called" end) end
if op == "mark" then return "MakeBookmark: " .. try(function() sm:MakeBookmark(FName(nameArg or "coop"), true, false) return "called" end) end
return "unknown op " .. op
