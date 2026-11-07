-- The state of an openable world thing (a wreck's locked trunk part, a container door): its class's functions and its
-- simple properties' values (bool / int / float / byte only: other reads may raise in UE4SS, which breaks Lua).
--   OP_CLASS = class name (e.g. "BP_TemplatePart_Trunk_Locked_C"), OP_NEAR = true: the one nearest to the player
--   OP_FUNCS = true: list the functions too
local cls = OP_CLASS or "BP_TemplatePart_Trunk_Locked_C"
local pawn = FindFirstOf("PlayerController").Pawn
local me = pawn:K2_GetActorLocation()
local best, bd
for _, a in ipairs(FindAllOf(cls) or {}) do
    if a:IsValid() and a:GetFullName():find(":PersistentLevel.", 1, true) then
        local l = a:K2_GetActorLocation()
        local d = (l.X - me.X) ^ 2 + (l.Y - me.Y) ^ 2 + (l.Z - me.Z) ^ 2
        if not bd or d < bd then best, bd = a, d end
    end
end
if not best then return "no " .. cls end
local o = { string.format("%s at %.0f m: %s", cls, math.sqrt(bd) / 100, best:GetFullName():gsub("^%S+ ", "")) }
local SIMPLE = { BoolProperty = true, IntProperty = true, FloatProperty = true, ByteProperty = true }
local c = best:GetClass()
local depth = 0
while c and c:IsValid() and depth < 3 do
    local props = {}
    c:ForEachProperty(function(p)
        local kind = p:GetClass():GetFName():ToString()
        local n = p:GetFName():ToString()
        if SIMPLE[kind] then
            local ok, v = pcall(function() return best[n] end)
            props[#props + 1] = n .. "=" .. (ok and tostring(v) or "?")
        else
            props[#props + 1] = n .. ":" .. kind
        end
    end)
    o[#o + 1] = c:GetFName():ToString() .. " props: " .. table.concat(props, ", ")
    if OP_FUNCS then
        local fns = {}
        c:ForEachFunction(function(f) fns[#fns + 1] = f:GetFName():ToString() end)
        o[#o + 1] = c:GetFName():ToString() .. " funcs: " .. table.concat(fns, ", ")
    end
    c = c:GetSuperStruct()
    depth = depth + 1
end
OP_LAST = best
return table.concat(o, "\n")
