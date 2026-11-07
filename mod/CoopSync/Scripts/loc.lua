-- The mod's in-game texts in the game's language (owner, alpha 18: "every text of the mod in a localization file,
-- Russian and English for now, picked by the game's language"). The texts are written in Russian in the code;
-- L(text) gives the English one when the game is not in Russian (a text missing here stays as it is).
-- The language: the game's current culture (KismetInternationalizationLibrary), read once and again on M.refresh().
local M = {}

M.EN = {
    -- the pause menu / F7 panel
    ["Кооператив"] = "Co-op",
    ["Назад"] = "Back",
    ["в гараже"] = "in the garage",
    ["в зоне "] = "in the zone ",
    ["Сеть: ждём Steam…"] = "Network: waiting for Steam…",
    ["Сеть Steam недоступна"] = "The Steam network is not available",
    ["Запустить сеть заново"] = "Restart the network",
    ["Создать лобби"] = "Create lobby",
    ["лобби создаётся…"] = "creating the lobby…",
    ["Приглашение от "] = "Invitation from ",
    [" — принять"] = " - accept",
    ["вход в лобби…"] = "joining the lobby…",
    ["вторая копия игры на этом ПК"] = "the second copy of the game on this PC",
    ["Войти в лобби: "] = "Join lobby: ",
    ["Лобби: %d из 2"] = "Lobby: %d of 2",
    [" мс"] = " ms",
    ["—"] = "—",
    [" (вы)"] = " (you)",
    [" · хост"] = " · host",
    ["Вы выбираете развилку"] = "You pick the junction",
    ["Хост ещё не в игре"] = "The host is not in the game yet",
    ["Ждём выезда хоста"] = "Waiting for the host to drive out",
    ["Хост в зоне — выезжайте"] = "The host is in the zone - drive out",
    ["Пригласить друга…"] = "Invite a friend…",
    ["Покинуть лобби"] = "Leave the lobby",
    ["вы вышли из лобби"] = "you left the lobby",
    ["Ошибка сети: "] = "Network error: ",
    ["Нет друзей в сети"] = "No friends online",
    [" (в Pacific Drive)"] = " (in Pacific Drive)",
    ["приглашение отправлено: "] = "invitation sent: ",
    ["Страница %d из %d — дальше"] = "Page %d of %d - next",
    ["Пересинхронизировать зону"] = "Resync the zone",
    ["Перезапустить синхронизацию"] = "Restart the sync",
    ["Телепорт к другому игроку"] = "Teleport to the other player",
    ["Вернуть детали машины (страховка)"] = "Restore car parts (insurance)",
    ["Собрать отчёт на рабочий стол"] = "Collect a report to the desktop",
    ["Выйти из сессии (одиночная игра)"] = "Leave the session (single player)",
    ["Состояние…"] = "State…",
    ["Сессия: "] = "Session: ",
    ["Сеть: %s лобби=%s пир=%s пинг=%s"] = "Network: %s lobby=%s peer=%s ping=%s",
    ["Игроки: "] = "Players: ",
    ["Мир: "] = "World: ",
    ["—— отладка ——"] = "—— debug ——",
    ["ошибка: "] = "error: ",
    ["отчёт собирается — файл появится на рабочем столе"] = "collecting the report - the file will appear on the desktop",
    ["CoopSync — панель (F7)"] = "CoopSync - panel (F7)",
    ["Закрыть (F7)"] = "Close (F7)",
    -- the co-op checklist in the garage (menu.lua M.checklist)
    ["Лобби: %d из 2 (пинг %s)"] = "Lobby: %d of 2 (ping %s)",
    [" (Вы)"] = " (You)",
    [" (Хост)"] = " (Host)",
    [" (Вы, Хост)"] = " (You, Host)",
    ["Выберите развилку"] = "Pick a junction",
    ["Выезжайте в зону"] = "Drive out to the zone",
    ["Ожидание хоста"] = "Waiting for the host",
    ["Лобби"] = "Lobby",
    ["%d из 2"] = "%d of 2",
    ["Игроки"] = "Players",
    ["Задача"] = "Task",
    -- session actions (debug)
    ["зона отправлена заново"] = "the zone was sent again",
    ["зона хоста загружается заново"] = "loading the host's zone again",
    ["нечего синхронизировать ("] = "nothing to sync (",
    ["синхронизация не запущена ("] = "the sync is not running (",
    ["синхронизация перезапускается"] = "restarting the sync",
    ["телепорт не удался: "] = "the teleport failed: ",
    ["не удалось вернуть детали: "] = "could not restore the parts: ",
    ["вы вышли из сессии (одиночная игра)"] = "you left the session (single player)",
    ["неизвестное действие "] = "unknown action ",
    -- playersync's teleport
    ["нет персонажа"] = "no character",
    ["сначала выйдите из машины"] = "get out of the car first",
    ["другого игрока здесь нет"] = "the other player is not here",
    ["вы рядом с другим игроком (%.0f, %.0f, %.0f)"] = "you are next to the other player (%.0f, %.0f, %.0f)",
}

local lang
function M.refresh()
    lang = "en"
    pcall(function()
        local KIL = StaticFindObject("/Script/Engine.Default__KismetInternationalizationLibrary")
        local c = KIL:GetCurrentLanguage():ToString()
        if c == "" then c = KIL:GetCurrentCulture():ToString() end
        if c:lower():find("^ru") then lang = "ru" end
    end)
    -- (a test or a player may force it: $COOPSYNC_LANG or CoopSyncLang = "ru" / "en"; the tests check Russian labels)
    local force = CoopSyncLang or os.getenv("COOPSYNC_LANG")
    if force == "ru" or force == "en" then lang = force end
    return lang
end
function M.lang() return lang or M.refresh() end
function M.L(s)
    if (lang or M.refresh()) == "ru" then return s end
    return M.EN[s] or s
end

CoopSyncLoc = M -- (one instance for every module)
return M
