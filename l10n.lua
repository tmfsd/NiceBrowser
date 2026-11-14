--[[--
NiceBrowser l10n loader.

KOReader's plugin loader does not load plugin translations: the core gettext
only loads a compiled `l10n/<lang>/koreader.mo` from KOReader's own directory.
This module loads the plugin's compiled `l10n/<lang>/nicebrowser.mo` for the
current UI language and merges its entries into KOReader's translation table
(same approach as projecttitle's l10n/gettext.lua, without the proxy).

It also wraps `GetText.changeLang` so the merge is re-applied whenever the
UI language is switched later (KOReader prompts for a restart after a
switch, so this mainly keeps the merge correct without relying on that).

@module nicebrowser.l10n
--]]--

local util = require("util")
local logger = require("logger")

local full_source_path = debug.getinfo(1, "S").source
if full_source_path:sub(1, 1) == "@" then
    full_source_path = full_source_path:sub(2)
end
local plugin_path = util.splitFilePathName(full_source_path):gsub("/+", "/")

local GetText = require("gettext")

-- Keep a reference to the un-patched changeLang (safe even if this module
-- is somehow loaded twice in one session).
local raw_changeLang = GetText.changeLang

-- Load the plugin catalog for `lang` without disturbing the core tables.
-- Returns the plugin-only translation/context tables, or nil when there is
-- nothing to merge (no .mo for that language / load failure).
local function loadPluginCatalog(lang)
    local core_translation = GetText.translation
    local core_context = GetText.context
    local core_dirname = GetText.dirname
    local core_textdomain = GetText.textdomain
    local core_current_lang = GetText.current_lang
    local core_plural = GetText.getPlural

    GetText.dirname = plugin_path .. "l10n"
    GetText.textdomain = "nicebrowser"
    local ok = pcall(raw_changeLang, lang)
    local plugin_translation = GetText.translation
    local plugin_context = GetText.context

    -- changeLang replaces all of the fields below: restore the core state.
    GetText.dirname = core_dirname
    GetText.textdomain = core_textdomain
    GetText.translation = core_translation
    GetText.context = core_context
    GetText.current_lang = core_current_lang
    GetText.getPlural = core_plural

    if ok and (next(plugin_translation) or next(plugin_context)) then
        return plugin_translation, plugin_context
    end
end

-- Merge the plugin's entries into the currently loaded (core) tables.
-- Plugin entries win for its own msgids; core translations stay untouched.
local function mergePluginTranslations(lang)
    local plugin_t, plugin_c = loadPluginCatalog(lang)
    if not plugin_t then return false end
    for k, v in pairs(plugin_t) do GetText.translation[k] = v end
    for k, v in pairs(plugin_c) do GetText.context[k] = v end
    return true
end

-- Load once for the current UI language...
local lang = G_reader_settings and G_reader_settings:readSetting("language") or nil
if lang and lang ~= "C" and not lang:match("^en_US") then
    if mergePluginTranslations(lang) then
        logger.dbg("NiceBrowser: loaded translations for", lang)
    end
end

-- ...and re-merge after any later language switch.
if not GetText.nicebrowser_l10n_hooked then
    GetText.nicebrowser_l10n_hooked = true
    GetText.changeLang = function(new_lang)
        local res = raw_changeLang(new_lang)
        if res then
            mergePluginTranslations(new_lang)
        end
        return res
    end
end

return {}
