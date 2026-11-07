-- The hood of the local real car: its material chain, the MID's own params, custom primitive data
local car
for _, x in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if x:IsValid() and x:GetFullName():find(":PersistentLevel.", 1, true) then car = x break end end
local SMC = StaticFindObject("/Script/Engine.StaticMeshComponent")
local o = {}
for _, a in ipairs(FindAllOf("Actor") or {}) do
  if #o < 8 and a:IsValid() and a:GetFullName():find(":PersistentLevel.", 1, true) then
    local par = a:GetAttachParentActor()
    if par and par:IsValid() and par:GetFullName() == car:GetFullName() and a:GetClass():GetFName():ToString():find("Panel_Base") then
      local comps = a:K2_GetComponentsByClass(SMC)
      for i = 1, #comps do
        local c = comps[i]:get()
        local m = c:GetMaterial(0)
        local chain = {}
        local cur = m
        for _ = 1, 5 do if cur and cur:IsValid() then chain[#chain + 1] = cur:GetClass():GetFName():ToString() .. ":" .. cur:GetFName():ToString() local okp, pp = pcall(function() return cur.Parent end) cur = okp and pp or nil else break end end
        local np = "-"
        pcall(function() np = string.format("s%d v%d t%d", #m.ScalarParameterValues, #m.VectorParameterValues, #m.TextureParameterValues) end)
        local cpd = "-"
        pcall(function() local d = c.CustomPrimitiveData.Data local t = {} for k = 1, #d do t[#t + 1] = string.format("%.2f", d[k]) end cpd = #d .. ":" .. table.concat(t, ",") end)
        local vecs = {}
        pcall(function() for k = 1, #m.VectorParameterValues do local x = m.VectorParameterValues[k] local v = x.ParameterValue vecs[#vecs + 1] = string.format("%s@%d,%d=%.2f,%.2f,%.2f", x.ParameterInfo.Name:ToString(), x.ParameterInfo.Association, x.ParameterInfo.Index, v.R, v.G, v.B) end end)
        o[#o + 1] = a:GetClass():GetFName():ToString() .. "/" .. c:GetFName():ToString() .. " mats=" .. c:GetNumMaterials() .. " chain=" .. table.concat(chain, " <- ") .. " params " .. np .. " cpd=" .. cpd .. " vec: " .. table.concat(vecs, " ")
      end
    end
  end
end
return table.concat(o, "\n")
