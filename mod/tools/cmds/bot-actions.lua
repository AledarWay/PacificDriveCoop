-- Bot interactions with the same end results as a player's actions. Picks targets deterministically
-- from a sorted list, skipping the first SKIP of each kind so host and client can act on different ones.
-- Globals expected: CoopSync (spawnsync), CoopSyncState (statesync). Set BOT_SKIP before running.
local SOCK = (rawget(_G, "CoopSync") and CoopSync.Loot and CoopSync.Loot.sockOf) or function(q) return q.MySocket:ToString() end -- (a reloaded zone's parts: lootsync M.sockOf)
local SKIP = BOT_SKIP or 0
local Loot = CoopSync.Loot
local IM = FindFirstOf("BP_InventoryManager_C")
local out = {}
local ONLY = BOT_ONLY -- nil = all, or "open" / "take" / "pick" / "detach"
local function want(k) return ONLY == nil or ("," .. ONLY .. ","):find("," .. k .. ",", 1, true) ~= nil end
local crumbs = (os.getenv("COOPDEV_DIR") or "C:/PacificDriveCoop/local/coopdev") .. "/bot-crumbs.txt"
local function note(s)
    out[#out + 1] = s
    local f = io.open(crumbs, "ab") if f then f:write(os.date("%H:%M:%S ") .. s .. "\n") f:close() end
end

local lootables, worldItems, templates = {}, {}, {}
for _, a in ipairs(CoopSync.collect()) do
    local c = CoopSync.clsName(a)
    local ok, cont = pcall(function() return a.InventoryContainer end)
    if c:find("^BP_Lootable_") and ok and cont and cont:IsValid() then lootables[#lootables + 1] = a
    elseif Loot.isItemActor(a) then worldItems[#worldItems + 1] = a
    elseif a:IsA(StaticFindObject("/Script/PenDriverPro.LootableTemplate")) then templates[#templates + 1] = a end
end
local function byName(x, y) return x:GetFullName() < y:GetFullName() end
table.sort(lootables, byName) table.sort(worldItems, byName) table.sort(templates, byName)
local function name(a) return a:GetFName():ToString() end

-- 1) open 3 containers that have an on-open roll (as the container UI would: open + roll)
local opened, skipped = 0, 0
for _, a in ipairs(lootables) do
    if want("open") and opened < 3 and not a.DataBlock_WasOpened and a.OnOpenItemsDecisionTree:IsValid() then
        if skipped < SKIP then skipped = skipped + 1 else
            note("about to open " .. name(a))
            a:HighlightInteract()
            a:OnRollForOpenItems()
            opened = opened + 1
            note("open " .. name(a))
        end
    end
end

-- 2) take every item of the first slot out of 2 (other) containers into the player's inventory
local took, skipped2 = 0, 0
for _, a in ipairs(lootables) do
    local c = a.InventoryContainer
    if want("take") and took < 2 and not a.DataBlock_WasOpened and c.Slots:GetArrayNum() > 0 then
        if skipped2 < SKIP then skipped2 = skipped2 + 1 else
            local slot = c.Slots[1]
            local items = {}
            for i = 1, slot.Items:GetArrayNum() do items[#items + 1] = slot.Items[i] end
            note("about to take from " .. name(a))
            for _, inst in ipairs(items) do
                local arch = inst.Archetype
                c:RemoveItem(inst)
                pcall(function() IM:GiveItemToPlayer(arch) end)
            end
            took = took + 1
            note(string.format("take %d from %s", #items, name(a)))
        end
    end
end

-- 3) pick up 2 world items
local picked = 0
for i = 1 + SKIP * 2, #worldItems do
    local a = worldItems[i]
    -- only real items: hazards (landmines, bollards) are item manifestations without an Instance
    local inst = a.Instance
    if want("pick") and picked < 2 and inst and inst:IsValid() then
        pcall(function() IM:GiveItemToPlayer(inst.Archetype) end)
        note("pick " .. name(a))
        Loot.removeWorldItem(a)
        picked = picked + 1
    end
end

-- 4) take a wheel off 2 car wrecks
local detached, skipped4 = 0, 0
for _, t in ipairs(templates) do
    if want("detach") and detached < 2 then
        for _, p in ipairs(Loot.templateParts(t)) do
            if detached < 2 and SOCK(p):find("^Wheel") then
                if skipped4 < SKIP then skipped4 = skipped4 + 1 else
                    note("about to detach " .. p:GetFName():ToString())
                    note("detach " .. SOCK(p) .. " from " .. name(t))
                    CoopSyncState.detachPart(p)
                    detached = detached + 1
                end
                break
            end
        end
    end
end
return table.concat(out, "; ")


