-- The dash of this side's own car and of the other's twin (owner's alpha 19 item 12): the LimBox's charge, the battery
-- digits' text, the computer's part icon of slot DASH_SLOT (its health share and whether it shows that car's item)
local T = _G.CoopPlayers.twinModule()
local own = T.ownCar()
local slot = DASH_SLOT or "Car.Equip.Attachments.BackSeatLeft"
local out = {}
local function carTag(a)
    local r = a:IsValid() and a:GetAttachParentActor()
    if not r then return nil, nil end
    if r:GetAddress() == own:GetAddress() then return "own", r end
    if T.isTwin(r) then return "twin", r end
end
for _, a in ipairs(FindAllOf("BP_CarPart_Internal_LimBox_C") or {}) do
    local t = carTag(a)
    if t then
        local w = a.BatteryWidget:GetUserWidgetObject()
        out[#out + 1] = string.format("%s_bat=%.2f %s_text=%s", t, a.CurrentBattery, t, w.UMG_BatteryCurrentDisplay_1.CurrentText:GetText():ToString())
    end
end
for _, a in ipairs(FindAllOf("BP_PlayerCar_Computer_C") or {}) do
    local t, car = carTag(a)
    if t then
        local kids = a.Widget:GetUserWidgetObject().ChildrenArray
        for i = 1, kids:GetArrayNum() do
            pcall(function()
                local p = kids[i]
                if p["Gameplay Tag"].TagName:ToString() == slot then
                    local it = p.ItemInstance
                    local m = it and it:IsValid() and it:GetActorManifestation()
                    local mine = m and m:IsValid() and m:GetAttachParentActor() and m:GetAttachParentActor():GetAddress() == car:GetAddress()
                    out[#out + 1] = string.format("%s_part=%.3f %s_part_item=%s", t, p.CachedHealthPercent, t, mine and "this_car" or "other")
                end
            end)
        end
    end
end
out[#out + 1] = string.format("dash=%s dash_parts=%s", tostring(T.stats.dash), tostring(T.stats.dashParts))
return table.concat(out, " ")
