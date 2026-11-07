-- How long a lookup of a path that does not exist takes (StaticFindObject from Lua, the native RefPath), against a hit;
-- and whether the native lookup (engine hash tables only) finds every object StaticFindObject finds: all actors,
-- item containers and the car's components.
local car = FindFirstOf("BP_CarManager_C").NewCarActor
local hit = car:GetFullName():gsub("^%S+ ", "")
local miss = hit .. "_gone"
local function ms(f) local t0 = os.clock() for _ = 1, 20 do f() end return (os.clock() - t0) * 1000 / 20 end
local out = { string.format("hit lua %.2f ms native %.3f ms | miss lua %.2f ms native %.3f ms",
    ms(function() StaticFindObject(hit) end), ms(function() CoopNative_RefPath(hit) end),
    ms(function() StaticFindObject(miss) end), ms(function() CoopNative_RefPath(miss) end)) }
local function check(label, list)
    local n, bad, ex = 0, 0, ""
    for _, o in ipairs(list) do
        if o:IsValid() then
            local p = o:GetFullName():gsub("^%S+ ", "")
            local a = StaticFindObject(p)
            if a and a:IsValid() then
                n = n + 1
                if not CoopNative_RefPath(p) then
                    bad = bad + 1
                    local dead = EInternalObjectFlags and a:HasAnyInternalFlags(EInternalObjectFlags.Unreachable | EInternalObjectFlags.PendingKill)
                    if dead then out.dead = (out.dead or 0) + 1 elseif #ex < 300 then ex = ex .. " " .. p end
                end
            end
        end
    end
    out[#out + 1] = string.format("%s: %d found by StaticFindObject, native missed %d %s", label, n, bad, ex)
end
check("actors", FindAllOf("Actor") or {})
check("item containers", FindAllOf("ItemContainer") or {})
check("item instances", FindAllOf("ItemInstance") or {})
local comps = {}
for _, c in ipairs(car:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.ActorComponent"))) do comps[#comps + 1] = c:get() end
check("car components", comps)
return table.concat(out, "\n")
