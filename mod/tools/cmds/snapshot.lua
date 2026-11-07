-- Writes every live in-level actor (class, rounded location) to snapshot.txt for run-to-run comparison.
-- Skips actors pending kill (destroyed but not yet garbage collected) and transient archetypes.
local path = "C:/PacificDriveCoop/local/coopdev/snapshot.txt"
local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local Pooled = StaticFindObject("/Script/PenDriverUtils.PooledActor")
local ItemActor = StaticFindObject("/Script/PenDriverInventory.ItemActorManifestation")
-- idle pooled item actor = parked at the origin, hidden, or (not a hazard) without an item Instance (same rule as spawnsync)
local function inPool(a)
    if not (Pooled and a:IsA(Pooled) and ItemActor and a:IsA(ItemActor)) then return false end
    local l = a:K2_GetActorLocation()
    if (math.abs(l.X) < 1 and math.abs(l.Y) < 1 and math.abs(l.Z) < 1) or a.bHidden == true then return true end
    if a:GetClass():GetFName():ToString():find("^BP_Hazard") then return false end
    local inst = a.Instance
    return not (inst and inst:IsValid() and KSL:IsValid(inst))
end
local gi = FindFirstOf("DrivingGameInstance")
-- only the current world's level: after a travel the old map's actors linger (moved to the origin) until GC
local level = gi:GetWorld():GetFullName():gsub("^%S+ ", "") .. ":PersistentLevel."
local f = io.open(path, "wb")
f:write(string.format("# seed=%d state=%d world=%s\n", gi.MasterSeed, gi.CurrentGameplayState, gi:GetWorld():GetFullName()))
local n = 0
for _, a in ipairs(FindAllOf("Actor") or {}) do
    if a:IsValid() and not (EInternalObjectFlags and a:HasAnyInternalFlags(EInternalObjectFlags.Unreachable)) and KSL:IsValid(a) and a:GetFullName():find(level, 1, true) and not inPool(a) then
        -- (a destroyed actor waiting for the GC passes both IsValid checks; it has no root component any more - car-census
        -- rule. Counted, the guest's import removals read as hundreds of "extra" right after the cleanup, 2026-11-05)
        local okR, root = pcall(function() local r = a.RootComponent return r and r:IsValid() and KSL:IsValid(r) end)
        local ok, loc = pcall(function() return a:K2_GetActorLocation() end)
        if ok and loc and okR and root then
            f:write(string.format("%s\t%.0f\t%.0f\t%.0f\n", a:GetClass():GetFName():ToString(), loc.X, loc.Y, loc.Z))
            n = n + 1
        end
    end
end
f:close()
return n

