-- The shared state comparison (soak-test.ps1, compare-state.ps1): this side's own car and the other's twin in one
-- form, each line "<what> <value>", written to DIGEST_OUT. The other side's file holds the same lines the other way
-- round: own.* there against twin.* here.
--   own.equip / twin.equip     the car's slots (twincar equipLine)
--   own.state / twin.state     the parts' health, fuel, battery (twincar stateLine)
--   own.lights / twin.lights   the lights (twincar lightLine)
--   own.store / twin.store     the trunk and the storages (carstore ownLine without the acks / twinLine)
--   own.car / twin.car         x,y,z,speed (cm/s)
--   self / puppet              the own character: x,y,z,in car / the other's puppet: x,y,z
--   info                       counters: errors, hitches, fps, mod ms, memory of the Lua state (KB)
local P = rawget(_G, "CoopPlayers")
local T = P.twinModule()
local own = T.ownCar()
local twin
for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and T.isTwin(c) then twin = c end end
local out = {}
local function put(k, v) out[#out + 1] = k .. " " .. tostring(v == nil and "-" or v):gsub("[\r\n]", " ") end
local function call(f, ...) local ok, r = pcall(f, ...) if ok then return r end return "ERR:" .. tostring(r) end
local function car(a)
    if not (a and a:IsValid()) then return "-" end
    local l = a:K2_GetActorLocation()
    local v = { X = 0, Y = 0, Z = 0 }
    pcall(function() v = a:GetVelocity() end)
    return string.format("%.0f,%.0f,%.0f,%.0f", l.X, l.Y, l.Z, math.sqrt(v.X * v.X + v.Y * v.Y))
end
put("own.equip", call(T.equipLine))
put("own.state", call(T.stateLine))
put("own.lights", own and call(T.lightLine, own) or "-")
put("own.store", (tostring(call(T.Store.ownLine)):gsub("~%d+\t", "\t")))
put("own.car", car(own))
local tc = twin and T.twinContainer(twin)
put("twin.equip", tc and call(T.equipLine, tc) or "-")
put("twin.state", tc and call(T.stateLine, tc) or "-")
put("twin.lights", tc and call(T.lightLine, twin, tc) or "-")
put("twin.store", twin and call(T.Store.twinLine, twin) or "-")
put("twin.car", car(twin))
local pawn = FindFirstOf("PlayerController").Pawn
if pawn and pawn:IsValid() then
    local l = pawn:K2_GetActorLocation()
    local par = pawn:GetAttachParentActor()
    put("self", string.format("%.0f,%.0f,%.0f,%s", l.X, l.Y, l.Z, (par and par:IsValid()) and (T.isTwin(par) and "twin" or "own") or "foot"))
end
local pup = P.puppetParts()
put("puppet", pup and pup:IsValid() and (function() local l = pup:K2_GetActorLocation() return string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z) end)() or "-")
local H = rawget(_G, "CoopSyncHitch")
local rep = call(P.report)
put("info", string.format("errors=%s twin_errors=%d store_errors=%d lua_kb=%.0f fps=%s mod_ms=%s gaps=%s worst_gap=%s",
    rep:find("ERRORS", 1, true) and "1" or "0", #(T.stats.errors or {}), T.Store.stats.errors or 0, collectgarbage("count"),
    H and string.format("%.1f", H.fps or -1) or "-", H and string.format("%.2f", H.modMs or -1) or "-",
    H and tostring(H.stats.gaps) or "-", H and tostring(H.stats.worst) or "-"))
put("report", rep)
local f = io.open(DIGEST_OUT, "wb")
f:write(table.concat(out, "\n") .. "\n")
f:close()
return "digest " .. #out .. " lines, twin=" .. tostring(twin ~= nil)
