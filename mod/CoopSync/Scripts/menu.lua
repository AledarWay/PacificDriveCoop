-- The in-game co-op menu: a "Кооператив" item in the game's own pause menu. Its pages reuse the pause menu's list
-- (MenuItemBox) and buttons (UMG_PauseMenuButton_C, styled like the game's own: font and slot copied from them), so
-- it looks and navigates like the game's menu; the game's items are collapsed while a co-op page shows and come back
-- on "Назад" or when the pause menu closes. The debug actions live on the F7 panel (panel.lua), which shows the same
-- lobby rows too (a fallback when this UI breaks).
-- Data: the network's status (link.lua: lobby, friends, invites), <chan>/inbox/host-session.txt (where the host
-- is) and the session (session.lua); commands: the network (link.lua) and session.debug.
local M = {}
-- the game's functions hooked only once they exist (hooks.lua)
local Hook = CoopSyncHook or dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "hooks.lua").hook
local After = CoopSyncAfter or dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "hooks.lua").after -- (never ExecuteWithDelay: hooks.lua)
-- path lookups: the native one answers a miss at once (UE4SS walks every object then: ~50 ms)
local SFO = StaticFindObject
if CoopNative_HasPath then SFO = function(p) if CoopNative_HasPath(p) then return StaticFindObject(p) end return nil end end
-- one instance per Lua state (tests dofile the modules from another mod: require would not find it)
local Link = CoopSyncLink or dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "link.lua")
-- the texts in the game's language (loc.lua)
local Loc = CoopSyncLoc or dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "loc.lua")
local L = Loc.L

local BTN_CLASS = "/Game/UI/UMG_PauseMenuButton.UMG_PauseMenuButton_C"
local PRESSED_FN = "/Game/UI/PDP_MenuButtonBase.PDP_MenuButtonBase_C:K2_OnPressed"
local REFRESH_MS = 100
local FRIENDS_PER_PAGE = 7

local Session, chan
local menuItemH         -- our "Кооператив" button in the pause menu (a weak handle, see hold)
local menuItemOwner     -- address of the pause menu it was added to
local page              -- nil = the game's pause menu, else "coop" | "friends"
local friendsPage = 1
local rows = {}         -- our buttons on the current page: { w = widget, label = text, act = fn }
local hidden = {}       -- the game's items we collapsed: { w, vis }
local lastMsg = ""      -- result of the last action, shown on top of the page
local sig = ""          -- the labels of the current page (rebuilt only when they change)

local function log(s) print("[CoopSync menu] " .. tostring(s) .. "\n") end

local function readLines(p)
    local f = io.open(p, "rb")
    if not f then return {} end
    local t = {}
    for l in f:lines() do t[#t + 1] = l end
    f:close()
    return t
end
local function appendLine(p, s)
    local f = io.open(p, "ab")
    if not f then return end
    f:write(s .. "\n") f:close()
end
local function kv(line)
    local t = {}
    for k, v in (line or ""):gmatch("(%w+)=(%S*)") do t[k] = v end
    return t
end
local function tabs(line)
    local t = {}
    for x in (line .. "\t"):gmatch("([^\t]*)\t") do t[#t + 1] = x end
    return t
end

-- the network's view: head (kv), members, friends, invites
local function net()
    local lines = Link.status()
    local n = { head = kv(lines[1]), members = {}, friends = {}, invites = {} }
    for i = 2, #lines do
        local t = tabs(lines[i])
        if t[1] == "member" then n.members[#n.members + 1] = { id = t[2], owner = t[3] == "1", me = t[4] == "1", mode = t[5], ready = t[6] == "1", name = t[7] }
        elseif t[1] == "friend" then n.friends[#n.friends + 1] = { id = t[2], online = t[3] == "1", ingame = t[4] == "1", lobby = t[5], name = t[6] }
        elseif t[1] == "invite" then n.invites[#n.invites + 1] = { lobby = t[2], from = t[3], name = t[4] } end
    end
    n.up = n.head.state ~= nil and n.head.state ~= "offline"
    n.inLobby = n.head.state == "lobby" and n.head.lobby ~= "0"
    n.owner = n.head.owner == "1"
    return n
end
local function netCmd(s) Link.cmd(s) end
M.net, M.netCmd = net, netCmd

-- the live pause menu (FindFirstOf gives the widget blueprint's template in /Game/..., not the game's one)
local ESC_OPEN_S = 0.3
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

-- A button like the game's: the owner saw ours smaller (default font, no slot padding / fill): the font and the
-- slot (padding 0,10,0,10, fill, centred) come from one of the game's own buttons.
-- The box sized itself to the longest label of a page, so it jumped in width from page to page (owner): every
-- button of ours sits in a SizeBox of one width. As wide as the game's own items it was too narrow, long labels came
-- out tiny (owner, alpha 8): ROW_W wide, in a column of ours over the menu's content, while the game's row (its items
-- and the route panel) is collapsed (showGameItems). Among the game's items ours were mixed with items the game shows
-- again by itself, empty ("TEXT BLOCK").
local ROW_W = 1500
local sbSeq = 0
-- Widgets kept across frames as weak handles (CoopNative), not Lua objects: a Lua object of a widget the game freed
-- (it rebuilds its pause menu) crashed UE4SS when touched. (Without the native half: the Lua object, as before.)
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
local function item() return held(menuItemH) end
-- The live pause menu, kept as a weak handle and searched again every REFIND_S (a search over every object: ~3.5 ms,
-- it ran every 100 ms - 0.35 ms per frame for a menu mostly closed; F lines, 2026-10-26)
local REFIND_S, MISSING_S = 2, 0.3 -- (not found yet: looked for more often, the item shows with the menu)
local pmH, pmAt = nil, -1e9
local function pauseMenu()
    local now = os.clock()
    local m = held(pmH)
    if now - pmAt >= (m and REFIND_S or MISSING_S) then
        pmAt = now
        pmH = nil
        for _, m in ipairs(FindAllOf("PDP_PauseMenu_C") or {}) do
            if type(m) == "userdata" and m:IsValid() and m:GetFullName():find("/Engine/Transient", 1, true) then pmH = hold(m) return m end
        end
        return nil
    end
    return m
end
M.pauseMenu = pauseMenu
local ourBoxH, ourBoxOf -- our column and the pause menu it belongs to (by address)
local ourRowH -- the row holding it (a HorizontalBox over the menu's content)
local function column(menu)
    local box = ourBoxOf == menu:GetAddress() and held(ourBoxH) or nil
    if box then return box end
    sbSeq = sbSeq + 1
    local vb = StaticConstructObject(StaticFindObject("/Script/UMG.VerticalBox"), menu.WidgetTree, FName("CoopSyncColumn_" .. sbSeq))
    local content = menu.MenuItemBox:GetParent():GetParent() -- the overlay holding the game's row
    -- (in a row of ours: the page's info text goes beside the buttons, the frame widens as for the game's route panel)
    local hb = StaticConstructObject(StaticFindObject("/Script/UMG.HorizontalBox"), menu.WidgetTree, FName("CoopSyncRow_" .. sbSeq))
    hb:AddChildToHorizontalBox(vb)
    hb:SetVisibility(4)
    ourRowH = hold(hb)
    local slot = content:AddChildToOverlay(hb)
    slot:SetHorizontalAlignment(2) -- centre
    slot:SetVerticalAlignment(0)   -- top
    vb:SetVisibility(1)
    ourBoxH, ourBoxOf = hold(vb), menu:GetAddress()
    return vb
end
-- box: where the button goes (our column by default; the "Кооператив" item goes into the game's own list - in our
-- column, collapsed outside our pages, it was gone from the pause menu: owner, alpha 9)
local function newButton(menu, label, box)
    local cls = SFO(BTN_CLASS)
    local WBL = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local pc = FindFirstOf("PlayerController")
    local w = WBL:Create(menu, cls, pc)
    -- the text first: a label that fails here leaves no empty button behind (they piled up as "TEXT BLOCK" rows)
    w:SetDisplayText(FText(label))
    local ours = box == nil -- (our pages' rows: ROW_W wide; the item in the game's own list keeps the game's width)
    box = box or column(menu)
    local kids = menu.MenuItemBox:GetAllChildren()
    local tpl = #kids >= 2 and kids[2]:get() or nil -- a middle item (the first / last have their own edge padding)
    local holder = w
    if ours then pcall(function()
        sbSeq = sbSeq + 1
        local sb = StaticConstructObject(StaticFindObject("/Script/UMG.SizeBox"), menu.WidgetTree, FName("CoopSyncRow_" .. sbSeq))
        sb:SetWidthOverride(ROW_W)
        sb:AddChild(w)
        holder = sb
    end) end
    local slot = box:AddChildToVerticalBox(holder)
    if tpl and tpl:IsValid() then
        pcall(function() w.Font = tpl.Font w.bEnableWrapText = false end)
        pcall(function()
            local t = tpl.Slot
            slot:SetPadding(t.Padding) slot:SetSize(t.Size)
            -- the item goes last in the game's list, after its last item (no bottom padding): the gap above it was
            -- half the others' (owner). A middle item's top + bottom above it, none below - as the game's last one
            if not ours then
                local p = t.Padding
                slot:SetPadding({ Left = p.Left, Top = p.Top + p.Bottom, Right = p.Right, Bottom = 0 })
            end
            slot:SetHorizontalAlignment(t.HorizontalAlignment) slot:SetVerticalAlignment(t.VerticalAlignment)
        end)
    end
    pcall(function() w:PreConstruct(false) end) -- applies the font to its text
    return w, holder
end

-- a row that does nothing (the lobby's state, the players, what to do next): a text header in our column, in its
-- place among the buttons, in the buttons' font - not a button (owner, alpha 19: back in the column, but as headers;
-- alpha 18 had them as buttons, alpha 19 as text at the right)
local headers = {}
local function newHeader(menu, label)
    local box = column(menu)
    sbSeq = sbSeq + 1
    local t = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), menu.WidgetTree, FName("CoopSyncHeader_" .. sbSeq))
    t:SetText(FText(label))
    local kids = menu.MenuItemBox:GetAllChildren()
    local tpl = #kids >= 2 and kids[2]:get() or nil
    pcall(function() if tpl then t:SetFont(tpl.Font) end end)
    pcall(function() t:SetJustification(1) end) -- centre, as the buttons' labels
    pcall(function() t:SetOpacity(0.7) end) -- (dimmer than a button's label: it is not one)
    local slot = box:AddChildToVerticalBox(t)
    pcall(function()
        slot:SetHorizontalAlignment(2)
        local p = tpl and tpl.Slot.Padding
        slot:SetPadding({ Left = 0, Top = (p and p.Top or 6) + 6, Right = 0, Bottom = (p and p.Bottom or 6) })
    end)
    t:SetVisibility(4) -- SelfHitTestInvisible
    headers[#headers + 1] = t
    return t
end
local function clearRows()
    for _, r in ipairs(rows) do pcall(function() (r.holder or r.w):RemoveFromParent() end) end
    rows = {}
    for _, t in ipairs(headers) do pcall(function() t:RemoveFromParent() end) end
    headers = {}
    M.infoLines = {}
end

local function showGameItems(show)
    local menu = pauseMenu()
    if not menu then hidden = {} return end
    if not show then
        hidden = {}
        local kids = menu.MenuItemBox:GetAllChildren()
        for i = 1, #kids do
            local w = kids[i]:get()
            local mi = item()
            if not (mi and w:GetAddress() == mi:GetAddress()) then
                hidden[#hidden + 1] = { w = w, vis = w:GetVisibility() }
                w:SetVisibility(1) -- Collapsed
            end
        end
        -- the game's whole row (its items, the route panel): our column shows instead
        pcall(function()
            local row = menu.MenuItemBox:GetParent()
            hidden[#hidden + 1] = { w = row, vis = row:GetVisibility() }
            row:SetVisibility(1)
        end)
        pcall(function() column(menu):SetVisibility(4) end) -- SelfHitTestInvisible: its buttons take clicks
        local mi = item()
        if mi then mi:SetVisibility(1) end
    else
        for _, h in ipairs(hidden) do pcall(function() h.w:SetVisibility(h.vis) end) end
        hidden = {}
        pcall(function() local b = held(ourBoxH) if b then b:SetVisibility(1) end end)
        local mi = item()
        if mi then pcall(function() mi:SetVisibility(0) end) end -- Visible
    end
end


-- where the host is (its session line): garage / a zone
local function hostWhere()
    local s = kv((Link.read(Link.docPath(chan, "inbox", "host-session.txt")) or ""):match("^[^\r\n]*"))
    if not s.world then return nil end
    if s.world == "-" then return L("menu.where_garage") end
    return L("menu.where_zone", s.world)
end

---------------------------------------------------------------------------------------------------
-- rows shared by the pause menu pages and the F7 panel: { label, act or nil }

function M.lobbyRows(add, setPage)
    local n = net()
    if not n.up then
        local err = (n.head.err or ""):gsub("_", " ")
        -- (the game brings Steam up a little after the mod starts: link.lua tries again by itself)
        if err:find("not initialized", 1, true) then add(L("menu.net_waiting"))
        else add(err ~= "" and L("menu.net_unavailable_err", err) or L("menu.net_unavailable")) end
        add(L("menu.net_restart"), function() return Session.startNet() end)
    elseif not n.inLobby then
        add(L("menu.create_lobby"), function() netCmd("create") return L("menu.creating_lobby") end)
        for _, i in ipairs(n.invites) do
            add(L("menu.invitation", i.name), function() netCmd("join " .. i.lobby) return L("menu.joining") end)
        end
        for _, f in ipairs(n.friends) do
            if f.ingame and f.lobby ~= "0" then
                -- ("local-copy": the other game on this PC, the two-games test script's local link)
                local who = f.name == "local-copy" and L("menu.local_copy") or f.name
                add(L("menu.join_lobby", who), function() netCmd("join " .. f.lobby) return L("menu.joining") end)
            end
        end
    else
        -- (no ping: each change rebuilt the page - owner, alpha 19)
        add(L("menu.lobby_count", #n.members))
        -- (the on-foot role is frozen, owner 2026-10-24: everyone comes with an own car, no role switch)
        for _, m in ipairs(n.members) do
            add(string.format("%s%s%s", m.name, m.me and L("menu.tag_me") or "", m.owner and L("menu.tag_host") or ""))
        end
        if n.owner then
            add(L("menu.you_pick"))
        else
            local where = hostWhere()
            add(where == nil and L("menu.host_not_in_game") or where == L("menu.where_garage") and L("menu.wait_host_drive") or L("menu.host_in_zone"))
        end
        add(L("menu.invite_friend"), function() friendsPage = 1 setPage("friends") return "" end)
        add(L("menu.leave_lobby"), function() netCmd("leave") return L("menu.left_lobby") end)
    end
    -- (out of a lobby the other side closing is the leave itself: it stayed on the menu for good, owner's alpha 18 test)
    local err = n.head.err or ""
    if err:find("other_side_closed", 1, true) and not n.inLobby then err = "" end
    if err ~= "" then add(L("menu.net_error", (err:gsub("_", " ")))) end
end

-- friends: those in Pacific Drive first (the network sorts: in this game, online, name), online only, a page at a time
function M.friendRows(add, setPage)
    local n = net()
    local list = {}
    for _, f in ipairs(n.friends) do if f.online then list[#list + 1] = f end end
    local pages = math.max(1, math.ceil(#list / FRIENDS_PER_PAGE))
    if friendsPage > pages then friendsPage = pages end
    if #list == 0 then add(L("menu.no_friends")) end
    for i = (friendsPage - 1) * FRIENDS_PER_PAGE + 1, math.min(#list, friendsPage * FRIENDS_PER_PAGE) do
        local f = list[i]
        add((f.ingame and "▶ " or "") .. f.name .. (f.ingame and L("menu.in_game_tag") or ""), function()
            netCmd("invite " .. f.id) return L("menu.invite_sent", f.name)
        end)
    end
    if pages > 1 then
        add(L("menu.page_next", friendsPage, pages), function()
            friendsPage = friendsPage % pages + 1 return ""
        end)
    end
    add(L("common.back"), function() setPage("coop") return "" end)
end

function M.debugRows(add, setPage)
    local function dbg(label, action) add(label, function() return Session.debug(action) end) end
    dbg(L("dbg.resync"), "resync")
    dbg(L("dbg.restart"), "restart")
    dbg(L("dbg.teleport"), "teleport")
    dbg(L("dbg.restore_car"), "restorecar")
    add(L("dbg.report"), function() return M.report() end)
    dbg(L("dbg.leave"), "leave")
    add(L("dbg.state"), function() setPage("state") return "" end)
end

function M.stateRows(add, setPage)
    local n = net()
    add(L("dbg.st_session", Session.info():sub(1, 110)))
    add(L("dbg.st_net", tostring(n.head.state), tostring(n.head.lobby), tostring(n.head.peer), tostring(n.head.ping)))
    local okP, p = pcall(function() return require("playersync").report() end)
    add(L("dbg.st_players", tostring(okP and p or "-"):sub(1, 110)))
    local okS, st = pcall(function() return require("statesync").report() end)
    add(L("dbg.st_world", tostring(okS and st or "-"):sub(1, 110)))
    add(L("common.back"), function() setPage("main") return "" end)
end

-- the F7 panel's pages: main = lobby + debug, friends, state
function M.panelRows(p, setPage)
    local r = {}
    local function add(label, act) r[#r + 1] = { label = label, act = act } end
    if p == "friends" then
        M.friendRows(add, function(x) setPage(x == "coop" and "main" or x) end)
    elseif p == "state" then
        M.stateRows(add, setPage)
    else
        M.lobbyRows(add, setPage)
        add(L("menu.debug_header"))
        M.debugRows(add, setPage)
    end
    return r
end

-- the pause menu's pages
local function pageRows()
    local r = {}
    local function add(label, act) r[#r + 1] = { label = label, act = act } end
    local function setPage(x) page = x end
    if lastMsg ~= "" then add("» " .. lastMsg) end
    if page == "coop" then
        M.lobbyRows(add, setPage)
        add(L("common.back"), function() page = nil return "" end)
    elseif page == "friends" then
        M.friendRows(add, setPage)
    end
    return r
end

M.infoLines = {} -- (the page's header rows: tests read them)

local function render()
    local menu = pauseMenu()
    if not menu then return end
    if not page then
        if #rows > 0 or #hidden > 0 then clearRows() showGameItems(true) sig = "" end
        return
    end
    local r = pageRows()
    local labels = {}
    for _, x in ipairs(r) do labels[#labels + 1] = x.label end
    local s = table.concat(labels, "\n")
    local acts = {}
    for _, x in ipairs(r) do if x.act then acts[#acts + 1] = x end end
    if s == sig and #rows == #acts then
        for i, x in ipairs(acts) do rows[i].act = x.act end
        -- the game shows some of its items again by itself (they came out as empty "TEXT BLOCK" rows among ours)
        for _, h in ipairs(hidden) do pcall(function() if h.w:GetVisibility() ~= 1 then h.w:SetVisibility(1) end end) end
        return
    end
    if #hidden == 0 then showGameItems(false) end
    clearRows()
    -- (rows that do nothing - the lobby's state, the players, the last result - are text headers in their place, not
    -- buttons: newHeader)
    local info = {}
    for _, x in ipairs(r) do
        if x.act then
            local ok, w, holder = pcall(newButton, menu, x.label)
            if ok then rows[#rows + 1] = { w = w, holder = holder, label = x.label, act = x.act } else log("button '" .. tostring(x.label) .. "' (" .. type(x.label) .. "): " .. tostring(w)) end
        else
            info[#info + 1] = x.label
            local ok, e = pcall(newHeader, menu, x.label)
            if not ok then log("header '" .. tostring(x.label) .. "': " .. tostring(e)) end
        end
    end
    M.infoLines = info
    sig = s
end

local function onPressed(btn)
    local a = btn:GetAddress()
    local mi = item()
    if mi and a == mi:GetAddress() then page = "coop" lastMsg = "" render() return end
    for _, r in ipairs(rows) do
        if r.w:GetAddress() == a then
            if r.act then
                local ok, msg = pcall(r.act)
                lastMsg = ok and (msg or "") or L("common.error", tostring(msg))
                sig = "" -- rebuild
                render()
            end
            return
        end
    end
end

-- our item in the game's pause menu (re-added whenever the menu was rebuilt)
local function ensureItem()
    local menu = pauseMenu()
    if not menu then menuItemH = nil return end
    -- (UE4SS gives a new Lua object per read: compare addresses)
    if item() and menuItemOwner == menu:GetAddress() then return end
    local ok, w, holder = pcall(newButton, menu, L("common.coop"), menu.MenuItemBox)
    if ok then
        menuItemH, menuItemOwner = hold(w), menu:GetAddress()
        -- (at the end of the game's list: the box has no ShiftChild here - that call only ever failed)
    else log("menu item: " .. tostring(w)) end
end

-- for the automated test: open the pause menu on the co-op page, what it shows, press a row by its label start
function M.open()
    local ui, menu = FindFirstOf("BP_UIManager_C"), pauseMenu()
    local visible = false
    if menu then pcall(function() visible = menu:IsVisible() end) end
    if ui and not visible then pcall(function() ui["Set Pause Menu Opened"](ui, true) end) end
    After(300, function() ensureItem() page = "coop" render() end)
end
function M.info()
    local labels = {}
    for _, r in ipairs(rows) do labels[#labels + 1] = r.label end
    local menu = pauseMenu()
    local vis = false
    if menu then pcall(function() vis = menu:IsVisible() end) end
    -- shown: the item really in the game's list and visible there (alpha 9 made it, in a collapsed box of ours)
    local shown = false
    pcall(function()
        local mi = item()
        shown = mi ~= nil and mi:IsVisible() and mi:GetParent():GetAddress() == menu.MenuItemBox:GetAddress()
    end)
    local hv = 0
    for _, t in ipairs(headers) do pcall(function() if t:GetParent() and t:GetParent():GetAddress() == held(ourBoxH):GetAddress() then hv = hv + 1 end end) end
    return string.format("menu=%s visible=%s item=%s shown=%s page=%s rows=%d hidden=%d headers=%d | %s | headers: %s", tostring(menu ~= nil), tostring(vis),
        tostring(item() ~= nil), tostring(shown), tostring(page), #rows, #hidden, hv, table.concat(labels, " / "), table.concat(M.infoLines, " / "))
end
function M.press(prefix)
    -- (a test names a row by its text key, "common.back", or by the start of its label as shown: the tests run in
    -- Russian, COOPSYNC_LANG=ru)
    local want = Loc.has(prefix) and L(prefix) or prefix
    if prefix == "Кооператив" or want == L("common.coop") then local mi = item() if mi then onPressed(mi) end return M.info() end -- (loc: test label)
    for _, r in ipairs(rows) do
        if r.label:sub(1, #want) == want then onPressed(r.w) return lastMsg end
    end
    return "no row " .. prefix
end

function M.report()
    local script = (Session.modDir() .. "tools/collect-report.ps1"):gsub("/", "\\")
    local cmd = string.format('start "" /b powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%s" -Chan "%s"', script, chan:gsub("/", "\\"))
    os.execute(cmd)
    return L("dbg.report_started")
end

local function loop(ms, fn)
    local h
    h = LoopInGameThreadWithDelay(ms, function()
        -- (an error escaping here made UE4SS drop the loop for good: the co-op menu item never came back, alpha 9)
        local t0 = os.clock()
        local ok, r = pcall(fn)
        if CoopSyncHitch then CoopSyncHitch.spent(os.clock() - t0, "menu") end
        if not ok then
            if CoopSyncHitch then CoopSyncHitch.note("loop error: " .. tostring(r):sub(1, 200)) end
            return
        end
        if r == true and h then CancelDelayedAction(h) end
    end)
    return h
end

function M.start(sessionModule)
    Session = sessionModule
    Session.menu = M
    chan = Session.channel()
    local hooked = false
    local n = 0
    loop(REFRESH_MS, function()
        local menu = pauseMenu()
        -- the buttons' blueprint is loaded with the game's UI, not before the mods start
        if menu and not hooked then
            local ok, e = pcall(Hook, PRESSED_FN, function(self) pcall(onPressed, self:get()) end)
            hooked = true
            if not ok then log("pressed hook: " .. tostring(e)) end
        end
        local visible = false
        if menu then pcall(function() visible = menu:IsVisible() end) end
        if visible then M.visibleSince = M.visibleSince or os.clock() else M.visibleSince = nil end
        if not visible then
            -- closed while a co-op page showed: our rows out, the game's items back (before, the next pause showed
            -- the game's buttons and the old page's rows together and nothing opened any more)
            if page or #rows > 0 or #hidden > 0 then
                pcall(clearRows) pcall(showGameItems, true)
                page, rows, hidden, sig = nil, {}, {}, ""
            end
            return
        end
        pcall(ensureItem) -- at once when the pause menu shows (it took up to a second before)
        n = n + 1
        if page and n % 10 == 0 then pcall(render) elseif page and sig == "" then pcall(render) end
    end)
    -- Esc in the co-op pause (owner's real test: "the pause menu sticks, Esc does nothing"; esc-test reproduced it:
    -- with the world running under the menu the game takes Esc for "open the pause menu" again and never closes it).
    -- An Esc while the pause menu has been open for a while closes it the way our F7 panel does (the HUD's
    -- SetPauseMenuWidgetVisible(false)); the Esc that opened it is younger than ESC_OPEN_S.
    -- (polled on the game thread: RegisterKeyBind's callback ran on another thread, hooks.lua onKey)
    local OnKey = CoopSyncOnKey or dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "hooks.lua").onKey
    OnKey(0x1B, function() -- Esc
        do
            -- the F7 panel shows: Esc closes it and the pause menu under it (the panel puts the menu's look back)
            if CoopSyncPanel and CoopSyncPanel.isShown and CoopSyncPanel.isShown() then
                After(120, function()
                    if CoopSyncPanel.isShown() then pcall(CoopSyncPanel.close) end
                    local m, vis = pauseMenu(), false
                    if m then pcall(function() vis = m:IsVisible() end) end
                    if vis then closePause() end
                end)
                return
            end
            if not (Session.coopActive and Session.coopActive()) then return end
            if not (M.visibleSince and os.clock() - M.visibleSince > ESC_OPEN_S) then return end
            After(120, function()
                local m, vis = pauseMenu(), false
                if m then pcall(function() vis = m:IsVisible() end) end
                if vis then
                    closePause()
                    M.escClosed = (M.escClosed or 0) + 1
                end
            end)
        end
    end)
    return "menu: pause menu item"
end

return M
