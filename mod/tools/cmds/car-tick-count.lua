-- How often the player car's functions run on the own car and on the twin (hooks registered once per Lua state; read
-- the counts with TC_READ = true after a while). Functions: TC_FUNCS (default ReceiveTick, the ElectronicUpdate_*,
-- TopLightUpdate).
local T = _G.CoopPlayers.twinModule()
_G.CarTickCount = _G.CarTickCount or { n = {}, hooked = {} }
local C = _G.CarTickCount
if TC_READ then
    TC_READ = nil
    local o = {}
    for k, v in pairs(C.n) do o[#o + 1] = k .. "=" .. v end
    table.sort(o)
    C.n = {}
    return table.concat(o, " ")
end
local car = FindFirstOf("BP_PlayerCarNew_C")
local cls = car:GetClass():GetFullName():gsub("^%S+%s+", "")
local o = {}
for _, fn in ipairs(TC_FUNCS or { "ReceiveTick", "ElectronicUpdate_TopLight", "ElectronicUpdate_All", "ElectronicUpdate_Dash", "ElectronicUpdate_RearLights", "TopLightUpdate" }) do
    if not C.hooked[fn] then
        local ok, e = pcall(RegisterHook, cls .. ":" .. fn, function(self)
            local a = self:get()
            local k = (T.isTwin(a) and "TWIN." or "OWN.") .. fn
            C.n[k] = (C.n[k] or 0) + 1
        end)
        C.hooked[fn] = true
        o[#o + 1] = fn .. ":" .. tostring(ok) .. (ok and "" or (" " .. tostring(e)))
    end
end
C.n = {}
TC_FUNCS = nil
return table.concat(o, " ")
