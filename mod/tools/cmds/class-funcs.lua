-- Functions and properties of PROBE_CLASS (default the landmine) and its Blueprint super classes, to find what
-- triggers / explodes / disarms a hazard. Needs one instance in the world (classes load with the zone).
local name = PROBE_CLASS or "BP_Hazard_Landmine_C"
local a = FindFirstOf(name)
if not a then return "no instance of " .. name end
local out = {}
local cls = a:GetClass()
local guard = 0
while cls and cls:IsValid() and guard < 6 do
    local fn, props = {}, {}
    pcall(function() cls:ForEachFunction(function(f) fn[#fn + 1] = f:GetFName():ToString() end) end)
    pcall(function() cls:ForEachProperty(function(p) props[#props + 1] = p:GetFName():ToString() end) end)
    out[#out + 1] = string.format("== %s\n  functions: %s\n  properties: %s", cls:GetFName():ToString(), table.concat(fn, " "), table.concat(props, " "))
    local ok, sup = pcall(function() return cls:GetSuperStruct() end)
    if not ok or not sup or not sup:IsValid() then break end
    if sup:GetFName():ToString():find("^Actor$") then break end
    cls = sup
    guard = guard + 1
end
return table.concat(out, "\n")
