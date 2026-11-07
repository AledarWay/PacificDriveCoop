-- The C++ probe (CoopNative) against the same work in Lua, in a zone:
--   1. the actors whose class name contains "Lootable": FindAllOf("Actor") + class names in Lua / ForEachUObject in C++
--   2. what hangs under the own car: carghost.descendants' world walk (by address) in Lua / the same walk in C++
--   3. a weak reference to an actor that is destroyed and garbage collected: valid before, invalid after, no crash
local out = {}
if not CoopNative_Version then return "CoopNative not loaded (no CoopNative_Version)" end
out[#out + 1] = CoopNative_Version()

local function clsName(a) return a:GetClass():GetFName():ToString() end
local t0 = os.clock()
local n = 0
for _, a in ipairs(FindAllOf("Actor") or {}) do
    if a:IsValid() and clsName(a):find("Lootable", 1, true) then n = n + 1 end
end
local luaMs = (os.clock() - t0) * 1000
local cn, cms = CoopNative_ScanActors("Lootable")
out[#out + 1] = string.format("1. Lootable actors: Lua %d in %.1f ms | C++ %d in %.1f ms (x%.0f)", n, luaMs, cn, cms, luaMs / math.max(cms, 0.01))

local car = FindFirstOf("BP_CarManager_C").NewCarActor
local function parentOf(a)
    local ok, p = pcall(function() return a:GetAttachParentActor() end)
    if ok and p and p:IsValid() then return p end
end
t0 = os.clock()
local r, d = car:GetAddress(), 0
for _, a in ipairs(FindAllOf("Actor") or {}) do
    if a:IsValid() then
        local cur, g = parentOf(a), 0
        while cur and g < 8 do
            if cur:GetAddress() == r then d = d + 1 break end
            cur = parentOf(cur)
            g = g + 1
        end
    end
end
luaMs = (os.clock() - t0) * 1000
local dn, dms = CoopNative_AttachedUnder(car:GetAddress())
out[#out + 1] = string.format("2. under the car: Lua %d in %.1f ms | C++ %d in %.1f ms (x%.0f)", d, luaMs, dn, dms, luaMs / math.max(dms, 0.01))

-- 3. weak reference: a plain actor spawned for it
local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
local xf = { Translation = car:K2_GetActorLocation(), Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
local a = GS:BeginDeferredActorSpawnFromClass(FindFirstOf("PlayerController"), StaticFindObject("/Script/Engine.StaticMeshActor"), xf, 1, nil)
a = GS:FinishSpawningActor(a, xf)
local h = CoopNative_WeakNew(a:GetAddress())
local v1 = CoopNative_WeakValid(h)
a:K2_DestroyActor()
a = nil
StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):CollectGarbage()
local v2 = CoopNative_WeakValid(h)
out[#out + 1] = string.format("3. weak ref: alive before %s, after destroy + GC %s", tostring(v1), tostring(v2))
return table.concat(out, "\n")
