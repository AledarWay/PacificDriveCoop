-- The other's car's gas cap (owner, 2026-11-09: "the friend's car's fuel tank does nothing - let us siphon from it, as
-- from abandoned cars, and fill it, as the game does for the own car").
-- A car's gas cap part (BP_CarPart_GasCap_C) has a BP_FuelableComponent_GasCap_C: its CarActor is its car and its
-- GetFuelTanks gives that car's tank items (the twin's: the twin's tanks, probed 2026-11-10), but its GetFuelStatus,
-- "Give Fuel" and "Take Fuel" go to the car manager's tanks - the local player's own car: on the guest the host's
-- car's cap showed the guest's own 6 (the host's tank had 12), and "Give Fuel" 3 there filled the guest's own tank
-- (9.3 -> 12.3, the host's stayed). Its fuelable actions say it cannot be siphoned (the own car: right).
-- Now, for a cap whose car is the other's twin (UE4SS's hooks run after the body and their out params can be set -
-- what the caller gets; probed):
--   * GetFuelStatus: the twin's tanks' fuel and capacity (their own BP_FuelableComponent_C, the owner's values);
--   * GetFuelableActions: it can be siphoned too (an abandoned car's tank can);
--   * "Give Fuel" / "Take Fuel": what the body put into / took from the own car's tanks goes back there (the car
--     manager's SiphonAllFuelTanks / RefuelAllFuelTanks), and the amount goes into / out of the twin's tanks - their
--     components, so the twin's part state sends the change to the owner (twincar EY f), whose real tanks follow.
local M = {}
local CAP = "/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_FuelableComponent_GasCap.BP_FuelableComponent_GasCap_C:"
local FC = "/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_FuelableComponent.BP_FuelableComponent_C"

CoopSyncGasCap = CoopSyncGasCap or {}
local G = CoopSyncGasCap
G.stats = G.stats or {}
for _, k in ipairs({ "status", "actions", "given", "taken", "errors" }) do G.stats[k] = G.stats[k] or 0 end
M.G = G

local fcCls
local function tankComps(cap)
    fcCls = (fcCls and fcCls:IsValid()) and fcCls or StaticFindObject(FC)
    local a, b, c = {}, {}, {}
    cap:GetFuelTanks(a, b, c)
    local out = {}
    for i = 1, (b.NumFuelTanks or 0) do
        local it = a[i]
        if it and it.get then it = it:get() end
        -- (a fuel can carried in an attachment slot is among the car's "tanks" but the game's own cap leaves it out:
        -- the host's cap 45 of tanks 20 + 25 + its can's 10; the guest's twin cap showed 55 - journey-test 2026-11-13)
        local tool = false
        pcall(function() tool = it:IsValid() and it.Archetype:GetFName():ToString():find("^IA_Tool_") ~= nil end)
        if tool then it = nil end
        local act = it and it:IsValid() and it:GetActorManifestation()
        local fc = act and act:IsValid() and act:GetComponentByClass(fcCls)
        if fc and fc:IsValid() then out[#out + 1] = fc end
    end
    return out
end
local function status(fc)
    local t = { {}, {}, {}, {}, {}, {}, {} }
    fc:GetFuelStatus(t[1], t[2], t[3], t[4], t[5], t[6], t[7])
    return tonumber(t[1].Fuel) or 0, tonumber(t[2]["Fuel Capacity"]) or 0
end
-- the cap's car when it is the other's twin (else nil: the own car's cap is the game's)
local function otherCap(ctx)
    local cap = ctx:get()
    if cap:GetClass():GetFName():ToString() ~= "BP_FuelableComponent_GasCap_C" then return nil end
    local car = cap.CarActor
    if car and car:IsValid() and G.isTwin and G.isTwin(car) then return cap end
    return nil
end
local function manager() return (CoopSyncFirst or FindFirstOf)("BP_CarManager_C") end

function G.onStatus(ctx, fuel, cap, pct, multi, empty, full, inf)
    local ok, e = pcall(function()
        local c = otherCap(ctx)
        if not c then return end
        local f, m = 0, 0
        for _, fc in ipairs(tankComps(c)) do local a, b = status(fc) f, m = f + a, m + b end
        fuel:set(f) cap:set(m) pct:set(m > 0 and f / m or 0) empty:set(f <= 0.001) full:set(m > 0 and f >= m - 0.001)
        G.stats.status = G.stats.status + 1
    end)
    if not ok then G.stats.errors = G.stats.errors + 1 G.stats.lastErr = tostring(e) end
end
function G.onActions(ctx, canSiphon, canRefuel, canBeSiphoned)
    local ok, e = pcall(function()
        if not otherCap(ctx) then return end
        canBeSiphoned:set(true)
        G.stats.actions = G.stats.actions + 1
    end)
    if not ok then G.stats.errors = G.stats.errors + 1 G.stats.lastErr = tostring(e) end
end
-- the body's amount back to the own car, then the asked amount through the twin's tanks
function G.onGive(ctx, amount, filled, full)
    local ok, e = pcall(function()
        local c = otherCap(ctx)
        if not c then return end
        local m = manager()
        local back = tonumber(filled:get()) or 0
        if back > 0 then m:SiphonAllFuelTanks(back, {}, {}) end
        local left, got = tonumber(amount:get()) or 0, 0
        local isFull = true
        for _, fc in ipairs(tankComps(c)) do
            if left <= 0.0001 then break end
            local o1, o2 = {}, {}
            fc["Give Fuel"](fc, left, o1, o2)
            local n = tonumber(o1["Amount Filled"]) or 0
            got, left = got + n, left - n
            if o2.Full ~= true then isFull = false end
        end
        filled:set(got) full:set(isFull and left > 0.0001)
        G.stats.given = G.stats.given + got
    end)
    if not ok then G.stats.errors = G.stats.errors + 1 G.stats.lastErr = tostring(e) end
end
function G.onTake(ctx, amount, emptied, empty)
    local ok, e = pcall(function()
        local c = otherCap(ctx)
        if not c then return end
        local m = manager()
        local back = tonumber(emptied:get()) or 0
        if back > 0 then m:RefuelAllFuelTanks(back, {}, {}) end
        local left, got = tonumber(amount:get()) or 0, 0
        local isEmpty = true
        for _, fc in ipairs(tankComps(c)) do
            if left <= 0.0001 then break end
            local o1, o2 = {}, {}
            fc["Take Fuel"](fc, left, o1, o2)
            local n = tonumber(o1["Amount Emptied"]) or 0
            got, left = got + n, left - n
            -- (downwards: the twin's part state sends only what goes up - told here, for the owner's tank)
            if n > 0 and G.noteSiphon then G.noteSiphon(c.CarActor, fc, n) end
            if o2.Empty ~= true then isEmpty = false end
        end
        emptied:set(got) empty:set(isEmpty and left > 0.0001)
        G.stats.taken = G.stats.taken + got
    end)
    if not ok then G.stats.errors = G.stats.errors + 1 G.stats.lastErr = tostring(e) end
end

-- isTwin(car) -> true for the other's twin; the hooks once per Lua state (they call G.on*: a reloaded module replaces those)
function M.start(isTwin, noteSiphon)
    G.isTwin, G.noteSiphon = isTwin, noteSiphon -- (in G: a module loaded again for its info keeps them)
    if G.hooked then return "gascap hooked before" end
    local Hooks = CoopSyncHook or dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "hooks.lua").hook
    G.hooked = true
    Hooks(CAP .. "GetFuelStatus", function(...) return G.onStatus(...) end)
    -- (the actions are the base class's: every fuelable component's call comes here, the cap's picked by its class)
    Hooks(FC .. ":GetFuelableActions", function(...) return G.onActions(...) end)
    Hooks(CAP .. "Give Fuel", function(...) return G.onGive(...) end)
    Hooks(CAP .. "Take Fuel", function(...) return G.onTake(...) end)
    return "gascap hooked"
end
function M.info()
    local s = G.stats
    return string.format("gascap status=%d actions=%d given=%.1f taken=%.1f errors=%d%s", s.status, s.actions, s.given, s.taken, s.errors,
        s.lastErr and (" " .. s.lastErr:sub(1, 80)) or "")
end
return M
