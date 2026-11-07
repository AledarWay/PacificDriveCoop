-- F7: the co-op debug panel (owner, 2026-10-24: a fallback for when the pause-menu UI breaks; imgui needs a C++ mod,
-- declined). A UserWidget built from Lua (StaticConstructObject: UserWidget + WidgetTree + CanvasPanel + Border +
-- VerticalBox + UButton / TextBlock), not the game's menu buttons: those take their clicks from the pause menu that
-- holds them. Probed (graphics):
--   * the game's mouse / UI input only works while its pause menu is open; an own SetInputMode / cursor is overridden
--     -> F7 opens the pause menu, makes it transparent and hit-test invisible (SetRenderOpacity 0, visibility 3 -
--     Hidden stopped the UI input too) and shows the panel over it; closing restores and closes the pause menu;
--   * UButton clicks cannot be bound from Lua: the buttons are polled (IsPressed: pressed -> released = a click);
--   * the panel is never removed from the viewport, only collapsed: a removed one is garbage collected and touching
--     it crashed the game.
-- Not in the main menu (owner, alpha 16: no lobby can be made or joined there).
local M = {}
-- the texts in the game's language (loc.lua)
local L = (CoopSyncLoc or dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "loc.lua")).L
local After = CoopSyncAfter or dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "hooks.lua").after -- (never ExecuteWithDelay: hooks.lua)
-- path lookups: the native one answers a miss at once (UE4SS walks every object then: ~50 ms)
local SFO = StaticFindObject
if CoopNative_HasPath then SFO = function(p) if CoopNative_HasPath(p) then return StaticFindObject(p) end return nil end end

local Session, Menu
local panel          -- path of the panel UserWidget
local list           -- path of its VerticalBox
local buttons = {}   -- { path = button path, act = fn, was = bool }
local shown = false
local armed = false -- the pause menu under the panel is up (before that, its being closed means nothing)
local page = "main"
local lastMsg = ""
local sig = ""

local function C(p) return SFO(p) end
local function deref(p)
    if not p then return nil end
    local o = SFO(p)
    if o and o:IsValid() then return o end
end
local function ref(o) return (o:GetFullName():gsub("^%S+ ", "")) end

-- the pause menu closed the game's own way: the UI manager's "Set Pause Menu Opened"(false) unpauses and gives the
-- input back. (Hiding the HUD's pause widget left the game paused with a cursor - owner, alpha 9, after F7.)
local function closePause()
    pcall(function() FindFirstOf("PDP_Game_Hud_C"):SetPauseMenuWidgetVisible(false) end)
    -- In the co-op pause the world runs anyway: the widget hidden is all (the UI manager's call goes through PauseGame,
    -- which session.lua hooks - that nested call crashed the game in esc-test, ltable.c getgeneric)
    if CoopSyncSession and CoopSyncSession.coopActive and CoopSyncSession.coopActive() then return end
    local ui = FindFirstOf("BP_UIManager_C")
    if ui then pcall(function() ui["Set Pause Menu Opened"](ui, false) end) end
    -- and when the game still stands paused with no pause menu to show (opened by Esc, then F7: the call above did
    -- not unpause there), the world and the input go back to the game
    After(300, function()
        pcall(function()
            local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            local pc = FindFirstOf("PlayerController")
            local vis = false
            for _, m in ipairs(FindAllOf("PDP_PauseMenu_C") or {}) do
                if type(m) == "userdata" and m:IsValid() and m:GetFullName():find("/Engine/Transient", 1, true) then vis = vis or m:IsVisible() end
            end
            if vis or not GS:IsGamePaused(pc) then return end
            pcall(function() FindFirstOf("PDP_Game_Hud_C"):SetPauseMenuWidgetVisible(false) end)
            GS:SetGamePaused(pc, false)
            StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_GameOnly(pc, false)
            pc.bShowMouseCursor = false
        end)
    end)
end
-- (menu.lua's: a weak handle, searched again every 2 s)
local function pauseMenu()
    if Menu and Menu.pauseMenu then return Menu.pauseMenu() end
    for _, m in ipairs(FindAllOf("PDP_PauseMenu_C") or {}) do
        if type(m) == "userdata" and m:IsValid() and m:GetFullName():find("/Engine/Transient", 1, true) then return m end
    end
end
local function gameState()
    local ok, s = pcall(function() return FindFirstOf("DrivingGameInstance").CurrentGameplayState end)
    return ok and tonumber(s) or -1
end

local seq = 0
local function new(cls, outer, name)
    seq = seq + 1
    return StaticConstructObject(C(cls), outer, FName(name .. "_" .. seq))
end

local function build()
    local gi = FindFirstOf("DrivingGameInstance")
    local w = new("/Script/UMG.UserWidget", gi, "CoopSyncPanel")
    local tree = new("/Script/UMG.WidgetTree", w, "Tree")
    w.WidgetTree = tree
    local canvas = new("/Script/UMG.CanvasPanel", tree, "Canvas")
    tree.RootWidget = canvas
    local border = new("/Script/UMG.Border", tree, "Bg")
    border:SetBrushColor({ R = 0.015, G = 0.015, B = 0.02, A = 0.92 })
    border:SetPadding({ Left = 24, Top = 18, Right = 24, Bottom = 18 })
    local slot = canvas:AddChildToCanvas(border)
    pcall(function() slot:SetPosition({ X = 40, Y = 40 }) slot:SetAutoSize(true) end)
    local vb = new("/Script/UMG.VerticalBox", tree, "List")
    border:SetContent(vb)
    w:AddToViewport(900)
    w:SetVisibility(1) -- collapsed until F7
    panel, list = ref(w), ref(vb)
end

local function text(vb, tree, s, size)
    local tb = new("/Script/UMG.TextBlock", tree, "T")
    tb:SetText(FText(s))
    pcall(function() local f = tb.Font f.Size = size or 18 tb:SetFont(f) end)
    pcall(function() tb:SetColorAndOpacity({ SpecifiedColor = { R = 0.92, G = 0.88, B = 0.72, A = 1 }, ColorUseRule = 0 }) end)
    local s2 = vb:AddChildToVerticalBox(tb)
    pcall(function() s2:SetPadding({ Left = 0, Top = 2, Right = 0, Bottom = 2 }) end)
end
local function button(vb, tree, label, act)
    local b = new("/Script/UMG.Button", tree, "B")
    b:SetBackgroundColor({ R = 0.12, G = 0.12, B = 0.12, A = 1 })
    local tb = new("/Script/UMG.TextBlock", tree, "BT")
    tb:SetText(FText(label))
    pcall(function() local f = tb.Font f.Size = 18 tb:SetFont(f) end)
    pcall(function() tb:SetColorAndOpacity({ SpecifiedColor = { R = 0.95, G = 0.92, B = 0.8, A = 1 }, ColorUseRule = 0 }) end)
    b:SetContent(tb)
    local s = vb:AddChildToVerticalBox(b)
    pcall(function() s:SetPadding({ Left = 0, Top = 3, Right = 0, Bottom = 3 }) end)
    buttons[#buttons + 1] = { path = ref(b), act = act, was = false }
end

-- the rows: Menu.rows(page) gives { label, act or nil } (the same actions as the pause menu, plus the debug ones)
local function render(force)
    local w, vb = deref(panel), deref(list)
    if not (w and vb) then return end
    local rows = Menu.panelRows(page, function(p) page = p end)
    local labels = { lastMsg }
    for _, r in ipairs(rows) do labels[#labels + 1] = r.label end
    local s = table.concat(labels, "\n")
    if s == sig and not force then
        local i = 0
        for _, r in ipairs(rows) do if r.act then i = i + 1 if buttons[i] then buttons[i].act = r.act end end end
        return
    end
    sig = s
    vb:ClearChildren()
    buttons = {}
    local tree = w.WidgetTree
    text(vb, tree, L("panel.title"), 24)
    if lastMsg ~= "" then text(vb, tree, "» " .. lastMsg, 18) end
    for _, r in ipairs(rows) do
        if r.act then button(vb, tree, r.label, r.act) else text(vb, tree, r.label, 16) end
    end
    button(vb, tree, L("panel.close"), function() M.close() return "" end)
end

local savedPause -- { opacity, visibility } of the game's pause menu while the panel shows over it
function M.open()
    -- not in the main menu (owner, alpha 16): no lobby can be made or joined there
    if gameState() == 1 then return "main menu" end
    if not deref(panel) then build() end
    local gs = gameState()
    if gs ~= 1 then
        -- the game's UI input comes with its pause menu: open it, keep it but make it invisible to eye and mouse
        local ui, menu = FindFirstOf("BP_UIManager_C"), pauseMenu()
        local vis = false
        if menu then pcall(function() vis = menu:IsVisible() end) end
        if ui and not vis then pcall(function() ui["Set Pause Menu Opened"](ui, true) end) end
    end
    shown, armed, page, lastMsg, sig = true, false, "main", "", ""
    After(250, function()
        if not shown then return end -- closed again meanwhile
        local menu = pauseMenu()
        if menu and gameState() ~= 1 then
            pcall(function()
                if not savedPause then savedPause = { menu:GetRenderOpacity(), menu:GetVisibility() } end
                menu:SetRenderOpacity(0) menu:SetVisibility(3) -- HitTestInvisible
            end)
        end
        local w = deref(panel)
        if w then w:SetVisibility(0) end
        render(true)
        armed = true
    end)
end

function M.close()
    shown, armed = false, false
    local w = deref(panel)
    if w then pcall(function() w:SetVisibility(1) end) end
    local menu = pauseMenu()
    if menu and savedPause then
        pcall(function() menu:SetRenderOpacity(savedPause[1]) menu:SetVisibility(savedPause[2]) end)
        -- and close it (the player came for the panel, not the pause menu)
        closePause()
    end
    savedPause = nil
end

function M.toggle() if shown then M.close() else M.open() end end
function M.isShown() return shown end

-- polled: clicks (pressed -> released), the pause menu closed under us (Esc), the rows refreshed
local function tick()
    if not (shown and armed) then return end
    if gameState() == 1 then M.close() return end -- (left for the main menu with the panel open)
    do
        local menu = pauseMenu()
        local vis = false
        if menu then pcall(function() vis = menu:IsVisible() end) end
        if not vis then
            -- Esc closed the pause menu: the panel goes too (its opacity back for the next pause)
            if menu and savedPause then pcall(function() menu:SetRenderOpacity(savedPause[1]) menu:SetVisibility(savedPause[2]) end) end
            savedPause = nil
            M.close()
            return
        end
    end
    for _, b in ipairs(buttons) do
        local o = deref(b.path)
        if o then
            local p = o:IsPressed()
            if b.was and not p and b.act then
                local ok, msg = pcall(b.act)
                lastMsg = ok and tostring(msg or "") or L("common.error", tostring(msg))
                sig = ""
                b.was = false
                After(50, function() pcall(render, true) end)
                return
            end
            b.was = p
        end
    end
end

local function loop(ms, fn)
    local h
    h = LoopInGameThreadWithDelay(ms, function()
        -- (an error escaping here made UE4SS drop the loop for good: the co-op menu item never came back, alpha 9)
        local t0 = os.clock()
        local ok, r = pcall(fn)
        if CoopSyncHitch then CoopSyncHitch.spent(os.clock() - t0, "panel") end
        if not ok then
            if CoopSyncHitch then CoopSyncHitch.note("loop error: " .. tostring(r):sub(1, 200)) end
            return
        end
        if r == true and h then CancelDelayedAction(h) end
    end)
    return h
end

function M.info()
    local w = deref(panel)
    local vis = -1
    if w then pcall(function() vis = w:GetVisibility() end) end
    return string.format("shown=%s vis=%d page=%s buttons=%d msg=%s | %s", tostring(shown), vis, page, #buttons, lastMsg, (sig:gsub("\n", " / ")))
end
-- for the tests: press a button by the start of its label
function M.press(prefix)
    local w = deref(panel)
    if not w then return "no panel" end
    for _, b in ipairs(buttons) do
        local o = deref(b.path)
        local label = o and o:GetContent():GetText():ToString() or ""
        if label:sub(1, #prefix) == prefix and b.act then
            local ok, msg = pcall(b.act)
            lastMsg = ok and tostring(msg or "") or L("common.error", tostring(msg))
            sig = ""
            render(true)
            return lastMsg
        end
    end
    return "no button " .. prefix
end

function M.start(sessionModule, menuModule)
    Session, Menu = sessionModule, menuModule
    -- (polled on the game thread: RegisterKeyBind's callback ran on another thread, hooks.lua onKey)
    local OnKey = CoopSyncOnKey or dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "hooks.lua").onKey
    OnKey(0x76, M.toggle) -- F7
    local n = 0
    loop(33, function()
        local ok, e = pcall(tick)
        if not ok then lastMsg = "panel: " .. tostring(e) end
        n = n + 1
        if shown and n % 30 == 0 then pcall(render) end -- the status rows change (once a second)
    end)
    return "panel: F7"
end

return M
