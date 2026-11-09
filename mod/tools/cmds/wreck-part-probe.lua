-- An abandoned car's parts hit the way the scrapper hits them (2026-11-09, owner: "on an abandoned car the friend
-- saws off the whole white bar of a part, the red one never starts"). The wreck nearest WP_AT (or the player): its
-- parts with a health component (socket, class, health, break health); WP_PART (socket name) gets WP_N hits of WP_DMG
-- by the WP_MSG damage message dispatched to the part actor (the effect shows on the next frame: read again later).
local MSG = WP_MSG or "MSG_Damage_Physical_Piercing_Scrapper"
local HC = StaticFindObject("/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_HealthComponent.BP_HealthComponent_C")
local me = WP_AT or FindFirstOf("PlayerController").Pawn:K2_GetActorLocation()
local best, bd
for _, w in ipairs(FindAllOf("LootableTemplate") or {}) do
    if w:IsValid() and not w:GetFullName():find("Default__", 1, true) then
        local l = w:K2_GetActorLocation()
        local d = (l.X - me.X) ^ 2 + (l.Y - me.Y) ^ 2 + (l.Z - me.Z) ^ 2
        if not bd or d < bd then best, bd = w, d end
    end
end
if not best then return "no wreck" end
local wl = best:K2_GetActorLocation()
local parts = {}
for _, p in ipairs(FindAllOf("LootableTemplatePart") or {}) do
    if p:IsValid() then
        local par = p:GetAttachParentActor()
        if par and par:IsValid() and par:GetAddress() == best:GetAddress() then parts[#parts + 1] = p end
    end
end
local function sock(p) local ok, s = pcall(function() return p.MySocket:ToString() end) return ok and s or "?" end
local function info(p)
    local hc = p:GetComponentByClass(HC)
    if not (hc and hc:IsValid()) then return nil end
    local h, bh = -1, -1
    pcall(function() h = hc:HC_GetHealth() end)
    pcall(function() bh = hc:HC_GetBreakHealth() end)
    return string.format("%s %s h=%.1f bh=%.1f", sock(p), p:GetClass():GetFName():ToString(), h, bh)
end
local out = { string.format("%s at %.0f,%.0f,%.0f (%.0f away), %d parts", best:GetClass():GetFName():ToString(), wl.X, wl.Y, wl.Z, math.sqrt(bd), #parts) }
local target
for _, p in ipairs(parts) do
    local s = info(p)
    if s and (not WP_PART or sock(p) == WP_PART) then out[#out + 1] = s end
    if WP_PART and sock(p) == WP_PART then target = p end
end
if WP_PART and (WP_N or 0) > 0 then
    if not target then out[#out + 1] = "no part " .. WP_PART
    else
        local path = "/Game/Systems/Messages/" .. MSG .. "." .. MSG .. "_C"
        local c = StaticFindObject(path)
        if not (c and c:IsValid()) then pcall(function() LoadAsset((path:gsub("_C$", ""))) end) c = StaticFindObject(path) end
        local ms = FindFirstOf("MessageSystem")
        for i = 1, WP_N do
            local ok, e = pcall(function()
                local msg = StaticConstructObject(c, ms)
                msg.Damage = WP_DMG or 10
                msg.HitLocation = target:K2_GetActorLocation()
                msg:Initialize()
                ms:DispatchMessage(msg, target)
            end)
            if not ok then out[#out + 1] = "hit ERR " .. tostring(e) break end
        end
        out[#out + 1] = "sent " .. WP_N .. " hits"
    end
end
return table.concat(out, " || ")
