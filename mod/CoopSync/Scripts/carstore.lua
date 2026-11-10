-- Car storages (owner 2026-10-27: the other's car's trunk and its other storages must work like the own car's).
-- Probed (cmds/car-storage-probe.lua, cmds/twin-trunk-probe.lua): the trunk part (BP_Storage_Trunk_Base: basic /
-- tier 2 / tier 3) points its container component (BP_InventoryContainerComponent_ExternalInventory .Container) at
-- the inventory manager's Inventory_Trunk - and the twin's trunk part did the same: opening the other's car showed
-- (and changed) the OWN trunk. A container of the trunk container's class with the trunk's layout set there instead
-- stays (the part does not point it back). Storage attachments (IA_Attach_Util_Storage_Small / Large) and other car
-- items keep their contents in containers of their own item instance (outer = the item); the twin's items are new:
-- empty. Now:
--   * the twin's trunk component points at a container of its own, filled with the owner's trunk;
--   * the twin's items' containers are filled with those of the owner's items in the same car slots;
--   * the local player's changes there go to the owner, whose real storage changes the same way: a put lands on the
--     tile the player put it on, a take comes from the tile it was taken from, a move inside goes tile to tile (the
--     tile layout's CanInsertItem / EmplaceSlot; anywhere when that tile is taken there);
--   * each change has a number; the owner's CS names, per storage, the last one it has done: an older CS (sent before
--     the change reached the owner) is not filled in - it put taken items back / took put ones away for a moment,
--     and refilled the storage in the owner's old order. The owner's own changes made meanwhile come with the next.
--   CS <time> <key>~<done> <container> ...               owner -> the other side (changed: checked every second, and
--                                                        every 10 s); key: trunk / large / <car slot>#<n> (the n-th
--                                                        container of the item in that slot); done: the number of the
--                                                        visitor's last change done there; container: lootsync's
--   CX <time> <key> <+|-|~> <n> <item spec> <tile> <tile2> <number>
--                                                        the other side -> owner: n items put / taken / moved; tile
--                                                        X_Y_R (rotated 0/1) put on / taken from / moved from, tile2
--                                                        moved to ("-": none)
--   CN <time> <key> <n> <item spec>                     owner -> the other side: a put that did not fit (back to
--                                                        the player)
--   CT <time> <key> <n> <archetype>                     owner -> the other side: a take the owner no longer had (the
--                                                        player's copy of it removed: no duplicate)
local M = {}
local Loot, Twin
function M.init(syncModule, twinModule) Loot, Twin = syncModule.Loot, twinModule end
M.stats = { sent = 0, applied = 0, local_ = 0, ownerPut = 0, ownerTake = 0, nack = 0, back = 0, missing = 0, removed = 0, errors = 0 }

local TRUNKS = { trunk = "Inventory_Trunk", large = "Inventory_LargeTrunk" }
local function invManager() return (CoopSyncFirst or FindFirstOf)("BP_InventoryManager_C") end
local function fullName(o) return (o:GetFullName():gsub("^%S+%s+", "")) end
local function quietly(f, ...)
    local LH = CoopSyncLootHook
    if LH then LH.quiet = true end
    local ok, r = pcall(f, ...)
    if LH then LH.quiet = false end
    if not ok then M.stats.errors = M.stats.errors + 1 M.stats.lastErr = tostring(r) end
    return ok and r
end

-- the item in each slot of a named container: slot name -> item
local function slotItems(cont)
    local t = {}
    local names = {}
    cont:GetSlotNames(names)
    for i = 1, #names do
        local n = names[i]:get()
        local sl = cont:GetSlot(n)
        if sl and sl:IsValid() and sl.Items:GetArrayNum() > 0 then
            local it = sl.Items[1]
            if it and it:IsValid() then t[n:ToString()] = it end
        end
    end
    return t
end
-- "<slot>#<n>" -> the container of the car items in a named container (the car's slots)
local function itemContainers(cont)
    local items = slotItems(cont)
    local keys, slotOf = {}, {}
    for slot, it in pairs(items) do
        local k = it:GetFullName()
        keys[#keys + 1] = k
        slotOf[k] = slot
    end
    local out = {}
    if #keys == 0 then return out end
    for k, list in pairs(Loot.containersByOuter(keys)) do
        local slot = slotOf[k]
        if slot then
            table.sort(list, function(a, b) return a:GetFullName() < b:GetFullName() end)
            for n, c in ipairs(list) do out[slot .. "#" .. n] = c end
        end
    end
    return out
end

-- Owner side: its car's storages as the CS fields (nil: no inventory)
local function ownStorages()
    local im = invManager()
    if not (im and im:IsValid()) then return nil end
    local out = {}
    for key, f in pairs(TRUNKS) do
        local c = im[f]
        if c and c:IsValid() then out[key] = c end
    end
    local car = im.Inventory_CarEquipped
    if car and car:IsValid() then
        for k, c in pairs(itemContainers(car)) do out[k] = c end
    end
    return out
end
function M.ownLine()
    local st = ownStorages()
    if not st then return nil end
    local keys = {}
    for k in pairs(st) do keys[#keys + 1] = k end
    table.sort(keys)
    local f = {}
    for _, k in ipairs(keys) do
        local ok, s = pcall(Loot.serContainer, st[k])
        if ok and s then f[#f + 1] = k .. "~" .. (M.done[k] or 0) f[#f + 1] = s end
    end
    return table.concat(f, "\t")
end
M.done = {} -- owner: storage key -> the number of the other player's last change done there

---------------------------------------------------------------------------------------------------
-- the twin side
local twins = {} -- twin address -> { trunk = { key -> container path }, base = { key -> what it held after the last
                 -- fill / sent change }, applied = { key -> the owner's string last filled in }, sent = { key -> the
                 -- number of the last change sent }, sentAt = { key -> os.clock() of it } }
local seq = 0 -- the changes' numbers (one count for all storages: a new twin does not start again below the owner's)
local function stateOf(twin)
    local k = twin:GetAddress()
    local t = twins[k]
    if not t or t.name ~= twin:GetFullName() then
        t = { name = twin:GetFullName(), trunk = {}, base = {}, applied = {}, sent = {}, sentAt = {} }
        twins[k] = t
    end
    return t
end
-- The twin's trunk parts point at containers of their own (a part pointing at the own trunk again - a new part after
-- an equipment change - is pointed back). key -> container.
local function twinTrunks(twin, t)
    local im = invManager()
    local own = {}
    for key, f in pairs(TRUNKS) do
        local c = im and im[f]
        if c and c:IsValid() then own[c:GetAddress()] = key end
    end
    local out = {}
    local att = {}
    pcall(function() twin:GetAttachedActors(att, true) end)
    for i = 1, #att do
        local a = att[i]:get()
        local comp
        pcall(function() comp = a.BP_InventoryContainerComponent end)
        local cur
        pcall(function() cur = comp.Container end)
        if cur and cur:IsValid() then
            local key = own[cur:GetAddress()]
            if key then
                local mine = t.trunk[key] and StaticFindObject(t.trunk[key])
                if not (mine and mine:IsValid()) then
                    local real = cur
                    mine = StaticConstructObject(real:GetClass(), a)
                    pcall(function() mine:SetLayout(real.Layout) end)
                    pcall(function() mine:SetNewSlotParameters(real.NewSlotCapacity, real.NewSlotMaxForceCapacity, real.NewSlotRules, real.NewSlotIgnoreOuter) end)
                    t.trunk[key] = fullName(mine)
                    t.applied[key], t.base[key] = nil, nil
                end
                comp.Container = mine
                M.stats.pointed = (M.stats.pointed or 0) + 1
                out[key] = mine
            else
                for k2, p in pairs(t.trunk) do
                    if fullName(cur) == p then out[k2] = cur end
                end
            end
        end
    end
    return out
end
-- the twin's trunk parts pointed at their own containers now (playersync, the moment the player looks at one: a trunk
-- part spawned again - an equipment change - points at the local player's own trunk until the next check, and the
-- inventory screen opened then showed that; owner, alpha 16: "the friend opened my trunk box: his own loot there")
function M.repoint(twin) return twinTrunks(twin, stateOf(twin)) end
local function twinStorages(twin, t)
    local out = twinTrunks(twin, t)
    local cont = Twin and Twin.twinContainer(twin)
    if cont and cont:IsValid() then
        for k, c in pairs(itemContainers(cont)) do out[k] = c end
    end
    return out
end

-- the owner's CS fields (key~done, container, ...) into the twin's storages; false: not ready yet. A storage with a
-- change of the local player the owner has not done yet keeps what it shows (for 5 s at most: an owner that started
-- again counts from 0).
local STALE_S = 5
function M.apply(twin, fields)
    local t = stateOf(twin)
    local st = twinStorages(twin, t)
    local done = true
    for i = 1, #fields - 1, 2 do
        local key, ack = fields[i]:match("^(.-)~(%d+)$")
        key, ack = key or fields[i], tonumber(ack) or 0
        local spec = fields[i + 1]
        local c = st[key]
        if not c then
            done = false
        elseif ack < (t.sent[key] or 0) and os.clock() - (t.sentAt[key] or 0) < STALE_S then
            M.stats.stale = (M.stats.stale or 0) + 1
        elseif t.applied[key] ~= spec then
            quietly(Loot.fillContainer, c, spec)
            t.applied[key] = spec
            t.base[key] = quietly(Loot.serContainer, c) or nil
            M.stats.applied = M.stats.applied + 1
        end
    end
    return done
end

-- the twin's storages in ownLine's form without the "~done" (the tests' state comparison)
function M.twinLine(twin)
    local st = twinStorages(twin, stateOf(twin))
    local keys = {}
    for k in pairs(st) do keys[#keys + 1] = k end
    table.sort(keys)
    local f = {}
    for _, k in ipairs(keys) do
        local ok, s = pcall(Loot.serContainer, st[k])
        if ok and s then f[#f + 1] = k f[#f + 1] = s end
    end
    return table.concat(f, "\t")
end

-- an item string's archetype
local function archOf(spec) return spec:match("^([^{*]*)") end
-- items of a container string: archetype -> n, "<tile>|<archetype>" -> n, archetype -> one whole item string
local function bags(spec)
    local arch, at, whole = {}, {}, {}
    local body = (spec or ""):match("^[^!]*!(.*)$") or ""
    for _, sspec in ipairs(body == "" and {} or Loot.splitTop(body, ";")) do
        local tile = sspec:match("^([^=]*)=") or "-"
        for _, it in ipairs(Loot.splitTop(sspec:match("^[^=]*=(.*)$") or "", ",")) do
            if it ~= "" then
                local a = archOf(it)
                arch[a] = (arch[a] or 0) + 1
                at[tile .. "|" .. a] = (at[tile .. "|" .. a] or 0) + 1
                whole[a] = whole[a] or it
            end
        end
    end
    return arch, at, whole
end
-- the tiles where archetype a went up from one bag to another, once per item
local function tilesUp(a, from, to)
    local out = {}
    for k, n in pairs(to) do
        local tile, ka = k:match("^(.-)|(.*)$")
        if ka == a then
            for _ = 1, n - (from[k] or 0) do out[#out + 1] = tile end
        end
    end
    table.sort(out)
    return out
end
-- What the local player changed in the twin's storages since the last fill / check, as CX fields after the time:
-- "<key> <op> 1 <item> <tile> <tile2> <number>", one per item. Per archetype: fewer -> takes (from the tiles where
-- it went down), more -> puts (on the tiles where it went up, a whole item string to recreate), the rest of its
-- ups and downs pair up as moves.
function M.changes(twin)
    local t = stateOf(twin)
    local st = twinStorages(twin, t)
    local out = {}
    for key, c in pairs(st) do
        local base = t.base[key]
        if base then
            local ok, cur = pcall(Loot.serContainer, c)
            if ok and cur and cur ~= base then
                local aNow, atNow, wNow = bags(cur)
                local aWas, atWas = bags(base)
                local seen = {}
                for a in pairs(aNow) do seen[a] = true end
                for a in pairs(aWas) do seen[a] = true end
                for a in pairs(seen) do
                    local d = (aNow[a] or 0) - (aWas[a] or 0)
                    local ups, downs = tilesUp(a, atWas, atNow), tilesUp(a, atNow, atWas)
                    local function add(op, item, tile, tile2)
                        seq = seq + 1
                        out[#out + 1] = string.format("%s\t%s\t1\t%s\t%s\t%s\t%d", key, op, item, tile or "-", tile2 or "-", seq)
                        t.sent[key], t.sentAt[key] = seq, os.clock()
                    end
                    local u, w = 1, 1
                    for _ = 1, math.max(0, -d) do add("-", a, downs[w]) w = w + 1 end
                    for _ = 1, math.max(0, d) do add("+", wNow[a] or a, ups[u]) u = u + 1 end
                    while u <= #ups and w <= #downs do add("~", a, downs[w], ups[u]) u, w = u + 1, w + 1 end
                end
                t.base[key] = cur
            end
        end
    end
    M.stats.local_ = M.stats.local_ + #out
    return out
end

---------------------------------------------------------------------------------------------------
-- the owner side: a change the other player made in its twin of this car
local TILE_LAYOUT
local function tileOf(tile)
    local x, y, r = (tile or ""):match("^(%-?%d+)_(%-?%d+)_(%d)$")
    if not x then return nil end
    return { X = tonumber(x), Y = tonumber(y) }, r == "1"
end
-- an item onto a tile of the container (the tile layout's own placement), else anywhere; true: it is in there
local function placeAt(c, inst, tile)
    local at, rot = tileOf(tile)
    if at then
        TILE_LAYOUT = TILE_LAYOUT or StaticFindObject("/Script/PenDriverInventory.ItemTileLayout")
        pcall(function()
            local lay = c.Layout
            if lay and lay:IsValid() and lay:IsA(TILE_LAYOUT) and lay:CanInsertItem(c, inst, at, rot, false) then
                lay:EmplaceSlot(c, inst, at, rot, false)
            end
        end)
        local s = c:FindSlot(inst)
        if s and s:IsValid() then M.stats.onTile = (M.stats.onTile or 0) + 1 return true end
    end
    if not c:AddItem(inst, true) then return false end
    local s = c:FindSlot(inst)
    return s and s:IsValid() or false
end
-- an item of archetype a in the container, the one on that tile first
local function itemOf(c, a, tile)
    local at, rot = tileOf(tile)
    local any
    for si = 1, c.Slots:GetArrayNum() do
        local s = c.Slots[si]
        if s and s:IsValid() and s.Items:GetArrayNum() > 0 then
            local it = s.Items[s.Items:GetArrayNum()]
            if it and it:IsValid() and it.Archetype:IsValid() and fullName(it.Archetype) == a then
                local here = false
                if at then pcall(function() here = s.Location.X == at.X and s.Location.Y == at.Y and s.bRotated == rot end) end
                if here then return it end
                any = any or it
            end
        end
    end
    return any
end
-- returns "nack" n (puts that did not fit), "missing" n (takes / moves of items not there any more), or nil
function M.ownerChange(key, op, n, spec, tile, tile2, number)
    if number then M.done[key] = math.max(M.done[key] or 0, number) end
    local st = ownStorages()
    local c = st and st[key]
    if not (c and c:IsValid()) then M.stats.errors = M.stats.errors + 1 return nil end
    n = math.max(0, math.floor(n or 0))
    if op == "+" then
        local failed = 0
        for _ = 1, n do
            local ok = quietly(function()
                local inst = Loot.newItem(spec)
                if not inst then return false end
                if placeAt(c, inst, tile) then return true end
                pcall(function() inst:Remove(true) end)
                return false
            end)
            if ok then M.stats.ownerPut = M.stats.ownerPut + 1 else failed = failed + 1 end
        end
        if failed > 0 then M.stats.nack = M.stats.nack + failed return "nack", failed end
        return nil
    end
    local a = archOf(spec)
    local got = 0
    for _ = 1, n do
        local done = quietly(function()
            local it = itemOf(c, a, tile)
            if not it then return false end
            c:RemoveItem(it)
            if op == "~" then
                -- moved inside: onto its new tile, else back where it was
                if not placeAt(c, it, tile2) then placeAt(c, it, tile) end
                M.stats.ownerMove = (M.stats.ownerMove or 0) + 1
            else
                pcall(function() it:Remove(true) end)
                M.stats.ownerTake = M.stats.ownerTake + 1
            end
            return true
        end)
        if done then got = got + 1 end
    end
    if got < n and op == "-" then M.stats.missing = M.stats.missing + (n - got) return "missing", n - got end
    return nil
end

-- the other side: a put the owner refused -> back to the player; a take it no longer had -> the player's copy removed
function M.giveBack(n, spec)
    local inv = invManager().Inventory_Player
    local done = 0
    for _ = 1, n do
        local inst = Loot.newItem(spec)
        if inst and inv:AddItem(inst, true) then done = done + 1 end
    end
    M.stats.back = M.stats.back + done
    return done
end
function M.takeBack(n, archPath)
    local im = invManager()
    local arch = Loot.find(archPath)
    if not arch then return 0 end
    local left = n
    for _, f in ipairs({ "Inventory_PlayerHand", "Inventory_Player", "Inventory_Trunk", "Inventory_OverflowContainer" }) do
        local c = im[f]
        if left > 0 and c and c:IsValid() then
            local list = {}
            pcall(function() c:FindAllItemsOfType(arch, list) end)
            for i = 1, math.min(left, #list) do
                local it = list[i]:get()
                pcall(function() c:RemoveItem(it) it:Remove(true) end)
                left = left - 1
            end
        end
    end
    M.stats.removed = M.stats.removed + (n - left)
    return n - left
end

function M.info()
    local s = M.stats
    return string.format("cs_applied=%d cs_stale=%d cx_local=%d cx_put=%d cx_take=%d cx_move=%d on_tile=%d cn=%d back=%d ct=%d removed=%d store_errors=%d trunk_pointed=%d",
        s.applied, s.stale or 0, s.local_, s.ownerPut, s.ownerTake, s.ownerMove or 0, s.onTile or 0, s.nack, s.back, s.missing, s.removed, s.errors, s.pointed or 0)
end
return M
