-- StaticMeshActors / other non-replicated actors of the zone: by level (persistent / streamed sublevel), runtime-
-- spawned or placed, and the attach root's class. Written as TSV to <dir>/census.tsv: kind, level, runtime, root, mesh, x, y, z
local dir = CENSUS_DIR
local f = io.open(dir .. "/census.tsv", "wb")
local n = 0
local function root(a)
    local cur, g = a, 0
    while g < 10 do
        local p = cur:GetAttachParentActor()
        if not (p and p:IsValid()) then break end
        cur, g = p, g + 1
    end
    return cur
end
for _, cls in ipairs({ "StaticMeshActor", "ManageChildrenActor", "PointLight", "SpotLight" }) do
    for _, a in ipairs(FindAllOf(cls) or {}) do
        if a:IsValid() and not a:GetFullName():find("/Engine/Transient", 1, true) then
            local full = a:GetFullName()
            local level = full:match("/Game/Maps/[^%.]+%.([^:]+):PersistentLevel") or "?"
            local runtime = (tonumber(a:GetFName():ToString():match("_(%d+)$") or "") or 0) > 2000000000
            local r = root(a)
            local mesh = "-"
            if cls == "StaticMeshActor" then pcall(function() local m = a.StaticMeshComponent.StaticMesh if m:IsValid() then mesh = m:GetFName():ToString() end end) end
            local l = a:K2_GetActorLocation()
            local rl = r:K2_GetActorLocation()
            f:write(string.format("%s\t%s\t%s\t%s\t%s\t%.0f\t%.0f\t%.0f\t%s\t%.0f,%.0f\n", cls, level, runtime and "rt" or "placed",
                r:GetAddress() == a:GetAddress() and "-" or r:GetClass():GetFName():ToString(), mesh, l.X, l.Y, l.Z,
                r:GetFName():ToString(), rl.X, rl.Y))
            n = n + 1
        end
    end
end
f:close()
return n .. " actors"
