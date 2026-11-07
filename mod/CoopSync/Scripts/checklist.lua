-- The co-op checklist in the garage (owner, alpha 18: "a Кооператив list like the game's Список водителя", and after
-- the first look: "with its sections and check boxes, where the garage's list is"). On the HUD right after the driver's
-- checklist's place (UMG_Missions_Main.ObjectiveSetsBox, after its RecipeSizeBox - the list the status screen by the
-- map table opens), shown while a lobby exists and the player is in its garage:
--   КООПЕРАТИВ
--   ЛОББИ      [x] 2 из 2
--   ИГРОКИ     [x] PLAYER1 (Вы, Хост)   [x] PLAYER2
--   ЗАДАЧА     [ ] host "Выберите развилку" -> (its exit gate open: a junction picked) "Выезжайте в зону";
--                  guest "Ожидание хоста" -> (the host has left: its gate open) "Выезжайте в зону"
-- The look is the game's: the title font of a checklist entry (UMG_Objective_Info_C) and a task row's section header,
-- text font and check box pictures (UMG_Mission_Task_C), read from ones made only for that. Never inside the game's
-- own lists: task widgets without a mission there crashed the game when it rebuilt the list (probe).
local M = {}
local L = (CoopSyncLoc or dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "loc.lua")).L
local DEMO = os.getenv("COOPSYNC_CHECKLIST_DEMO") == "1"

local Session, Menu
local boxH        -- our VerticalBox (weak handle, see menu.lua hold)
local boxOf       -- the HUD widget it was added to (address)
local lastSig = ""
local seq = 0
M.stats = { built = 0, shown = 0, errors = 0, last = "-" }
M.rows = 0 -- (the lines it shows: status.txt chk=, for the tests)

local function hold(o)
    if not o then return nil end
    if CoopNative_RefPath then return CoopNative_RefPath((o:GetFullName():gsub("^%S+ ", ""))) end
    return o
end
local function held(h)
    if type(h) == "number" then return CoopNative_Get(h) end
    if h and h:IsValid() then return h end
    return nil
end

-- the HUD's missions widget, kept as a weak handle (FindAllOf walks every object: ~3.5 ms - not every tick)
local mainH, mainAt = nil, -1e9
local function missionsMain()
    local m = held(mainH)
    if m then return m end
    if os.clock() - mainAt < 2 then return nil end
    mainAt = os.clock()
    for _, w in ipairs(FindAllOf("UMG_Missions_Main_C") or {}) do
        if w:IsValid() and w:GetFullName():find("/Engine/Transient", 1, true) then mainH = hold(w) return w end
    end
    return nil
end

-- a widget class by its name (FindFirstOf of a widget class can give a dead template - GetClass on it crashed UE4SS)
local function widgetClass(name, path)
    local cls
    pcall(function() cls = FindObject("WidgetBlueprintGeneratedClass", name, 0, 0) end)
    if not (cls and cls:IsValid()) then pcall(function() cls = LoadAsset(path) end) end
    return cls and cls:IsValid() and cls or nil
end
-- the game's checklist look, from an entry and a task row made only to read it (never added anywhere). Read again
-- for every build and used at once: the structs read are the widgets' own memory, and those widgets go with the GC -
-- a cached font set later crashed the guest in SetFont (FProperty::CopyCompleteValue, startflow / mapsync)
local function readStyle(owner)
    local WBL = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local pc = FindFirstOf("PlayerController")
    local s = {}
    local info = widgetClass("UMG_Objective_Info_C", "/Game/UI/Missions/UMG_Objective_Info.UMG_Objective_Info_C")
    if info then
        local w = WBL:Create(owner, info, pc)
        s.keep1 = w
        pcall(function() s.title, s.titleColor = w.ObjectiveTitleText.Font, w.ObjectiveTitleText.ColorAndOpacity end)
    end
    local task = widgetClass("UMG_Mission_Task_C", "/Game/UI/Missions/UMG_Mission_Task.UMG_Mission_Task_C")
    if task then
        local t = WBL:Create(owner, task, pc)
        pcall(function() s.header, s.headerColor = t.SubHeaderText.Font, t.SubHeaderText.ColorAndOpacity end)
        pcall(function() s.text, s.textColor = t.TaskDescriptionText.Font, t.TaskDescriptionText.ColorAndOpacity end)
        pcall(function() s.checked, s.unchecked = t.Checkbox_Checked, t.Checkbox_Unchecked end)
        s.keep2 = t
    end
    return s
end

-- capitals with the Cyrillic letters too (string.upper knows ASCII only: "Кооператив" stayed as it was)
local function upper(s)
    local out = {}
    for _, c in utf8.codes(s) do
        if c >= 0x430 and c <= 0x44F then c = c - 0x20 elseif c == 0x451 then c = 0x401 elseif c >= 0x61 and c <= 0x7A then c = c - 0x20 end
        out[#out + 1] = utf8.char(c)
    end
    return table.concat(out)
end
M.upper = upper

local function new(cls, tree)
    seq = seq + 1
    return StaticConstructObject(StaticFindObject("/Script/UMG." .. cls), tree, FName("CoopSyncChecklist" .. cls .. "_" .. seq))
end
local function text(tree, s, font, color)
    local t = new("TextBlock", tree)
    t:SetText(FText(s))
    if font then pcall(function() t:SetFont(font) end) end
    if color then pcall(function() t:SetColorAndOpacity(color) end) end
    return t
end

-- The driver's checklist's column: the game's RecipeSizeBox holds its ShoppingListWidgetSwitcher (the checklist / a
-- pinned recipe, at the HUD's left under the health bars). Our list goes under it: the size box's content is put into
-- a VerticalBox of ours (the switcher first, our list after it) and back as it was when ours goes.
local wrapH, wrapOf
local function unwrap()
    local wrap = held(wrapH)
    if wrap then
        pcall(function()
            local main = missionsMain()
            local sw = main and main.ShoppingListWidgetSwitcher
            local sb = main and main.RecipeSizeBox
            if sw and sb and sw:GetParent() and sw:GetParent():GetAddress() == wrap:GetAddress() then
                wrap:RemoveChild(sw)
                sb:RemoveChild(wrap)
                sb:AddChild(sw)
            end
        end)
    end
    wrapH, wrapOf = nil, nil
end
local function removeBox()
    local b = held(boxH)
    if b then pcall(function() b:RemoveFromParent() end) end
    boxH, boxOf, lastSig = nil, nil, ""
end
local function remove()
    removeBox()
    unwrap()
end

-- the rows to show: { { header = "ЛОББИ" | nil, text, done }, ... }, or nil (no lobby / not in the garage)
function M.lines()
    if not (Session and Menu) then return nil end
    local S = Session.state()
    local n = Menu.net()
    -- ($COOPSYNC_CHECKLIST_DEMO=1: a made-up lobby, for a look at it without a second game - graphics checks)
    if DEMO then
        n = { inLobby = true, owner = true, head = { ping = "10" }, members = { { name = "Player1", me = true, owner = true }, { name = "Player2" } } }
    end
    if not n.inLobby then return nil end
    local gi = FindFirstOf("DrivingGameInstance")
    local okG, gs = pcall(function() return gi.CurrentGameplayState end)
    if not (okG and tonumber(gs) == 4) then return nil end
    local out = {}
    -- (no ping: each change rebuilt the list, and the driver's checklist above it folded and unfolded - owner, alpha 19)
    out[#out + 1] = { header = upper(L("Лобби")), text = string.format(L("%d из 2"), #n.members), done = #n.members >= 2 }
    for i, m in ipairs(n.members) do
        local tag = m.me and m.owner and L(" (Вы, Хост)") or m.me and L(" (Вы)") or m.owner and L(" (Хост)") or ""
        out[#out + 1] = { header = i == 1 and upper(L("Игроки")) or nil, text = upper(m.name or "?") .. tag, done = true }
    end
    local gateOpen = false
    pcall(function() local ex = Session.garageExit and Session.garageExit() gateOpen = ex ~= nil and ex.ExitActive == true end)
    local action
    if n.owner then action = gateOpen and L("Выезжайте в зону") or L("Выберите развилку")
    else action = (S.go or S.joinPending or gateOpen) and L("Выезжайте в зону") or L("Ожидание хоста") end
    out[#out + 1] = { header = upper(L("Задача")), text = action, done = false }
    return out
end

local function build(main, rows)
    local s = readStyle(main) or {}
    local tree = main.WidgetTree
    local box = new("VerticalBox", tree)
    local wrap = held(wrapH)
    if not (wrap and wrapOf == main:GetAddress()) then
        local sw, sb = main.ShoppingListWidgetSwitcher, main.RecipeSizeBox
        wrap = new("VerticalBox", tree)
        sb:RemoveChild(sw)
        wrap:AddChildToVerticalBox(sw)
        sb:AddChild(wrap)
        wrapH, wrapOf = hold(wrap), main:GetAddress()
    end
    local slot = wrap:AddChildToVerticalBox(box)
    pcall(function() slot:SetPadding({ Left = 0, Top = 36, Right = 0, Bottom = 0 }) end) -- (owner, alpha 19: 12 sat too close)
    -- the title as the game's: its font, a line under it
    box:AddChildToVerticalBox(text(tree, upper(L("Кооператив")), s.title or s.header, s.titleColor))
    pcall(function()
        local line = new("Image", tree)
        line:SetBrushSize({ X = 140, Y = 1 })
        if s.titleColor then line:SetColorAndOpacity(s.titleColor.SpecifiedColor) end
        local ls = box:AddChildToVerticalBox(line)
        ls:SetHorizontalAlignment(1) -- left
        ls:SetPadding({ Left = 0, Top = 2, Right = 0, Bottom = 4 })
    end)
    for _, r in ipairs(rows) do
        if r.header then
            local h = text(tree, r.header, s.text, s.textColor)
            local hs = box:AddChildToVerticalBox(h)
            pcall(function() hs:SetPadding({ Left = 0, Top = 6, Right = 0, Bottom = 2 }) end)
        end
        local line = new("HorizontalBox", tree)
        local img = new("Image", tree)
        local brush = r.done and s.checked or s.unchecked
        if brush then pcall(function() img:SetBrush(brush) end) end
        pcall(function() img:SetBrushSize({ X = 16, Y = 16 }) end)
        local is = line:AddChildToHorizontalBox(img)
        pcall(function() is:SetVerticalAlignment(2) is:SetPadding({ Left = 0, Top = 0, Right = 8, Bottom = 0 }) end)
        local ts = line:AddChildToHorizontalBox(text(tree, upper(r.text), s.text, s.textColor))
        pcall(function() ts:SetVerticalAlignment(2) end)
        local rs = box:AddChildToVerticalBox(line)
        pcall(function() rs:SetPadding({ Left = 14, Top = 1, Right = 0, Bottom = 1 }) end) -- (under its header, as the game's sub-items)
    end
    pcall(function() box:SetVisibility(4) end) -- SelfHitTestInvisible
    return box
end

function M.tick()
    local rows = M.lines()
    M.rows = rows and #rows or 0
    if not rows then if boxH then remove() end return end
    local main = missionsMain()
    if not main then return end
    local parts = {}
    for _, r in ipairs(rows) do parts[#parts + 1] = (r.header or "") .. "|" .. r.text .. "|" .. tostring(r.done) end
    local sig = table.concat(parts, "\n")
    if sig == lastSig and boxOf == main:GetAddress() and held(boxH) then return end
    -- (rebuilt whenever a line changes: a handful of widgets, a few times per lobby; only our box - the driver's
    -- checklist stays in the wrap, taking it out and back made it fold and unfold)
    if wrapOf == main:GetAddress() and held(wrapH) then removeBox() else remove() end
    local ok, box = pcall(build, main, rows)
    if not ok then M.stats.errors = M.stats.errors + 1 M.stats.last = "error: " .. tostring(box) return end
    boxH, boxOf, lastSig = hold(box), main:GetAddress(), sig
    M.stats.built = M.stats.built + 1
    M.stats.last = (sig:gsub("\n", " / "))
end

function M.info()
    local b = held(boxH)
    local vis = false
    pcall(function() vis = b ~= nil and b:IsVisible() end)
    return string.format("checklist=%s visible=%s built=%d errors=%d | %s", tostring(b ~= nil), tostring(vis), M.stats.built, M.stats.errors, M.stats.last)
end

function M.start(sessionModule, menuModule)
    Session, Menu = sessionModule, menuModule
    return "checklist"
end
M.remove = remove

return M
