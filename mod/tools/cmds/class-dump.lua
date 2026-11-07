-- Own-class properties (with values of the first live instance) and functions of the classes named in
-- CLASS_DUMP = { "<short class name>", ... }; CLASS_DUMP_DEPTH = how many classes up the chain (default 1).
local function str(v)
    if type(v) ~= "userdata" then return tostring(v) end
    local ok, s = pcall(function() return v:GetFName():ToString() end) if ok and s then return s end
    ok, s = pcall(function() return "#" .. #v end) if ok then return s end
    return "ud"
end
local out = {}
for _, name in ipairs(CLASS_DUMP or {}) do
    local o
    for _, x in ipairs(FindAllOf(name) or {}) do
        if x:IsValid() and not x:GetFullName():find("Default__", 1, true) then o = x break end
    end
    if not o then out[#out + 1] = "== " .. name .. ": no instance"
    else
        out[#out + 1] = "== " .. name .. " " .. o:GetFullName():gsub("^%S+ ", "")
        local cls = o:GetClass()
        for _ = 1, (CLASS_DUMP_DEPTH or 1) do
            if not (cls and cls:IsValid()) then break end
            local cn = cls:GetFName():ToString()
            local props, funcs = {}, {}
            cls:ForEachProperty(function(p)
                local n = p:GetFName():ToString()
                local ty = p:GetClass():GetFName():ToString():gsub("Property$", "")
                if not ty:find("Delegate") and n ~= "UberGraphFrame" then
                    local simple = ({ Bool = 1, Int = 1, Float = 1, Byte = 1, Enum = 1, Name = 1, Str = 1, Object = CLASS_DUMP_OBJECTS })[ty]
                    local val = ""
                    if simple then local ok, v = pcall(function() return o[n] end) val = "=" .. (ok and str(v) or "ERR") end
                    props[#props + 1] = n .. ":" .. ty .. val
                end
            end)
            cls:ForEachFunction(function(f)
                local ps = {}
                f:ForEachProperty(function(p) ps[#ps + 1] = p:GetFName():ToString() end)
                local n = f:GetFName():ToString()
                if not n:find("^ExecuteUbergraph") then funcs[#funcs + 1] = n .. "(" .. table.concat(ps, ","):sub(1, 80) .. ")" end
            end)
            table.sort(funcs)
            out[#out + 1] = "  [" .. cn .. "] props: " .. table.concat(props, "  ")
            out[#out + 1] = "  [" .. cn .. "] funcs: " .. table.concat(funcs, "  ")
            cls = cls:GetSuperStruct()
        end
    end
end
return table.concat(out, "\n")
