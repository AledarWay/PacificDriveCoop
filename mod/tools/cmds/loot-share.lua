-- Helpers for loot-share-test.ps1. Globals in: LS_OP and its arguments; CoopSync / CoopSyncState loaded.
--   pickable            (client) a mapped world item both sides have: "<host key>\t<archetype path>"
--   takeable            (client) a mapped container holding exactly one item of some archetype: "<key>\t<arch>"
--   pick LS_KEY LS_ROLE pick the world item up like a player (give to inventory, remove from the world)
--   take LS_KEY LS_ROLE LS_ARCH  take one item of LS_ARCH out of that container into the inventory
--   count LS_ARCH       how many of that archetype the local player carries
--   drop LS_ARCH        put one carried item of that archetype on the ground 1.5 m in front of the player
--   near LS_ARCH LS_X LS_Y LS_Z  path of a world item of that archetype within 400 units, or "none"
--   exists LS_KEY LS_ROLE  is that world item still in this world
--   incount LS_KEY LS_ROLE LS_ARCH  how many of LS_ARCH that container holds
--   put LS_KEY LS_ROLE LS_ARCH  one carried item of LS_ARCH into that container (the same instance, like the game)
--   give LS_ARCH        one item of that archetype into the inventory
--   dropfuel LS_ARCH LS_FUEL [LS_DX]  a fuel canister on the ground with that much fuel (a carried one leaves the inventory)
--   fuelnear / setfuelnear LS_ARCH LS_X LS_Y LS_Z [LS_FUEL]  the fuel of the canister there (set first: setfuelnear)
local Loot = CoopSync.Loot
local IM = FindFirstOf("BP_InventoryManager_C")
local function objPath(o) return (o:GetFullName():gsub("^%S+%s+", "")) end
local function actorOf(key)
    if LS_ROLE == "client" then return CoopSync.deref(CoopSyncMap[key]) end
    return CoopSync.deref(key)
end
local function carried(archPath)
    local n = 0
    for _, f in ipairs({ "Inventory_Player", "Inventory_PlayerHand" }) do
        pcall(function()
            local c = IM[f]
            for i = 1, c.Slots:GetArrayNum() do
                local s = c.Slots[i]
                for j = 1, s.Items:GetArrayNum() do if objPath(s.Items[j].Archetype) == archPath then n = n + 1 end end
            end
        end)
    end
    return n
end
local op = LS_OP
-- a wreck's trunk: LS_SUB = "<socket>#<n>" (statesync's sub-container address)
local function subOf(a)
    local socket, n = (LS_SUB or ""):match("^(.*)#(%d+)$")
    return socket and Loot.subContainer(a, socket, n) or nil
end
local function countIn(c, arch)
    local n = 0
    for i = 1, c.Slots:GetArrayNum() do
        local s = c.Slots[i]
        for j = 1, s.Items:GetArrayNum() do if objPath(s.Items[j].Archetype) == arch then n = n + 1 end end
    end
    return n
end
-- world doors (statesync DS): by place, "x,y,z" in 10-unit cells
local function doors()
    local out = {}
    for _, cn in ipairs({ "BP_Door_Single_C", "BP_Door_Sliding_Single_C" }) do
        for _, d in ipairs(FindAllOf(cn) or {}) do
            if d:IsValid() and d:GetFullName():find(":PersistentLevel.", 1, true) then
                local l = d:K2_GetActorLocation()
                out[#out + 1] = { d = d, key = string.format("%d,%d,%d", math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5), math.floor(l.Z / 10 + 0.5)), state = d.CurrentState }
            end
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end
local function doorNear(key)
    local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
    for _, e in ipairs(doors()) do
        local l = e.d:K2_GetActorLocation()
        if (l.X - x * 10) ^ 2 + (l.Y - y * 10) ^ 2 + (l.Z - z * 10) ^ 2 < 60 ^ 2 then return e end
    end
end
if op == "shutdoor" then
    -- the LS_N-th door that is shut here (state 0): its place
    local n = 0
    for _, e in ipairs(doors()) do if e.state == 0 then n = n + 1 if n == (LS_N or 1) then return e.key end end end
    return "none"
elseif op == "doorstate" then
    local e = doorNear(LS_KEY)
    return e and tostring(e.state) or "-1"
elseif op == "setdoor" then
    local e = doorNear(LS_KEY)
    if not e then return "no door" end
    e.d["Set Door from State"](e.d, LS_STATE)
    return "door " .. LS_KEY .. " -> " .. tostring(e.d.CurrentState)
elseif op == "lockedtrunk" then
    -- (client) mapped wrecks with a locked trunk (TrunkState 0): "<key>\t<socket>" of the LS_N-th (default 1)
    local keys = {}
    for k in pairs(CoopSyncMap) do keys[#keys + 1] = k end
    table.sort(keys)
    Loot.beginPass()
    local seen, found = 0, nil
    for _, k in ipairs(keys) do
        local a = CoopSync.deref(CoopSyncMap[k])
        if a and Loot.templatePartCount(a) > 0 then
            for socket, s in pairs(Loot.statesOf(a)) do
                if s == 0 and not found then
                    seen = seen + 1
                    if seen == (LS_N or 1) then found = k .. "\t" .. socket end
                end
            end
        end
        if found then break end
    end
    Loot.endPass()
    return found or "none"
elseif op == "trunkstate" or op == "opentrunk" then
    local a = actorOf(LS_KEY)
    if not a then return "gone" end
    if op == "opentrunk" then
        -- (what prying it open ends in: the trunk part's open state)
        for _, p in ipairs(Loot.templateParts(a)) do if p.MySocket:ToString() == LS_SUB then Loot.openTrunk(p) end end
    end
    return tostring(Loot.statesOf(a)[LS_SUB])
elseif op == "trunkable" then
    -- (client) a mapped wreck whose part holds a sub-container with an item of some archetype exactly once:
    -- "<key>\t<socket>#<n>\t<arch>"
    local keys = {}
    for k in pairs(CoopSyncMap) do keys[#keys + 1] = k end
    table.sort(keys)
    Loot.beginPass()
    local found
    for _, k in ipairs(keys) do
        local a = CoopSync.deref(CoopSyncMap[k])
        local loot = a and Loot.serialize(a) or ""
        if loot:sub(1, 2) == "T|" and loot:find("{", 1, true) then
            for _, ps in ipairs(Loot.splitTop(loot:sub(3), "~")) do
                local socket = ps:match("^([^=]*)=")
                for i, cs in ipairs(Loot.partSubs(ps)) do
                    local counts = {}
                    for _, sl in ipairs(Loot.splitTop((cs:match("^[^!]*!(.*)$") or ""), ";")) do
                        for _, it in ipairs(Loot.splitTop(sl:match("^[^=]*=(.*)$") or "", ",")) do
                            local arch = it:match("^([^{]*)")
                            if arch ~= "" then counts[arch] = (counts[arch] or 0) + 1 end
                        end
                    end
                    for arch, n in pairs(counts) do if n == 1 then found = k .. "\t" .. socket .. "#" .. i .. "\t" .. arch break end end
                    if found then break end
                end
                if found then break end
            end
        end
        if found then break end
    end
    Loot.endPass()
    return found or "none"
elseif op == "subcount" then
    local a = actorOf(LS_KEY)
    local c = a and subOf(a)
    return c and tostring(countIn(c, LS_ARCH)) or "-1"
elseif op == "subtake" then
    local a = actorOf(LS_KEY)
    local c = a and subOf(a)
    if not c then return "no trunk" end
    local arch = Loot.find(LS_ARCH)
    local inst = c:FindItemOfType(arch)
    if not (inst and inst:IsValid()) then return "none left" end
    c:RemoveItem(inst)
    IM:GiveItemToPlayer(arch)
    return "took " .. arch:GetFName():ToString()
elseif op == "subput" then
    local a = actorOf(LS_KEY)
    local c = a and subOf(a)
    if not c then return "no trunk" end
    local arch = Loot.find(LS_ARCH)
    for _, f in ipairs({ "Inventory_Player", "Inventory_PlayerHand" }) do
        local inv = IM[f]
        local inst = inv:FindItemOfType(arch)
        if inst and inst:IsValid() then
            inv:RemoveItem(inst)
            c:AddItem(inst, true)
            return "put " .. arch:GetFName():ToString()
        end
    end
    return "not carried"
elseif op == "pickable" or op == "takeable" then
    local keys = {}
    for k in pairs(CoopSyncMap) do keys[#keys + 1] = k end
    table.sort(keys)
    Loot.beginPass()
    local found
    for _, k in ipairs(keys) do
        local a = CoopSync.deref(CoopSyncMap[k])
        if a and not CoopSync.inPool(a) then
            if op == "pickable" and Loot.isItemActor(a) then
                local arch = (Loot.serialize(a) or ""):match("^W|([^{]*)")
                if arch and arch ~= "" then found = k .. "\t" .. arch break end
            elseif op == "takeable" then
                local ok, c = pcall(function() return a.InventoryContainer end)
                if ok and c and c:IsValid() and c.Slots:GetArrayNum() > 0 then
                    local counts, firstArch = {}, nil
                    for i = 1, c.Slots:GetArrayNum() do
                        local s = c.Slots[i]
                        for j = 1, s.Items:GetArrayNum() do
                            local p = objPath(s.Items[j].Archetype)
                            counts[p] = (counts[p] or 0) + 1
                            firstArch = firstArch or p
                        end
                    end
                    for p, n in pairs(counts) do if n == 1 then found = k .. "\t" .. p break end end
                    if found then break end
                end
            end
        end
    end
    Loot.endPass()
    return found or "none"
elseif op == "pick" then
    local a = actorOf(LS_KEY)
    if not a then return "gone" end
    local arch = a.Instance.Archetype
    IM:GiveItemToPlayer(arch)
    Loot.removeWorldItem(a)
    return "picked " .. arch:GetFName():ToString()
elseif op == "take" then
    local a = actorOf(LS_KEY)
    if not a then return "gone" end
    local arch = Loot.find(LS_ARCH)
    local c = a.InventoryContainer
    local inst = c:FindItemOfType(arch)
    if not (inst and inst:IsValid()) then return "none left" end
    c:RemoveItem(inst)
    IM:GiveItemToPlayer(arch)
    return "took " .. arch:GetFName():ToString()
elseif op == "count" then
    return tostring(carried(LS_ARCH))
elseif op == "drop" then
    local arch = Loot.find(LS_ARCH)
    local removed = 0
    for _, f in ipairs({ "Inventory_Player", "Inventory_PlayerHand" }) do
        if removed == 0 then pcall(function() IM[f]:RemoveItemsOfType(arch, 1) removed = 1 end) end
    end
    local pawn = FindFirstOf("PlayerController").Pawn
    local l, fwd = pawn:K2_GetActorLocation(), pawn:GetActorForwardVector()
    local at = { X = l.X + fwd.X * 150, Y = l.Y + fwd.Y * 150, Z = l.Z }
    local xf = { Translation = at, Rotation = CoopSync.quat(0, 0, 0), Scale3D = { X = 1, Y = 1, Z = 1 } }
    local w = Loot.spawnWorldItem("W|" .. LS_ARCH, xf)
    return string.format("dropped at %.0f,%.0f,%.0f (%s)", at.X, at.Y, at.Z, w and w:IsValid() and "item on the ground" or "spawn failed")
elseif op == "give" then
    IM:GiveItemToPlayer(Loot.find(LS_ARCH))
    return tostring(carried(LS_ARCH))
elseif op == "dropfuel" then
    -- a fuel canister put down with LS_FUEL in it (a carried one is taken from the inventory, as a drop does): what the
    -- game's drop makes of the item - a world item whose component has the item's fuel
    local arch = Loot.find(LS_ARCH)
    local was = carried(LS_ARCH)
    for _, f in ipairs({ "Inventory_Player", "Inventory_PlayerHand" }) do
        if carried(LS_ARCH) == was then pcall(function() IM[f]:RemoveItemsOfType(arch, 1) end) end
    end
    local pawn = FindFirstOf("PlayerController").Pawn
    local l, fwd = pawn:K2_GetActorLocation(), pawn:GetActorForwardVector()
    local at = { X = l.X + fwd.X * 150 + (LS_DX or 0), Y = l.Y + fwd.Y * 150, Z = l.Z }
    local xf = { Translation = at, Rotation = CoopSync.quat(0, 0, 0), Scale3D = { X = 1, Y = 1, Z = 1 } }
    local w = Loot.spawnWorldItem("W|" .. LS_ARCH, xf)
    if not (w and w:IsValid()) then return "spawn failed" end
    local fc = w.BP_FuelableComponent
    fc["Set Fuel"](fc, LS_FUEL)
    return string.format("dropped at %.0f,%.0f,%.0f fuel %s (carried %d -> %d)", at.X, at.Y, at.Z, tostring(CoopSyncFuel.of(w)), was, carried(LS_ARCH))
elseif op == "fuelnear" or op == "setfuelnear" then
    -- the fuel of the world item of LS_ARCH nearest to LS_X/Y/Z within 400 units ("none"); setfuelnear sets LS_FUEL first
    local at = { X = tonumber(LS_X), Y = tonumber(LS_Y), Z = tonumber(LS_Z) }
    local best, bd
    for _, a in ipairs(FindAllOf("BP_WorldItem_Fuelable_C") or {}) do
        if a:IsValid() and not CoopSync.inPool(a) and objPath(a.Instance.Archetype) == LS_ARCH then
            local l = a:K2_GetActorLocation()
            local d = (l.X - at.X) ^ 2 + (l.Y - at.Y) ^ 2 + (l.Z - at.Z) ^ 2
            if d < 400 ^ 2 and (not bd or d < bd) then best, bd = a, d end
        end
    end
    if not best then return "none" end
    if op == "setfuelnear" then local fc = best.BP_FuelableComponent fc["Set Fuel"](fc, LS_FUEL) end
    return tostring(CoopSyncFuel.of(best))
elseif op == "near" then
    local at = { X = tonumber(LS_X), Y = tonumber(LS_Y), Z = tonumber(LS_Z) }
    Loot.beginPass()
    local best
    for _, a in ipairs(CoopSync.collect()) do
        if Loot.isItemActor(a) and not CoopSync.inPool(a) then
            local arch = (Loot.serialize(a) or ""):match("^W|([^{]*)")
            local l = a:K2_GetActorLocation()
            if arch == LS_ARCH and (l.X - at.X) ^ 2 + (l.Y - at.Y) ^ 2 + (l.Z - at.Z) ^ 2 < 400 ^ 2 then best = CoopSync.ref(a) end
        end
    end
    Loot.endPass()
    return best or "none"
elseif op == "exists" then
    local a = actorOf(LS_KEY)
    return (a and not CoopSync.inPool(a)) and "yes" or "no"
elseif op == "incount" then
    local a = actorOf(LS_KEY)
    if not a then return "-1" end
    local c = a.InventoryContainer
    local n = 0
    for i = 1, c.Slots:GetArrayNum() do
        local s = c.Slots[i]
        for j = 1, s.Items:GetArrayNum() do if objPath(s.Items[j].Archetype) == LS_ARCH then n = n + 1 end end
    end
    return tostring(n)
elseif op == "put" then
    local a = actorOf(LS_KEY)
    if not a then return "gone" end
    local arch = Loot.find(LS_ARCH)
    for _, f in ipairs({ "Inventory_Player", "Inventory_PlayerHand" }) do
        local inv = IM[f]
        local inst = inv:FindItemOfType(arch)
        if inst and inst:IsValid() then
            inv:RemoveItem(inst)
            a.InventoryContainer:AddItem(inst, true)
            return "put " .. arch:GetFName():ToString()
        end
    end
    return "not carried"
elseif op == "setcarriedfuel" then
    -- the fuel of a carried item of LS_ARCH (the item's own property: what a container gets)
    local arch = Loot.find(LS_ARCH)
    for _, f in ipairs({ "Inventory_Player", "Inventory_PlayerHand" }) do
        local inst = IM[f]:FindItemOfType(arch)
        if inst and inst:IsValid() then
            Loot.setItemFuel(inst, LS_FUEL)
            return tostring(Loot.itemFuel(inst))
        end
    end
    return "not carried"
elseif op == "fuelin" then
    -- the fuel of each LS_ARCH item in that container, sorted ("-" none)
    local a = actorOf(LS_KEY)
    if not a then return "gone" end
    local c = a.InventoryContainer
    local out = {}
    for i = 1, c.Slots:GetArrayNum() do
        local s = c.Slots[i]
        for j = 1, s.Items:GetArrayNum() do
            local it = s.Items[j]
            if objPath(it.Archetype) == LS_ARCH then out[#out + 1] = string.format("%.2f", Loot.itemFuel(it) or -1) end
        end
    end
    table.sort(out)
    return #out > 0 and table.concat(out, ",") or "-"
end
return "unknown LS_OP " .. tostring(op)
