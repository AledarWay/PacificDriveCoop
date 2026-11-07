-- The garage's driver's checklist on the HUD (owner, alpha 18: a "Кооператив" list like the game's "Список водителя"):
-- the live UMG_Objective_List widgets, which one is the checklist, what its boxes hold, the texts of its entries.
local out = {}
local function texts(w, depth, acc)
    if depth > 8 or #acc > 40 then return end
    pcall(function()
        local cls = w:GetClass():GetFName():ToString()
        if cls == "TextBlock" or cls:find("RichTextBlock") then
            local t = ""
            pcall(function() t = w:GetText():ToString() end)
            acc[#acc + 1] = string.format("%s[%s]vis=%d", w:GetFName():ToString(), t, w:GetVisibility())
        end
    end)
    local ok, n = pcall(function() return w:GetChildrenCount() end)
    if ok and n then
        for i = 0, n - 1 do local c = w:GetChildAt(i) if c and c:IsValid() then texts(c, depth + 1, acc) end end
    end
    pcall(function()
        local tree = w.WidgetTree
        if tree and tree.RootWidget and tree.RootWidget:IsValid() then texts(tree.RootWidget, depth + 1, acc) end
    end)
end
for _, w in ipairs(FindAllOf("UMG_Objective_List_C") or {}) do
    if w:IsValid() and w:GetFullName():find("/Engine/Transient", 1, true) then
        local acc = {}
        texts(w, 0, acc)
        out[#out + 1] = string.format("%s checklist=%s vis=%d inViewport=%s normal=%d crit=%d | %s", w:GetFName():ToString(),
            tostring(w.bIsDriversChecklistObjectiveList), w:GetVisibility(), tostring(w:IsInViewport()),
            w.NormalObjectiveListBox:GetChildrenCount(), w.CritpathObjectiveListBox:GetChildrenCount(), table.concat(acc, "; "))
    end
end
return #out .. " lists || " .. table.concat(out, " || ")
