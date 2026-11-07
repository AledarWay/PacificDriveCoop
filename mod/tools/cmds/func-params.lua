-- Parameters of named UFunctions: FUNC_PARAMS = { "<class path>:<function>", ... } (set before this file).
local out = {}
for _, fp in ipairs(FUNC_PARAMS or {}) do
    local f = StaticFindObject(fp)
    if f and f:IsValid() then
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
        out[#out + 1] = fp:match("[^%.]+$") .. "(" .. table.concat(ps, ", ") .. ")"
    else
        out[#out + 1] = "missing " .. fp
    end
end
return table.concat(out, "\n")
