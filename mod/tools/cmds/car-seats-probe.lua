-- Where the seats' devices really are (car-local, X forward, Y right) and whether a seat frame holds an item.
local car
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
    if c:IsValid() and c:GetFullName():find(":PersistentLevel.", 1, true) then car = c end
end
if not car then return "no car" end
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local xf = car:GetTransform()
local function loc(v) local l = KML:InverseTransformLocation(xf, v) return string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z) end
local out = {}
local crumbFile = (os.getenv("COOPDEV_DIR") or "C:/PacificDriveCoop/local/coopdev") .. "/seats-crumbs.txt"
local function crumb(s) local f = io.open(crumbFile, "ab") if f then f:write(s .. "\n") f:close() end end
crumb("--- start " .. os.date("%H:%M:%S"))
for _, n in ipairs({ "SLOT_Internal_Computer", "SLOT_BackSeatLeft", "SLOT_BackSeatRight", "SLOT_Interior_Large_01",
    "SLOT_Internal_ReserveBattery", "SLOT_Internal_ReserveGas", "SLOT_FrontLeftDoor", "SLOT_FrontRightDoor",
    "SLOT_RearLeftDoor", "SLOT_RearRightDoor", "SLOT_TrunkStorage" }) do
    local ok, s = pcall(function()
        crumb(n .. " comp") local c = car[n]
        local r = { n }
        crumb(n .. " spawned") local a = c.SpawnedActor
        if a and a:IsValid() then r[#r + 1] = "actor=" .. a:GetClass():GetFName():ToString() .. "@" .. loc(a:K2_GetActorLocation()) end
        crumb(n .. " itemslot") local sl = c.ItemSlot
        if sl and sl:IsValid() then
            local items = {}
            crumb(n .. " items") for i = 1, sl.Items:GetArrayNum() do
                crumb(n .. " item " .. i) local it = sl.Items[i]
                items[#items + 1] = (it and it:IsValid() and it.Archetype:IsValid()) and it.Archetype:GetFName():ToString() or "?"
            end
            crumb(n .. " cap") r[#r + 1] = "slotItems=[" .. table.concat(items, ",") .. "] cap=" .. tostring(sl.Capacity)
            -- (reading sl.FilterItemType crashed the game on SLOT_Interior_Large_01: AV, garbage pointer)
        end
        crumb(n .. " empty") pcall(function() r[#r + 1] = "empty=" .. tostring(c.EmptyInstance:IsValid()) end)
        return table.concat(r, " ")
    end)
    out[#out + 1] = ok and s or (n .. " ERR " .. tostring(s))
end
-- (a FindAllOf loop over these device classes crashed the game: AV 0x18 on non-level template instances)
crumb("attached") local att = {}
pcall(function() car:GetAttachedActors(att, true) end)
local seen = {}
for _, a in ipairs(att) do
    pcall(function()
        a = a.get and a:get() or a
        local k = a:GetClass():GetFName():ToString() .. "@" .. loc(a:K2_GetActorLocation())
        if not seen[k] then seen[k] = true out[#out + 1] = "attached " .. k end
    end)
end
return table.concat(out, "\n")
