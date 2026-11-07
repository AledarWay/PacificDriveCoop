CoopSync.Loot.beginPass()
local a = CoopSyncOpen2
local now = CoopSync.Loot.serialize(a)
return string.format("changed=%s WasOpened=%s RolledOnOpen=%s", tostring(now ~= CoopSyncOpen2Before), tostring(a.DataBlock_WasOpened), tostring(a.RolledOnOpenItems))
