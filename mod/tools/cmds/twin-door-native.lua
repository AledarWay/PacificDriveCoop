-- The game's own E at the twin's door (aim first with twin-parts-look LOOK_SLOT = 'DoorsFL'):
--   DOOR_MODE = 'giveup'   E pressed, GiveUpTryingToEnter on the twin's door DOOR_GIVEUP_MS later (the game's entry
--                          started by the press is called off: does the player stay outside?)
--   DOOR_MODE = 'manager'  the car manager pointed at the twin before E (does the game itself get in the twin?)
--   DOOR_MODE = 'plain'    just E
-- DOOR_N: the twin's door (1 FL .. 5 trunk) for 'giveup'
local T = _G.CoopPlayers.twinModule()
local twin
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then twin = c end end
if not twin then return "no twin" end
local mode, n = DOOR_MODE or "plain", DOOR_N or 1
local door = T.door(twin, n)
local s = "mode=" .. mode .. " door=" .. tostring(door and door:IsValid() and door:GetClass():GetFName():ToString())
if mode == "manager" then FindFirstOf("BP_CarManager_C").NewCarActor = twin end
local p = FindFirstOf("PlayerController").Pawn
p["Command Interact"](p, true)
Dev.after(120, function() local q = FindFirstOf("PlayerController").Pawn q["Command Interact"](q, false) end)
if mode == "giveup" then
    Dev.after(DOOR_GIVEUP_MS or 30, function()
        local ok, e = pcall(function() T.door(twin, n):GiveUpTryingToEnter() end)
        print("[twin-door-native] giveup " .. tostring(ok) .. " " .. tostring(e))
    end)
end
DOOR_MODE, DOOR_N, DOOR_GIVEUP_MS = nil, nil, nil
return s .. " E pressed"
