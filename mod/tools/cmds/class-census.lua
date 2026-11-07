-- Where the actors of some classes are (CENSUS_CLASSES = comma separated class names): in the world, parked in the
-- actor pool (at the origin / no item instance), pending kill, or outside the persistent level.
local out = {}
for cls in (CENSUS_CLASSES or "BP_Destruct_Box_02_C"):gmatch("[^,]+") do
    local all, alive, parked, levelOther, dead = 0, 0, 0, 0, 0
    for _, a in ipairs(FindAllOf(cls) or {}) do
        all = all + 1
        if not CoopSyncUsable(a) then dead = dead + 1
        else
            local p = a:GetFullName()
            if not p:find(":PersistentLevel.", 1, true) then levelOther = levelOther + 1
            elseif CoopSync.inPool(a) then parked = parked + 1
            else alive = alive + 1 end
        end
    end
    out[#out + 1] = string.format("%s all=%d world=%d parked=%d not_in_level=%d dead=%d", cls, all, alive, parked, levelOther, dead)
end
return table.concat(out, " | ")
