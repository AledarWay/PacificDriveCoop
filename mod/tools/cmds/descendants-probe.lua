-- The actors attached under the own car: the old way (every actor of the world, its parent chain compared by full
-- name) against the component tree (the car's scene components' AttachChildren -> their owners, recursively).
-- Same set? How long each?
local car = FindFirstOf("BP_CarManager_C").NewCarActor
local function parentOf(a)
    local ok, p = pcall(function() return a:GetAttachParentActor() end)
    if ok and p and p:IsValid() then return p end
end
local t0 = os.clock()
local old = {}
local root = car:GetFullName()
for _, a in ipairs(FindAllOf("Actor") or {}) do
    if a:IsValid() then
        local cur, g = parentOf(a), 0
        while cur and g < 8 do
            if cur:GetFullName() == root then old[a:GetAddress()] = a:GetFName():ToString() break end
            cur = parentOf(cur)
            g = g + 1
        end
    end
end
local tOld = (os.clock() - t0) * 1000
t0 = os.clock()
local SC = StaticFindObject("/Script/Engine.SceneComponent")
local function elem(e) local ok, g = pcall(function() return e:get() end) return ok and g or e end
local new, seen, queue, qi = {}, { [car:GetAddress()] = true }, { car }, 1
while qi <= #queue do
    local a = queue[qi]
    qi = qi + 1
    local comps = a:K2_GetComponentsByClass(SC)
    for i = 1, #comps do
        local c = elem(comps[i])
        local kids = c.AttachChildren
        for j = 1, #kids do
            local k = elem(kids[j])
            local ok, o = pcall(function() return k:GetOwner() end)
            if ok and o and o:IsValid() and not seen[o:GetAddress()] then
                seen[o:GetAddress()] = true
                new[o:GetAddress()] = o:GetFName():ToString()
                queue[#queue + 1] = o
            end
        end
    end
end
local tNew = (os.clock() - t0) * 1000
local nOld, nNew, onlyOld, onlyNew = 0, 0, {}, {}
for k, v in pairs(old) do nOld = nOld + 1 if not new[k] then onlyOld[#onlyOld + 1] = v end end
for k, v in pairs(new) do nNew = nNew + 1 if not old[k] then onlyNew[#onlyNew + 1] = v end end
return string.format("old=%d in %.0f ms, tree=%d in %.0f ms; only old: %s; only tree: %s", nOld, tOld, nNew, tNew,
    table.concat(onlyOld, ","):sub(1, 300), table.concat(onlyNew, ","):sub(1, 300))
