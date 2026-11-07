-- Parameters of functions of a live class: FN_OF = { { "<class name>", { "Func", ... } }, ... } (set before this file).
local out = {}
local function params(f)
    local ps = {}
    f:ForEachProperty(function(p)
        local ty = p:GetClass():GetFName():ToString():gsub("Property$", "")
        local extra = ""
        pcall(function()
            if ty == "Object" then extra = "<" .. p:GetPropertyClass():GetFName():ToString() .. ">"
            elseif ty == "Struct" then extra = "<" .. p:GetStruct():GetFName():ToString() .. ">"
            elseif ty == "Enum" or ty == "Byte" then extra = "<" .. p:GetEnum():GetFName():ToString() .. ">" end
        end)
        ps[#ps + 1] = p:GetFName():ToString() .. ":" .. ty .. extra
    end)
    return table.concat(ps, ", ")
end
for _, e in ipairs(FN_OF or {}) do
    local a = FindFirstOf(e[1])
    if not a then out[#out + 1] = "no " .. e[1] else
        local want = {}
        for _, n in ipairs(e[2]) do want[n] = true end
        local cls = a:GetClass()
        out[#out + 1] = "== " .. cls:GetFullName()
        local g = 0
        while cls and cls:IsValid() and g < 8 do
            pcall(function() cls:ForEachFunction(function(f)
                local n = f:GetFName():ToString()
                if want[n] or e[2][1] == "*" then out[#out + 1] = "  " .. n .. "(" .. params(f) .. ")" end
            end) end)
            local ok, sup = pcall(function() return cls:GetSuperStruct() end)
            if not ok or not sup or not sup:IsValid() then break end
            cls = sup g = g + 1
        end
    end
end
return table.concat(out, "\n")
