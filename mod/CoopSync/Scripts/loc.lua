-- The mod's in-game texts in the game's language (owner, alpha 18: every text of the mod in a localization file;
-- owner, 2026-11-07: one file per language, so a language is added by adding a file).
--   Scripts/lang/<code>.lua returns { [key] = text }: en.lua is the reference with every key; another language's
--   file may lack keys (they show in English). Code: the game's language, lower case: "ru", "de", "pt-br" ...
--   L(key, ...) -> the text in the current language; with arguments it is string.format(text, ...).
-- The language: the game's current language / culture (KismetInternationalizationLibrary), read once and again on
-- M.refresh(); lang/<full code>.lua ("pt-br"), else lang/<language>.lua ("pt"), else English.
-- A test or a player may force it: $COOPSYNC_LANG or the global CoopSyncLang = "ru" / "en" / any code.
local M = {}

local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "lang/"
local files = {} -- code -> its table, or false when there is no such file
local function load(code)
    if files[code] == nil then
        files[code] = false
        local path = dir .. code .. ".lua"
        local f = io.open(path, "r")
        if f then
            f:close()
            local ok, t = pcall(dofile, path)
            if ok and type(t) == "table" then files[code] = t
            else print("[CoopSync] loc: " .. path .. ": " .. tostring(t)) end
        end
    end
    return files[code] or nil
end

M.EN = load("en") or {}
local lang, texts

function M.refresh()
    local c = ""
    pcall(function()
        local KIL = StaticFindObject("/Script/Engine.Default__KismetInternationalizationLibrary")
        c = KIL:GetCurrentLanguage():ToString()
        if c == "" then c = KIL:GetCurrentCulture():ToString() end
    end)
    local force = CoopSyncLang or os.getenv("COOPSYNC_LANG")
    if force and force ~= "" then c = force end
    c = c:lower():gsub("_", "-")
    lang, texts = "en", M.EN
    for _, code in ipairs({ c, c:match("^(%a+)-") }) do
        if code ~= "" and code:find("^[%a%-]+$") then
            local t = load(code)
            if t then lang, texts = code, t break end
        end
    end
    return lang
end
function M.lang() return lang or M.refresh() end
function M.has(key) return M.EN[key] ~= nil end
function M.L(key, ...)
    if not lang then M.refresh() end
    local s = texts[key] or M.EN[key] or key
    if select("#", ...) > 0 then
        local ok, r = pcall(string.format, s, ...)
        if ok then return r end
        ok, r = pcall(string.format, M.EN[key] or key, ...) -- (a translation with broken %-codes: the English one)
        if ok then return r end
    end
    return s
end

CoopSyncLoc = M -- (one instance for every module)
return M
