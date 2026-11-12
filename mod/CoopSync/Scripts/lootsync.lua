-- Loot replication: contents of lootable containers and the parts of lootable templates (car wrecks).
-- Serialized per actor as one string:
--   lootable:  C|<slot>;<slot>;...          slot = item,item,...   (item = archetype path [+ {sub-containers}])
--   template:  T|<socket>=<partClass>@<archetype>@<mesh>[{sub}]~<socket>=...
-- Sub-containers (e.g. trunk contents owned by the trunk item instance) are written as
--   {<container>^<container>}  where container = slot;slot;...
local M = {}
-- path lookups: the native one answers a miss at once (UE4SS walks every object then: ~50 ms)
local SFO = StaticFindObject
if CoopNative_HasPath then SFO = function(p) if CoopNative_HasPath(p) then return StaticFindObject(p) end return nil end end

local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
-- same rule as spawnsync usable(): skip objects the GC already flagged Unreachable
local UNREACHABLE = EInternalObjectFlags and EInternalObjectFlags.Unreachable or nil
local DEAD = UNREACHABLE and EInternalObjectFlags.PendingKill and (UNREACHABLE | EInternalObjectFlags.PendingKill) or nil
local function alive(o)
    if not (o and o:IsValid()) then return false end
    if DEAD then return not o:HasAnyInternalFlags(DEAD) end -- one native flag test, no UFunction call
    if UNREACHABLE and o:HasAnyInternalFlags(UNREACHABLE) then return false end
    return KSL:IsValid(o)
end
local function path(o) return (alive(o) or (o and o:IsValid())) and (o:GetFullName():gsub("^%S+ ", "")) or "" end

-- pending work stores object paths, never UObject references (see spawnsync M.ref / M.deref)
local function refOf(a) return (a:GetFullName():gsub("^%S+ ", "")) end
local function derefOf(p)
    local o = p and SFO(p)
    if alive(o) then return o end
    return nil
end

-- the native helpers (mod/CoopNative world.cpp): "key\tpath" lines of a C++ walk -> { [key] = { path, ... } }
local N = CoopNative_OuterMap ~= nil
local function byKey(text)
    local by = {}
    for k, p in text:gmatch("([^\t\n]*)\t([^\n]*)\n") do
        by[k] = by[k] or {}
        table.insert(by[k], p)
    end
    return by
end

-- containers owned by an object (outer == object), built once per export/import pass
local ownedBy
local function buildOwners()
    if N then ownedBy = byKey(CoopNative_OuterMap("ItemContainer", "")) return end
    ownedBy = {}
    for _, c in ipairs(FindAllOf("ItemContainer") or {}) do
        if alive(c) then
            local o = c:GetOuter()
            if o and o:IsValid() then
                local k = o:GetFullName()
                ownedBy[k] = ownedBy[k] or {}
                table.insert(ownedBy[k], refOf(c)) -- paths: the maps live across several frames
            end
        end
    end
end

-- deep debug breadcrumbs (CoopSyncDebug path + CoopSyncDebugDeep), flushed per line
local function dcrumb(msg)
    if not (CoopSyncDebugDeep and CoopSyncDebug) then return end
    local f = io.open(CoopSyncDebug, "ab") if f then f:write("    . " .. msg .. "\n") f:close() end
end

-- An item's fuel (IP_Fuelable: canisters, fuel tanks) inside a container (owner, 2026-11-10: a canister put into a
-- container came out empty on the other side - an item made from its archetype comes with the archetype's fuel). In a
-- container's string an item's fuel follows it: <archetype>[{sub-containers}]*<fuel>. Not on wreck parts (their
-- sockets compare by the item's string: each side's own fuel would rebuild the part).
-- Read: BFL_ItemPropertyUtilityFns GetFuelableInfo (an archetype without the property: Max Fuel 0, remembered). Write:
-- one BP_FuelableComponent of ours pointed at the item (SetItemInstance) and its "Set Fuel", what a canister's world
-- actor does with its item.
local BFL, FUELCOMP
local noFuel = {} -- archetype path -> true: has no fuel
local function itemFuel(inst, archPath)
    if noFuel[archPath] then return nil end
    BFL = BFL or StaticFindObject("/Game/Systems/ScriptingLibraries/BFL_ItemPropertyUtilityFns.Default__BFL_ItemPropertyUtilityFns_C")
    if not (BFL and BFL:IsValid()) then return nil end
    local t1, t2 = {}, {}
    local ok = pcall(function() BFL:GetFuelableInfo(inst, FindFirstOf("PlayerController"), t1, t2, {}, {}, {}, {}) end)
    local cap = ok and tonumber(t2["Max Fuel"] or t2.Max_Fuel)
    if not (cap and cap > 0) then noFuel[archPath] = true return nil end
    return tonumber(t1.Fuel)
end
local function setItemFuel(inst, v)
    if not (FUELCOMP and FUELCOMP:IsValid()) then
        local cls = StaticFindObject("/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_FuelableComponent.BP_FuelableComponent_C")
        if not (cls and cls:IsValid()) then return false end
        FUELCOMP = StaticConstructObject(cls, FindFirstOf("PlayerController"), FName("None"), 0, 0, false, false, nil)
        if not (FUELCOMP and FUELCOMP:IsValid()) then FUELCOMP = nil return false end
    end
    local ok = pcall(function()
        FUELCOMP:SetItemInstance(inst, false)
        FUELCOMP["Set Fuel"](FUELCOMP, v)
    end)
    pcall(function() FUELCOMP:SetItemInstance(nil, false) end)
    return ok
end
M.itemFuel = function(inst) return inst and inst:IsValid() and itemFuel(inst, path(inst.Archetype)) or nil end
M.setItemFuel = setItemFuel
-- an item spec's archetype path (without its sub-containers and fuel)
function M.archOf(spec) return (spec or ""):match("^([^{*]*)") end

local serContainer
local function serItem(inst, withFuel)
    dcrumb("item")
    if not (inst and inst:IsValid()) then return "" end
    local s = path(inst.Archetype)
    local fuel = withFuel and itemFuel(inst, s)
    local subs = ownedBy[inst:GetFullName()]
    if subs and #subs > 0 then
        local t = {}
        for _, cp in ipairs(subs) do
            local c = derefOf(cp)
            if c then t[#t + 1] = serContainer(c) end
        end
        s = s .. "{" .. table.concat(t, "^") .. "}"
    end
    if fuel then s = s .. string.format("*%.2f", fuel) end
    return s
end

-- container = <layout path>!slot;slot;...   slot = X_Y_R=item,item,...  (tile position, rotated 0/1)
serContainer = function(c)
    dcrumb("container " .. c.Slots:GetArrayNum() .. " slots")
    local slots = {}
    for si = 1, c.Slots:GetArrayNum() do
        local s = c.Slots[si]
        if s and s:IsValid() then
            local items = {}
            for ii = 1, s.Items:GetArrayNum() do items[#items + 1] = serItem(s.Items[ii], true) end
            local x, y, r = 0, 0, 0
            pcall(function() x, y, r = s.Location.X, s.Location.Y, s.bRotated and 1 or 0 end)
            slots[#slots + 1] = string.format("%d_%d_%d=%s", x, y, r, table.concat(items, ","))
        end
    end
    local layout = ""
    pcall(function() layout = path(c.Layout) end)
    return layout .. "!" .. table.concat(slots, ";")
end

-- parent template full name -> its parts; built once per pass (FindAllOf walks all of GUObjectArray
-- when bForceGUObjectArrayForIteration is on, so it must not run once per template)
local partsByParent
local function buildParts()
    if N then partsByParent = byKey(CoopNative_ParentMap("LootableTemplatePart")) return end
    partsByParent = {}
    for _, p in ipairs(FindAllOf("LootableTemplatePart") or {}) do
        if alive(p) then
            local par = CoopSyncParentOf and CoopSyncParentOf(p) or nil
            if par and par:IsValid() then
                local k = par:GetFullName()
                partsByParent[k] = partsByParent[k] or {}
                table.insert(partsByParent[k], refOf(p))
            end
        end
    end
end

local function templateParts(t)
    local owned = partsByParent
    if not owned then buildParts() owned = partsByParent partsByParent = nil end
    local r = {}
    for _, pp in ipairs(owned[t:GetFullName()] or {}) do
        local p = derefOf(pp)
        if p then r[#r + 1] = p end
    end
    return r
end
M.templateParts = templateParts
-- how many parts a template has (paths only, no per-part lookup; cheap check for the client's detection)
function M.templatePartCount(t)
    local owned = partsByParent
    if not owned then buildParts() owned = partsByParent partsByParent = nil end
    return #(owned[t:GetFullName()] or {})
end

local function isTemplate(a) return a:IsA(StaticFindObject("/Script/PenDriverPro.LootableTemplate")) end
local trunkState -- (below: serialize)
local function lootableContainer(a)
    local ok, c = pcall(function() return a.InventoryContainer end)
    if ok and c and c:IsValid() and c:IsA(StaticFindObject("/Script/PenDriverInventory.ItemContainer")) then return c end
    return nil
end

local function isItemActor(a) return a:IsA(StaticFindObject("/Script/PenDriverInventory.ItemActorManifestation")) end
M.isItemActor = isItemActor

-- Grabbed resources (owner, alpha 18 item 39: "the guest took an anchor - not taken on the host"): anchors are
-- BP_Spawn_Resource_GrabBase actors, no item manifestation, so no W| pick-up saw them. Their state rides as R|0 / R|1
-- (SuccessfullyGrabbed). Taken on the other side the game's way with nobody grabbing: "Long Grab Complete" with no
-- grabber marks it taken (got, AnchorRemoved, the grab mesh hidden) and hands no item to anyone (probed 2026-11-01).
local GRAB_CLS = "/Game/Gameplay/Resources/BP_Spawn_Resource_GrabBase.BP_Spawn_Resource_GrabBase_C"
local grabCls
local function isGrab(a)
    if not (grabCls and grabCls:IsValid()) then
        grabCls = nil
        if CoopNative_HasPath and not CoopNative_HasPath(GRAB_CLS) then return false end
        grabCls = StaticFindObject(GRAB_CLS)
        if not (grabCls and grabCls:IsValid()) then grabCls = nil return false end
    end
    return a:IsA(grabCls)
end
local function grabbed(a)
    local ok, v = pcall(function() return a.SuccessfullyGrabbed end)
    return ok and v == true
end
function M.markGrabbed(a)
    if grabbed(a) then return false end
    return (pcall(function() a["Long Grab Complete"](a) end))
end

local function opened(a)
    local ok, v = pcall(function() return a.DataBlock_WasOpened end)
    return ok and v == true
end

-- Returns the loot string for an actor, or nil when it carries no loot.
--   lootable: C|...  (+ "#O" when it was opened)   world item: W|<item>   template: T|...
function M.serialize(a)
    if not ownedBy then buildOwners() end
    local c = lootableContainer(a)
    if c then return "C|" .. serContainer(c) .. (opened(a) and "#O" or "") end
    if isItemActor(a) then
        local inst
        pcall(function() inst = a.Instance end)
        -- hazards (landmines, grabbers) are item manifestations without an item: plain actors, no loot
        if inst and inst:IsValid() then return "W|" .. serItem(inst) end
        return nil
    end
    if isTemplate(a) then
        local t, s = {}, {}
        for _, p in ipairs(templateParts(a)) do
            dcrumb("part " .. p:GetFName():ToString())
            local inst = p.ItemInstance
            local mesh = ""
            pcall(function() mesh = path(p.RequestedMesh) end)
            local cls = path(p:GetClass())
            t[#t + 1] = string.format("%s=%s@%s@%s", p.MySocket:ToString(), cls, serItem(inst), mesh)
            local st = trunkState(p, cls)
            if st then s[#s + 1] = p.MySocket:ToString() .. "=" .. st end
        end
        table.sort(t)
        table.sort(s)
        return "T|" .. table.concat(t, "~") .. (#s > 0 and ("#S" .. table.concat(s, ",")) or "")
    end
    if isGrab(a) then return "R|" .. (grabbed(a) and "1" or "0") end
    return nil
end
-- A wreck's trunk (owner, alpha 16: "I pried the abandoned car's trunk open, the friend's stayed shut"): the trunk
-- part's state - 0 locked, 1 shut, 2 open - rides on the template's loot as "#S<socket>=<state>,..." after the parts.
-- Probed (cmds/openable-probe.lua): TrunkState is the zone's roll (locked / closed / empty) and stays; open is
-- AnimStateOpened, locked the BP_LockedComponent's IsLocked. The other side opens one the game's way: the lock let go
-- (ModifyStrength), then the trunk's own "lock opened" handler (its open animation, AnimStateOpened).
function trunkState(p, cls)
    local c = cls or path(p:GetClass())
    if not c:find("BP_TemplatePart_Trunk_", 1, true) or c:find("TrunkContents", 1, true) then return nil end
    local ok, v = pcall(function()
        if p.AnimStateOpened then return 2 end
        local lk = {}
        p.BP_LockedComponent:IsLocked(lk)
        return lk.Locked and 0 or 1
    end)
    return ok and v or nil
end
local function openTrunk(p)
    pcall(function()
        local lk = {}
        p.BP_LockedComponent:IsLocked(lk)
        if lk.Locked then p.BP_LockedComponent:ModifyStrength(-100, {}, {}, {}, {}) end
    end)
    return (pcall(function() p["BndEvt__BP_LockedComponent_K2Node_ComponentBoundEvent_1_OnLockOpened__DelegateSignature"](p, nil) end))
end
M.openTrunk = function(p) return openTrunk(p) end
-- "T|parts#S..." -> "T|parts", { socket = state }
function M.splitStates(loot)
    local body, s = loot:match("^(.-)#S([^#]*)$")
    if not body then return loot, {} end
    local st = {}
    for k, v in s:gmatch("([^=,]+)=(%d+)") do st[k] = tonumber(v) end
    return body, st
end
-- a template's trunk parts' states now: { socket = state }
function M.statesOf(a)
    local st = {}
    for _, p in ipairs(templateParts(a)) do
        local v = trunkState(p)
        if v then st[p.MySocket:ToString()] = v end
    end
    return st
end
-- the trunk states onto the template's parts (those that differ); returns how many were set
function M.applyStates(a, states)
    local n = 0
    for _, p in ipairs(templateParts(a)) do
        local want = states[p.MySocket:ToString()]
        -- (only opening: a trunk does not shut or lock again in the game)
        if want == 2 and trunkState(p) ~= 2 and openTrunk(p) then n = n + 1 end
    end
    return n
end

function M.beginPass() buildOwners() buildParts() end
function M.endPass() ownedBy = nil partsByParent = nil end

---------------------------------------------------------------------------------------------------
-- import

local cache = {}
-- a new import: assets found for an earlier world may be unloaded since (a cached one crashed a late join)
function M.resetCache() cache = {} end
local function find(p)
    if p == nil or p == "" then return nil end
    if cache[p] ~= nil then return cache[p] or nil end
    local o = SFO(p)
    if not (o and o:IsValid()) then
        local pkg = p:gsub("%.[^.]+$", "")
        for _, q in ipairs({ pkg .. "." .. pkg:match("[^/]+$"), pkg, p }) do
            pcall(function() LoadAsset(q) end)
            o = SFO(p)
            if o and o:IsValid() then break end
        end
    end
    cache[p] = (o and o:IsValid()) and o or false
    return cache[p] or nil
end

-- split respecting {...} nesting
local function splitTop(s, sep)
    local out, depth, cur = {}, 0, {}
    for ch in s:gmatch(".") do
        if ch == "{" then depth = depth + 1 elseif ch == "}" then depth = depth - 1 end
        if ch == sep and depth == 0 then out[#out + 1] = table.concat(cur) cur = {} else cur[#cur + 1] = ch end
    end
    out[#out + 1] = table.concat(cur)
    return out
end

local IBL = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
local stats

-- An item's sub-containers (a toolbox's contents) are objects with the item as outer and no other way to them
-- than a search over every container: that search per item made the guest's import of a big zone take 11 s and
-- its cleanup 15 s (owner: stalls up to a minute). Now the items with contents wait in subQueue and fillDeferred
-- does one search for all of them (and again for the contents' own contents).
local fillContainer
local subQueue = {}
local batch = 0 -- > 0: inside beginBatch / endBatch (the import): one fillDeferred at the end
local function makeItem(spec, ctx)
    local body, fuel = spec:match("^(.*)%*(%-?[%d.]+)$")
    if body then spec = body end
    local archPath, subs = spec:match("^([^{]*)(.*)$")
    local arch = find(archPath)
    if not arch then stats.missing[archPath] = true stats.failed = stats.failed + 1 return nil end
    local inst = IBL:CreateItemInstance(ctx, arch, 4)
    if not (inst and inst:IsValid()) then stats.failed = stats.failed + 1 return nil end
    stats.items = stats.items + 1
    -- (its fuel: the archetype's comes otherwise)
    if fuel then
        if setItemFuel(inst, tonumber(fuel)) then stats.fuelSet = (stats.fuelSet or 0) + 1 else stats.fuelFailed = (stats.fuelFailed or 0) + 1 end
    end
    -- the instance may have created its own (random) sub-containers: overwritten in order by fillDeferred
    if subs ~= "" then subQueue[#subQueue + 1] = { key = inst:GetFullName(), subs = subs, ctx = ctx } end
    return inst
end
-- containers by outer (full name), one search over all of them (keys: the outers wanted, native only: a C++ walk
-- that resolves them first and lists only their containers)
local function containersByOuter(keys)
    if N then
        local by = byKey(CoopNative_OuterMap("ItemContainer", keys and table.concat(keys, "\n") or ""))
        for k, paths in pairs(by) do
            local objs = {}
            for _, p in ipairs(paths) do
                local c = derefOf(p)
                if c then objs[#objs + 1] = c end
            end
            by[k] = objs
        end
        return by
    end
    local by = {}
    for _, c in ipairs(FindAllOf("ItemContainer") or {}) do
        local ok, o = pcall(function() return c:IsValid() and c:GetOuter() end)
        if ok and o and o:IsValid() then
            local k = o:GetFullName()
            by[k] = by[k] or {}
            table.insert(by[k], c)
        end
    end
    return by
end
function M.fillDeferred()
    local rounds = 0
    while #subQueue > 0 and rounds < 6 do
        rounds = rounds + 1
        local q = subQueue
        subQueue = {}
        local keys = {}
        for _, e in ipairs(q) do keys[#keys + 1] = e.key end
        local by = containersByOuter(keys)
        for _, e in ipairs(q) do
            local owned = by[e.key] or {}
            for i, cs in ipairs(splitTop(e.subs:sub(2, -2), "^")) do if owned[i] then fillContainer(owned[i], cs, e.ctx) end end
            -- (no yield here: "by" holds containers found this frame)
        end
    end
    subQueue = {}
    return rounds
end
-- fillDeferred as a job step (native only): one container map per round (paths, looked up when used: no objects kept
-- across frames), then the queued items a slice at a time until over() says the frame's time is up. true = done.
-- (the whole fill in one frame held the guest's game up to 1.4 s at the end of an import and in its cleanup)
function M.fillStep(cur, over)
    if not N then M.fillDeferred() return true end
    while true do
        if not cur.q then
            if #subQueue == 0 or (cur.rounds or 0) >= 6 then subQueue = {} return true end
            cur.rounds = (cur.rounds or 0) + 1
            cur.q, subQueue, cur.i = subQueue, {}, 1
            local keys = {}
            for _, e in ipairs(cur.q) do keys[#keys + 1] = e.key end
            cur.by = byKey(CoopNative_OuterMap("ItemContainer", table.concat(keys, "\n")))
            if over() then return false end
        end
        local ctx = FindFirstOf("PlayerController")
        while cur.i <= #cur.q do
            local e = cur.q[cur.i]
            cur.i = cur.i + 1
            local owned = cur.by[e.key] or {}
            for i, cs in ipairs(splitTop(e.subs:sub(2, -2), "^")) do
                local c = owned[i] and derefOf(owned[i])
                if c then fillContainer(c, cs, ctx) end
            end
            if over() then return false end
        end
        cur.q = nil
    end
end

function M.beginBatch() batch = batch + 1 if batch == 1 then buildParts() end end
-- deferFill: the caller runs fillStep in its own job steps
function M.endBatch(deferFill)
    batch = math.max(0, batch - 1)
    if batch == 0 then partsByParent = nil if not deferFill then M.fillDeferred() end end
end

-- Tile containers create slots on demand and stack equal items into one slot, so to rebuild the
-- host's exact stacks we temporarily mark existing slots full while adding the first item of a stack.
-- (Never call SetNumSlots on these containers: it inserts null slots and RemoveAllItems then crashes.)
fillContainer = function(c, spec, ctx)
    local layoutPath, body = spec:match("^([^!]*)!(.*)$")
    if not layoutPath then layoutPath, body = "", spec end
    if layoutPath ~= "" and path(c.Layout) ~= layoutPath then
        local lay = find(layoutPath)
        if lay then pcall(function() c:SetLayout(lay) end) end
    end
    c:RemoveAllItems()
    local caps = {}
    for _, sspec in ipairs(body == "" and {} or splitTop(body, ";")) do
        local x, y, r, items = sspec:match("^(%-?%d+)_(%-?%d+)_(%d)=(.*)$")
        local list = splitTop(items or "", ",")
        local first = makeItem(list[1], ctx)
        if first then
            for si = 1, c.Slots:GetArrayNum() do
                local s = c.Slots[si]
                if s and s:IsValid() then
                    local k = s:GetFullName()
                    if caps[k] == nil then caps[k] = { slot = s, cap = s.Capacity } end
                    s.Capacity = s.Items:GetArrayNum()
                end
            end
            c:AddItem(first, true)
            local slot = c:FindSlot(first)
            if slot and slot:IsValid() then
                local k = slot:GetFullName()
                if caps[k] == nil then caps[k] = { slot = slot, cap = slot.Capacity } end
                slot.Capacity = -1
                for i = 2, #list do
                    local inst = makeItem(list[i], ctx)
                    if inst then slot:AddItem(inst) end
                end
                pcall(function() slot.Location = { X = tonumber(x), Y = tonumber(y) } end)
                pcall(function() slot.bRotated = (r == "1") end)
            else
                stats.failed = stats.failed + 1
            end
        end
    end
    for _, e in pairs(caps) do
        if e.slot:IsValid() then e.slot.Capacity = e.cap end
    end
end

local function applyTemplate(a, spec, ctx)
    -- remove the client's own random parts, then attach the host's parts
    for _, p in ipairs(templateParts(a)) do p:K2_DestroyActor() end
    if spec == "" then return end
    for _, ps in ipairs(splitTop(spec, "~")) do
        local socket, cls, item, mesh = ps:match("^([^=]*)=([^@]*)@(.*)@([^@]*)$")
        local partClass = find(cls)
        local inst = makeItem(item, ctx)
        local archPath = item:match("^([^{]*)")
        if partClass and inst then
            local ok, err = pcall(function()
                a:AttachTemplatePart(FName(socket), { Archetype = find(archPath), ArchetypeOverride = nil, PartClass = partClass, Mesh = find(mesh) }, inst)
            end)
            if ok then stats.parts = stats.parts + 1 else stats.failed = stats.failed + 1 stats.err = tostring(err) end
        else
            stats.failed = stats.failed + 1
        end
    end
    -- (a part attached this way is never set up to break - CanBeBreaking false: statesync's wreck parts sweep sets it)
    -- Sub-containers of attached items (trunk contents) are (re)initialized by the part after it is
    -- attached, so they are filled in a later pass: flushPending(), called a few seconds later.
    for _, ps in ipairs(splitTop(spec, "~")) do
        local socket, cls, item = ps:match("^([^=]*)=([^@]*)@(.*)@([^@]*)$")
        local subs = item:match("^[^{]*(.*)$")
        if subs ~= "" then CoopSyncLootPending[#CoopSyncLootPending + 1] = { path = refOf(a), socket = socket, subs = subs } end
    end
end

-- flushPending as a job step (native only; see fillStep): the maps in the first call, then the pending entries a
-- slice at a time, then the sub-containers' own contents. cur.filled: how many containers were filled. true = done.
function M.flushStep(cur, over)
    if not N then cur.filled = M.flushPending() return true end
    if not cur.list then
        cur.list, cur.i, cur.filled = CoopSyncLootPending or {}, 1, 0
        CoopSyncLootPending = {}
        if #cur.list == 0 then M.flushStates() return true end
        cur.parts = byKey(CoopNative_ParentMap("LootableTemplatePart"))
        cur.by = byKey(CoopNative_OuterMap("ItemContainer", ""))
        return false
    end
    local ctx = FindFirstOf("PlayerController")
    while cur.i <= #cur.list do
        local e = cur.list[cur.i]
        cur.i = cur.i + 1
        local actor = derefOf(e.path)
        if actor then
            for _, pp in ipairs(cur.parts[actor:GetFullName()] or {}) do
                local p = derefOf(pp)
                if p and p.MySocket:ToString() == e.socket and p.ItemInstance:IsValid() then
                    local owned = cur.by[p.ItemInstance:GetFullName()] or {}
                    for i, cs in ipairs(splitTop(e.subs:sub(2, -2), "^")) do
                        local c = owned[i] and derefOf(owned[i])
                        if c then fillContainer(c, cs, ctx) cur.filled = cur.filled + 1 end
                    end
                end
            end
        end
        if over() then return false end
    end
    if not cur.states then cur.states = true M.flushStates() end -- (trunk states: the new parts are attached by now)
    cur.fill = cur.fill or {}
    return M.fillStep(cur.fill, over)
end

-- Fills the sub-containers recorded by apply(). Returns how many containers were filled.
function M.flushPending()
    local ctx = FindFirstOf("PlayerController")
    local filled = 0
    if #(CoopSyncLootPending or {}) == 0 then M.flushStates() return 0 end
    buildParts()
    local by = containersByOuter()
    for _, e in ipairs(CoopSyncLootPending or {}) do
        local actor = derefOf(e.path)
        if actor then
            for _, p in ipairs(templateParts(actor)) do
                if p.MySocket:ToString() == e.socket and p.ItemInstance:IsValid() then
                    local owned = by[p.ItemInstance:GetFullName()] or {}
                    for i, cs in ipairs(splitTop(e.subs:sub(2, -2), "^")) do
                        if owned[i] then fillContainer(owned[i], cs, ctx) filled = filled + 1 end
                    end
                end
            end
        end
    end
    partsByParent = nil
    CoopSyncLootPending = {}
    M.fillDeferred()
    M.flushStates()
    return filled
end

-- Applies a loot string to a client actor.
local applyOne
function M.apply(a, loot)
    applyOne(a, loot)
    if batch == 0 then M.fillDeferred() end
end
applyOne = function(a, loot)
    local ctx = FindFirstOf("PlayerController")
    local kind, spec = loot:match("^(%u)|(.*)$")
    if kind == "C" then
        local isOpen = spec:sub(-2) == "#O"
        if isOpen then spec = spec:sub(1, -3) end
        local c = lootableContainer(a)
        if c then fillContainer(c, spec, ctx) stats.containers = stats.containers + 1 else stats.failed = stats.failed + 1 end
        -- the host owns the on-open roll: never let this copy roll by itself
        pcall(function() a.RolledOnOpenItems = true end)
        if isOpen and not opened(a) then
            pcall(function() a.DataBlock_WasOpened = true end)
            pcall(function() a:SwitchToOpenedVisuals() end)
            pcall(function() a:UpdateInteractionOpened() end)
        end
    elseif kind == "W" then
        -- world items are spawned with their item by spawnItem(); nothing to change in place
        stats.items = stats.items
    elseif kind == "T" then
        local body, states = M.splitStates("T|" .. spec)
        applyTemplate(a, body:sub(3), ctx)
        if next(states) then CoopSyncTrunkPending[#CoopSyncTrunkPending + 1] = { path = refOf(a), states = states } end
        stats.templates = stats.templates + 1
    elseif kind == "R" then
        if spec == "1" and M.markGrabbed(a) then stats.grabbed = (stats.grabbed or 0) + 1 end
    end
end
-- The trunk states of templates applied since the last call (their parts may be new: one parts map, fresh)
CoopSyncTrunkPending = CoopSyncTrunkPending or {}
function M.flushStates()
    if #CoopSyncTrunkPending == 0 then return 0 end
    local list = CoopSyncTrunkPending
    CoopSyncTrunkPending = {}
    local keep = partsByParent
    buildParts()
    local n = 0
    for _, e in ipairs(list) do
        local a = derefOf(e.path)
        if a then n = n + M.applyStates(a, e.states) end
    end
    partsByParent = keep
    if stats then stats.trunkStates = (stats.trunkStates or 0) + n end
    return n
end

-- Like apply(), but for templates only touches the sockets that differ (used for live updates).
function M.applyDiff(a, loot)
    local kind = loot:match("^(%u)|")
    if kind ~= "T" then return M.apply(a, loot) end
    local body, states = M.splitStates(loot)
    local spec = body:sub(3)
    if next(states) then CoopSyncTrunkPending[#CoopSyncTrunkPending + 1] = { path = refOf(a), states = states } end
    local ctx = FindFirstOf("PlayerController")
    local want = {}
    for _, ps in ipairs(spec == "" and {} or splitTop(spec, "~")) do
        local socket = ps:match("^([^=]*)=")
        if socket then want[socket] = ps end
    end
    if not ownedBy then buildOwners() end
    local have = {}
    for _, p in ipairs(templateParts(a)) do
        local socket = p.MySocket:ToString()
        local mesh = ""
        pcall(function() mesh = path(p.RequestedMesh) end)
        local cur = string.format("%s=%s@%s@%s", socket, path(p:GetClass()), serItem(p.ItemInstance), mesh)
        local w = want[socket]
        local sameBase = w and (cur:gsub("{.*}", "") == w:gsub("{.*}", ""))
        if not w or not sameBase then
            p:K2_DestroyActor()
        else
            have[socket] = true
            if cur ~= w then
                -- same part, different sub-container contents (e.g. trunk emptied): refill later
                CoopSyncLootPending[#CoopSyncLootPending + 1] = { path = refOf(a), socket = socket, subs = w:match("^[^@]*@[^{@]*(%b{})") or "{}" }
            end
        end
    end
    local missingSpec = {}
    for socket, ps in pairs(want) do if not have[socket] then missingSpec[#missingSpec + 1] = ps end end
    if #missingSpec > 0 then
        -- attach only the missing parts: reuse applyTemplate's attach loop on a reduced spec
        local keep = templateParts
        templateParts = function() return {} end -- applyTemplate must not destroy the parts we kept
        local ok, e = pcall(applyTemplate, a, table.concat(missingSpec, "~"), ctx)
        templateParts = keep
        if not ok then stats.failed = stats.failed + 1 stats.err = tostring(e) end
    end
    if batch == 0 then M.fillDeferred() end
    stats.templates = stats.templates + 1
end

-- A new item instance from an item spec (archetype [+ {sub-containers}]: what the other player put somewhere).
function M.newItem(spec)
    if not stats then M.resetStats() end
    local inst = makeItem(spec, FindFirstOf("PlayerController"))
    if inst and batch == 0 then M.fillDeferred() end
    return inst
end

-- One container as the loot strings write it (<layout>!slot;...), its items' own contents included (car storages:
-- carstore.lua). Native: the containers owned by its items only (no owner map of the whole zone every second).
function M.serContainer(c)
    local keep = ownedBy
    if N then
        local keys = {}
        for si = 1, c.Slots:GetArrayNum() do
            local s = c.Slots[si]
            if s and s:IsValid() then
                for ii = 1, s.Items:GetArrayNum() do
                    local it = s.Items[ii]
                    if it and it:IsValid() then keys[#keys + 1] = it:GetFullName() end
                end
            end
        end
        ownedBy = #keys > 0 and byKey(CoopNative_OuterMap("ItemContainer", table.concat(keys, "\n"))) or {}
    else
        buildOwners()
    end
    local ok, s = pcall(serContainer, c)
    ownedBy = keep
    if not ok then error(s) end
    return s
end
-- Fills a container from such a string (its old items leave it).
function M.fillContainer(c, spec)
    if not stats then M.resetStats() end
    fillContainer(c, spec, FindFirstOf("PlayerController"))
    if batch == 0 then M.fillDeferred() end
end
-- the containers owned by these objects (full names) -> { [full name] = { container, ... } }
M.containersByOuter = function(keys) return containersByOuter(keys) end
function M.inPass() return partsByParent ~= nil end
-- A wreck's part's i-th sub-container (its trunk: the order the loot strings write them, serItem / flushStep), or nil.
function M.subContainer(t, socket, i)
    for _, p in ipairs(templateParts(t)) do
        if p.MySocket:ToString() == socket then
            local inst = p.ItemInstance
            if not (inst and inst:IsValid()) then return nil end
            local k = inst:GetFullName()
            local list = containersByOuter({ k })[k] or {}
            local c = list[tonumber(i) or 0]
            return c and alive(c) and c or nil
        end
    end
    return nil
end
-- The sub-containers of one template part's loot string ("socket=class@arch{c^c}@mesh"): { "<layout>!<slots>", ... }
function M.partSubs(ps)
    local item = (ps or ""):match("^[^=]*=[^@]*@(.*)@[^@]*$") or ""
    local body = item:match("^[^{]*(%b{})$")
    if not body or body == "{}" then return {} end
    return splitTop(body:sub(2, -2), "^")
end
M.splitTop = function(s, sep) return splitTop(s, sep) end
M.find = function(p) return find(p) end

-- Removes a world item the way the game does (item instance removed together with its actors).
-- K2_DestroyActor on these pooled actors parked them at 0,0,0 with their item still set.
function M.removeWorldItem(a)
    local ok, inst = pcall(function() return a.Instance end)
    if ok and alive(inst) then
        local ok2 = pcall(function() inst:Remove(true) end)
        if ok2 then return true end
    end
    a:K2_DestroyActor()
    return false
end

-- UInventorySystem owns SpawnItemActor; the game instance keeps the live one.
function M.inventorySystem() return FindFirstOf("DrivingGameInstance").InventorySystem end

-- Spawns a world item actor carrying the item described by a "W|<item>" loot string.
function M.spawnWorldItem(loot, xf)
    local spec = loot:match("^W|(.*)$") or ""
    local archPath = spec:match("^([^{]*)")
    local arch = find(archPath)
    if not arch then return nil end
    -- 0 = EItemActorContext::World. Known gap: sub-containers of the item (if any) are not rebuilt.
    return M.inventorySystem():SpawnItemActor(FindFirstOf("PlayerController"), xf, arch, 0, 4)
end

-- The import over the host's exact zone (2026-11-12): most actors already hold the host's contents (the same zone
-- save). same(a, loot): the actor serializes to exactly the host's loot -> nothing to apply (a container still gets
-- RolledOnOpenItems: the host owns the on-open roll). freshOwners() before a run of them (the map is per pass).
function M.freshOwners() buildOwners() end
function M.same(a, loot)
    local ok, s = pcall(M.serialize, a)
    if not ok or s ~= loot then return false end
    if loot:sub(1, 2) == "C|" then pcall(function() a.RolledOnOpenItems = true end) end
    stats.same = (stats.same or 0) + 1
    return true
end
function M.resetStats()
    stats = { containers = 0, templates = 0, parts = 0, items = 0, failed = 0, missing = {} }
    CoopSyncLootPending = {}
end
function M.stats()
    local miss = {}
    for k in pairs(stats.missing) do miss[#miss + 1] = k end
    return string.format("same=%d containers=%d templates=%d parts=%d items=%d failed=%d fuel=%d/%d %s %s",
        stats.same or 0, stats.containers, stats.templates, stats.parts, stats.items, stats.failed, stats.fuelSet or 0, stats.fuelFailed or 0,
        table.concat(miss, " "), stats.err or "")
end

return M








