CoopSync = CoopSync or dofile("C:/PacificDriveCoop/mod/CoopSync/Scripts/spawnsync.lua")
local a = CoopSyncOpenTarget
local function flags() return string.format("RolledOnOpen=%s WasOpened=%s Empty=%s", tostring(a.RolledOnOpenItems), tostring(a.DataBlock_WasOpened), tostring(a.Empty)) end
local function short() CoopSync.Loot.beginPass() local s = CoopSync.Loot.serialize(a) return (s:gsub("/Game/[^@,;~{}|=!]-/([^/.@,;~{}|=!]+)%.[^@,;~{}|=!]+", "%1")) end
for _, fn in ipairs({"HighlightInteract", "OnRollForOpenItems", "UpdateInteractionOpened"}) do
  local ok, e = pcall(function() a[fn](a) end)
  Dev.out(fn, ok, tostring(e), flags(), short())
end
return "ok"
