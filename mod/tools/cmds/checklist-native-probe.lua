-- Build a co-op list out of the game's own checklist widgets (UMG_Objective_Info_C + UMG_Mission_Task_C) inside the
-- driver's checklist's place on the HUD; report what each part ended up with.
local WBL = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
local pc = FindFirstOf("PlayerController")
local main
for _, w in ipairs(FindAllOf("UMG_Missions_Main_C") or {}) do
    if w:IsValid() and w:GetFullName():find("/Engine/Transient", 1, true) then main = w end
end
if not main then return "no missions main" end
local list = main.UMG_DriversChecklist_Objective_List
local infoCls = FindObject("WidgetBlueprintGeneratedClass", "UMG_Objective_Info_C", 0, 0)
local taskCls = FindObject("WidgetBlueprintGeneratedClass", "UMG_Mission_Task_C", 0, 0)
if not (infoCls and taskCls) then return "classes: " .. tostring(infoCls) .. " " .. tostring(taskCls) end
local r = {}
local info = WBL:Create(main, infoCls, pc)
info.bIsDriversChecklistMission = true
pcall(function() info.ObjectiveTitleText:SetText(FText("КООПЕРАТИВ")) end)
pcall(function() info.ObjectiveDescriptionText:SetVisibility(1) end)
pcall(function() info.UMG_Mission_Info:SetVisibility(1) end)
list.NormalObjectiveListBox:AddChildToVerticalBox(info)
local rows = { { "ЛОББИ", "Лобби: 2 из 2 (пинг 10 мс)", true }, { "ИГРОКИ", "PLAYER1 (Вы, Хост)", true }, { nil, "PLAYER2", true }, { "ДЕЙСТВИЕ", "Выберите развилку", false } }
local box = info.UMG_Missions_TaskList.TaskList
for i, row in ipairs(rows) do
    local t = WBL:Create(main, taskCls, pc)
    t.bIsDriversChecklistMission = true
    box:AddChildToVerticalBox(t)
    pcall(function() t.TaskDescriptionText:SetText(FText(row[2])) end)
    pcall(function() if row[1] then t.SubHeaderText:SetText(FText(row[1])) t.SubHeader:SetVisibility(4) else t.SubHeader:SetVisibility(1) end end)
    pcall(function() t:SetCheckbox(row[3], true) end)
    pcall(function() t:SetVisible(true, false) end)
    r[#r + 1] = string.format("task%d vis=%d", i, t:GetVisibility())
end
pcall(function() info.UMG_Missions_TaskList:SetTasksVisible(true, false) end)
pcall(function() main.ShoppingListWidgetSwitcher:SetActiveWidgetIndex(1) end)
pcall(function() list:SetVisibility(4) end)
CHK_PROBE = { info = info }
return string.format("info vis=%d list vis=%d switcher=%d | %s", info:GetVisibility(), list:GetVisibility(), main.ShoppingListWidgetSwitcher:GetActiveWidgetIndex(), table.concat(r, " "))
