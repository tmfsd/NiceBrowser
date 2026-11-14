--[[--
NiceBrowser settings.

Builds the NiceBrowser preferences menu (category sub-menus on the KOReader
Menu widget) and persists values directly into `G_reader_settings`, so they
are shared across KOReader and survive restarts.

Categories follow SPEC §8: Bibliothek, Darstellung, Navigation, Suche,
Sonstiges, Farbe. Each option maps to a `nicebrowser_*` setting key.

@module nicebrowser.settings
--]]--

local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local SpinWidget = require("ui/widget/spinwidget")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Settings = {}

-- ---- Reading/writing helpers (persist in G_reader_settings) ----

local function getBool(key)
    return G_reader_settings:isTrue(key)
end

local function setBool(key, value)
    if value then G_reader_settings:makeTrue(key)
    else G_reader_settings:makeFalse(key) end
end

local function getNumber(key, default)
    return tonumber(G_reader_settings:readSetting(key)) or default
end

-- Numeric option: opens a SpinWidget (min/max/step).
local function numberOption(key, label, min, max, default, step)
    return {
        text_func = function()
            return T(_("%1: %2"), label, getNumber(key, default))
        end,
        callback = function()
            local spin = SpinWidget:new{
                title = label,
                value = getNumber(key, default),
                value_min = min,
                value_max = max,
                value_step = step or 1,
                default_value = default,
                callback = function(spin)
                    G_reader_settings:saveSetting(key, spin.value)
                    if Settings.on_change then Settings.on_change(key) end
                end,
            }
            UIManager:show(spin)
        end,
    }
end

-- Toggle option (checkbox in a sub-menu item).
local function toggleOption(key, label, default_true)
    return {
        text = label,
        checked_func = function()
            if default_true then
                return G_reader_settings:nilOrTrue(key)
            end
            return getBool(key)
        end,
        callback = function()
            setBool(key, not getBool(key))
            if Settings.on_change then Settings.on_change(key) end
        end,
    }
end

-- Radio option group entry.
local function radioOption(key, value, label, default_value)
    return {
        text = label,
        radio = true,
        checked_func = function()
            return (G_reader_settings:readSetting(key) or default_value) == value
        end,
        callback = function()
            G_reader_settings:saveSetting(key, value)
            if Settings.on_change then Settings.on_change(key) end
        end,
    }
end

-- Menu entry that opens a nested sub-menu.
local function subMenuOption(text, sub_item_table)
    return { text = text, sub_item_table = sub_item_table }
end

local function libraryCategory()
    return {
        toggleOption("nicebrowser_auto_update", _("Automatic incremental update")),
    }
end

local function displayCategory()
    return {
        numberOption("nicebrowser_books_per_page", _("Books per page"), 1, 10, 4),
        numberOption("nicebrowser_authors_per_page", _("Authors/facets per page"), 5, 20, 10),
        toggleOption("nicebrowser_title_two_lines", _("Two-line titles"), true),
        toggleOption("nicebrowser_show_ui_bars", _("Show top/status bars"), true),
        subMenuOption(_("Font"), {
            radioOption("nicebrowser_font_face", "SourceSerif4", _("Serif (SourceSerif4)"), "SourceSerif4"),
            radioOption("nicebrowser_font_face", "SourceSans3", _("Sans (SourceSans3)"), "SourceSerif4"),
        }),
    }
end

local function navigationCategory()
    return {
        toggleOption("nicebrowser_doubletap_open", _("Double-tap opens book")),
        toggleOption("nicebrowser_sort_asc", _("Sort ascending"), true),
        toggleOption("nicebrowser_books_sort_filename", _("Books sorted by filename"), true),
        numberOption("nicebrowser_jump_pages", _("x-page jump"), 2, 20, 5),
    }
end

local function searchCategory()
    return {
        toggleOption("nicebrowser_search_authors", _("Search authors"), true),
        toggleOption("nicebrowser_search_titles", _("Search titles"), true),
        toggleOption("nicebrowser_search_global", _("Search whole library")),
        toggleOption("nicebrowser_az_register", _("Show A–Z register"), true),
    }
end

local function miscCategory()
    return {
        toggleOption("nicebrowser_reduced_effects", _("Reduced effects/animations")),
        toggleOption("nicebrowser_restore_position", _("Restore last level + page")),
        toggleOption("nicebrowser_replace_home", _("Replace home screen on start")),
        subMenuOption(_("Colours"), {
            radioOption("nicebrowser_color_mode", "greyscale", _("Greyscale (default)"), "greyscale"),
            radioOption("nicebrowser_color_mode", "color", _("Colour"), "greyscale"),
            radioOption("nicebrowser_color_mode", "bw", _("Black & white"), "greyscale"),
        }),
        { text = _("Reset all settings"), callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("Reset all NiceBrowser settings to defaults?"),
                ok_text = _("Reset"),
                ok_callback = function()
                    for _i, key in ipairs(Settings.allKeys) do
                        G_reader_settings:delSetting(key)
                    end
                    UIManager:show(InfoMessage:new{ text = _("NiceBrowser settings reset.") })
                end,
            })
        end },
    }
end

-- ---- Public ----

-- Optional hook invoked whenever a setting changes (set by the plugin host so
-- e.g. the home-replace patch can be re-applied).
Settings.on_change = nil

Settings.allKeys = {
    "nicebrowser_auto_update",
    "nicebrowser_books_per_page",
    "nicebrowser_authors_per_page",
    "nicebrowser_title_two_lines",
    "nicebrowser_show_ui_bars",
    "nicebrowser_doubletap_open",
    "nicebrowser_sort_asc",
    "nicebrowser_books_sort_filename",
    "nicebrowser_jump_pages",
    "nicebrowser_search_authors",
    "nicebrowser_search_titles",
    "nicebrowser_search_global",
    "nicebrowser_az_register",
    "nicebrowser_reduced_effects",
    "nicebrowser_restore_position",
    "nicebrowser_replace_home",
    "nicebrowser_color_mode",
    "nicebrowser_font_face",
}

-- Build and show the settings dialog as a fullscreen Menu.
function Settings.show(parent_callback)
    -- KOReader Menu handles nested sub_item_table automatically.
    local m = Menu:new{
        title = _("NiceBrowser settings"),
        item_table = {
            { text = _("Library"), sub_item_table = libraryCategory() },
            { text = _("Display"), sub_item_table = displayCategory() },
            { text = _("Navigation"), sub_item_table = navigationCategory() },
            { text = _("Search"), sub_item_table = searchCategory() },
            { text = _("Misc"), sub_item_table = miscCategory() },
        },
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        close_callback = parent_callback,
    }
    logger.dbg("NiceBrowser: showing settings dialog")
    UIManager:show(m)
end

return Settings
