-- Logs calls of the door / entry functions into DOOR_TRACE (global list); DOOR_TRACE_READ returns + clears it.
if DOOR_TRACE_READ then
    local s = table.concat(DOOR_TRACE or {}, "\n") DOOR_TRACE = {} return s
end
DOOR_TRACE = DOOR_TRACE or {}
if DOOR_TRACE_HOOKED then return "already hooked" end
DOOR_TRACE_HOOKED = true
local t0 = os.clock()
local function log(s) DOOR_TRACE[#DOOR_TRACE + 1] = string.format("%7.3f %s", os.clock() - t0, s) end
local d = FindFirstOf("BP_CarPart_Door_Base_C")
local dc = d:GetClass():GetFullName():gsub("^%S+%s+", "")
local ch = FindFirstOf("PDP_MainCharacter_C"):GetClass():GetFullName():gsub("^%S+%s+", "")
local cm = FindFirstOf("BP_CarManager_C"):GetClass():GetFullName():gsub("^%S+%s+", "")
local n = 0
local function who(a)
    local ok, r = pcall(function()
        local s = a[1]:get()
        local T = _G.CoopPlayers and _G.CoopPlayers.twinModule()
        local root, g = s, 0
        if not root.GetAttachParentActor then return "" end
        while g < 10 do local p = root:GetAttachParentActor() if not (p and p:IsValid()) then break end root, g = p, g + 1 end
        return (T and T.isTwin(root)) and "[TWIN] " or (root:GetClass():GetFName():ToString() == "BP_PlayerCarNew_C" and "[OWN] " or "")
    end)
    return ok and r or ""
end
local function H(path, f)
    local fo = StaticFindObject(path)
    local okc, c = pcall(function() return fo:GetClass():GetFName():ToString() end)
    if not (okc and c == "Function") then log("no function " .. path) return end
    local ok, e = pcall(RegisterHook, path, function(...) local a = { ... } pcall(function() log(who(a) .. path:match("[^:]+$") .. " " .. (f and f(a) or "")) end) end)
    if ok then n = n + 1 else log("hook failed " .. path .. ": " .. tostring(e)) end
end
local function v(x) local ok, r = pcall(function() return x:get() end) return tostring(ok and r or "?") end
for _, f in ipairs({ "StartEntry", "EnterCar", "GiveUpTryingToEnter", "AttemptOpen", "AttemptShut", "AttemptDoorExit",
    "BndEvt__Highlight_K2Node_ComponentBoundEvent_0_OnHighlightInteract__DelegateSignature",
    "BndEvt__Highlight_K2Node_ComponentBoundEvent_1_OnHighlightInteract__DelegateSignature",
    "BndEvt__Highlight_K2Node_ComponentBoundEvent_2_OnHighlightInteract__DelegateSignature" }) do
    H(dc .. ":" .. f, function(a) return a[2] and v(a[2]) or "" end)
end
H(ch .. ":CommandEnterCar", function(a) local d2 = a[3] and a[3]:get() return "tp=" .. v(a[2]) .. " door=" .. (d2 and d2:IsValid() and d2:GetFName():ToString() or "nil") end)
H(ch .. ":Exit Car")
H(ch .. ":Command Interact", function(a) return v(a[2]) end)
H(cm .. ":AttemptOpenOrShutDoor", function(a) return v(a[2]) .. " " .. v(a[3]) end)
local hmc = FindFirstOf("BP_HighlightManager_C"):GetClass():GetFullName():gsub("^%S+%s+", "")
local function cur() local h = FindFirstOf("BP_HighlightManager_C").CurrentHighlight return (h and h:IsValid()) and "hl=on" or "hl=nil" end
H(hmc .. ":HighlightPress", function(a) return v(a[2]) .. " " .. cur() end)
H(hmc .. ":SetHighlight", function(a) local x = a[2] and a[2]:get() return ((x and x:IsValid()) and "comp" or "nil") .. " " .. cur() end)
return "hooked " .. n .. "\n" .. table.concat(DOOR_TRACE, "\n")
