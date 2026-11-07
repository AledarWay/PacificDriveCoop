-- Who removes the zone's placed variants: hooks on the leaf spawner's destroy paths, written to <LEAF_DIR>/leaf.log
-- (target class, path, the calling leaf spawner); installed in the garage before the travel.
local LOG = LEAF_DIR .. "/leaf.log"
local function log(s) local f = io.open(LOG, "ab") f:write(s .. "\n") f:close() end
LEAF_PROBE = LEAF_PROBE or {}
if LEAF_PROBE.done then return "already" end
LEAF_PROBE.done = true
pcall(function() LoadAsset("/Game/Gameplay/Utility/LeafSpawner/BP_LeafSpawner") end)
local LS = "/Game/Gameplay/Utility/LeafSpawner/BP_LeafSpawner.BP_LeafSpawner_C:"
local function path(o) local ok, s = pcall(function() return o:GetFullName():gsub("^%S+ ", "") end) return ok and s or "?" end
local hooks = {}
local function hook(fn, cb) local ok, e = pcall(RegisterHook, fn, cb) hooks[#hooks + 1] = fn:match(":(.*)$") .. "=" .. tostring(ok) end
hook(LS .. "DestroyActor", function(self, target)
    local ok, t = pcall(function() return target:get() end)
    log("DestroyActor by " .. path(self:get()) .. " -> " .. (ok and t and t:IsValid() and (t:GetClass():GetFName():ToString() .. " " .. path(t)) or "nil"))
end)
hook(LS .. "DeleteInactiveChildren", function(self) log("DeleteInactiveChildren " .. path(self:get())) end)
hook(LS .. "EvaluateLeaf", function(self) log("EvaluateLeaf " .. path(self:get())) end)
hook("/Script/PrefabAsset.PrefabActor:DestroyPrefabActor", function(self) log("DestroyPrefabActor " .. path(self:get())) end)
return "leaf hooks: " .. table.concat(hooks, " ")
