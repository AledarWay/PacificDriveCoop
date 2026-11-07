-- The functions of a class whose name matches a pattern, with their parameters (name:type).
--   FN_OBJ = an object (else FN_OF = the short class name of a live object (default the player car)), FN_PAT = a Lua pattern (default "[Ll]ight")
local obj = FN_OBJ or FindFirstOf(FN_OF or "BP_PlayerCarNew_C")
local pat = FN_PAT or "[Ll]ight"
FN_OF, FN_PAT, FN_OBJ = nil, nil, nil
if not (obj and obj:IsValid()) then return "no object" end
local cls = obj:GetClass()
local o = {}
cls:ForEachFunction(function(f)
    local n = f:GetFName():ToString()
    if n:find(pat) then
        local ps = {}
        f:ForEachProperty(function(p) ps[#ps + 1] = p:GetFName():ToString() .. ":" .. p:GetClass():GetFName():ToString():gsub("Property", "") end)
        o[#o + 1] = n .. "(" .. table.concat(ps, ",") .. ")"
    end
end)
return #o .. " functions\n" .. table.concat(o, "\n")
