--[[--
NiceBrowser: a fast, minimalist replacement for the KOReader library view.

@module koplugin.NiceBrowser
--]]--

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local NiceBrowser = WidgetContainer:extend{
    name = "nicebrowser",
    is_doc_only = false,
}

-- Load the plugin's own translations (l10n/<lang>/<domain>.mo), merged into
-- KOReader's gettext table (KOReader's plugin loader does not load plugin
-- .po/.mo files on its own). See l10n.lua.
pcall(require, "l10n")

-- Absolute directory path of this plugin (folder containing main.lua).
local function pluginDir()
    local src = (debug.getinfo(1, "S").source or "")
        :gsub("^@", ""):gsub("/[^/]+$", "/") -- keep trailing slash
    return src
end

-- Font auto-installation (SPEC §10 / portability).
-- Bundled font files live in <plugin>/fonts/; KOReader scans ./fonts in its
-- install directory. We copy the bundled fonts into KOReader's ./fonts when
-- they are missing, so the plugin is self-contained across installs.
local BUNDLED_FONTS = {
    "SourceSerif4-Regular.ttf", "SourceSerif4-It.ttf",
    "SourceSerif4-Bold.ttf", "SourceSerif4-BoldIt.ttf",
    "SourceSans3-Regular.ttf", "SourceSans3-It.ttf",
    "SourceSans3-Bold.ttf", "SourceSans3-BoldIt.ttf",
}

-- Simple file copy helper (falls back to reading/writing bytes).
local function util_copy(src, dest)
    local in_f = io.open(src, "rb")
    if not in_f then return false, "cannot open " .. src end
    local out_f = io.open(dest, "wb")
    if not out_f then in_f:close() return false, "cannot write " .. dest end
    local data = in_f:read("*a")
    out_f:write(data)
    in_f:close()
    out_f:close()
    return true
end

local function ensureFonts()
    local lfs = require("libs/libkoreader-lfs")
    local src_dir = pluginDir() .. "fonts/"
    -- KOReader's install dir fonts folder = lfs.currentdir() .. "/fonts".
    local dest_dir = lfs.currentdir() .. "/fonts/"

    if lfs.attributes(src_dir, "mode") ~= "directory" then
        logger.warn("NiceBrowser: bundled fonts dir not found at", src_dir)
        return
    end
    if lfs.attributes(dest_dir, "mode") ~= "directory" then
        lfs.mkdir(dest_dir)
    end

    local installed = 0
    for _i, fname in ipairs(BUNDLED_FONTS) do
        local src = src_dir .. fname
        local dest = dest_dir .. fname
        if lfs.attributes(src, "mode") ~= "file" then
            logger.warn("NiceBrowser: bundled font missing:", fname)
        elseif lfs.attributes(dest, "mode") ~= "file" then
            local ok, err = pcall(util_copy, src, dest)
            if ok then
                installed = installed + 1
            else
                logger.warn("NiceBrowser: could not install font", fname, ":", err)
            end
        end
    end
    if installed > 0 then
        logger.info("NiceBrowser: installed", installed, "font(s) into", dest_dir)
    end
end

-- Soft-toggled replacement of the home screen (SPEC §9 / §7).
-- We save the original FileManager:showFiles and replace it while the
-- setting `nicebrowser_replace_home` is enabled, restoring it otherwise.
--
-- Timing note: plugins are loaded *inside* FileManager:init(), which runs
-- from *within* the original FileManager:showFiles() call that opens the
-- home screen at boot. Patching the class therefore only affects later
-- calls. To also replace the initial home screen, we close the freshly
-- shown FileManager instance on the next UI tick and show NiceBrowser.
local _showFiles_orig = nil
local _home_patched = false

local function showBrowser()
    local Browser = require("browser")
    local browser = Browser:new{
        on_open_book = function(path)
            NiceBrowser:openBookAnywhere(path)
        end,
    }
    browser:show()
end

local function applyHomeToggle(enable)
    if enable == _home_patched then return nil end

    local FileManager = require("apps/filemanager/filemanager")
    if enable then
        if not _showFiles_orig then
            _showFiles_orig = FileManager.showFiles
        end
        FileManager.showFiles = function(_, path, focused_file, selected_files)
            -- Launch NiceBrowser instead of the standard file browser.
            logger.info("NiceBrowser: replacing home screen at start")
            showBrowser()
        end
        _home_patched = true
        -- Boot-time replacement: the FileManager instance created by the
        -- showFiles() call we are nested in gets closed on the next tick.
        UIManager:nextTick(function()
            local FM = FileManager.instance
            if FM then
                logger.info("NiceBrowser: replacing home screen at start")
                showBrowser()
                FM:onClose()
            end
        end)
        logger.dbg("NiceBrowser: home replace enabled")
    else
        if _showFiles_orig then
            FileManager.showFiles = _showFiles_orig
        end
        _home_patched = false
        logger.dbg("NiceBrowser: home replace disabled")
    end
end

function NiceBrowser:init()
    ensureFonts()
    self.ui.menu:registerToMainMenu(self)
    applyHomeToggle(G_reader_settings:isTrue("nicebrowser_replace_home"))
    logger.dbg("NiceBrowser: initialised")
end

-- Re-apply the home toggle (called from the settings dialog after change).
function NiceBrowser:applyHomeReplace()
    applyHomeToggle(G_reader_settings:isTrue("nicebrowser_replace_home"))
end

-- Open the library browser (used by the menu and by the home toggle).
function NiceBrowser:showBrowserDialog()
    showBrowser()
end

-- Open a book robustly, regardless of whether we run from a FileManager
-- context (menu) or as the home-path replacement (no FM instance).
function NiceBrowser:openBookAnywhere(path)
    if not path then return end
    -- Prefer the standard FileManager open-file flow if a FM exists.
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        local ok, err = pcall(function()
            local filemanagerutil = require("apps/filemanager/filemanagerutil")
            filemanagerutil.openFile(FileManager.instance, path)
        end)
        if ok then return end
        logger.warn("NiceBrowser: FM open failed, falling back to ReaderUI:", err)
    end
    -- Fallback: open the document directly via the KOReader Reader.
    local ok, err = pcall(function()
        local ReaderUI = require("apps/reader/readerui")
        ReaderUI:showReader(path)
    end)
    if not ok then
        logger.warn("NiceBrowser: could not open book:", err)
    end
end

-- Open the library browser (menu entry).
function NiceBrowser:_openBrowser()
    self:showBrowserDialog()
end

-- Open the NiceBrowser settings dialog.
function NiceBrowser:_openSettings()
    local Settings = require("settings")
    Settings.on_change = function(key)
        if key == "nicebrowser_replace_home" then
            self:applyHomeReplace()
        end
    end
    Settings.show()
end

function NiceBrowser:addToMainMenu(menu_items)
    menu_items.nicebrowser_open = {
        text = _("NiceBrowser"),
        sorting_hint = "more_tools",
        callback = function()
            self:_openBrowser()
        end,
    }
    menu_items.nicebrowser_settings = {
        text = _("NiceBrowser settings"),
        sorting_hint = "more_tools",
        callback = function()
            self:_openSettings()
        end,
    }
end

return NiceBrowser
