--[[--
NiceBrowser core browser widget.

Provides the tabbed, drill-down library browsing UI built on KOReader's Menu:
- Tabs: Authors (default), Genres, Tags (separate tab row).
- Levels: for the Authors tab, author -> books. For Genre/Tag tabs:
  facet -> authors -> books.
- Custom top bar: home, up, search, sort direction, index actions,
  KOReader menu, close (SPEC §3).
- Breadcrumb in the top bar; combined status bar with pagination in the
  book-level cover list (listview).

@module nicebrowser.browser
--]]--

local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local CheckButton = require("ui/widget/checkbutton")
local Trapper = require("ui/trapper")
local logger = require("logger")
local NbTitleBar = require("nbtitlebar")
local BookStore = require("bookstore")
local CoverCache = require("covercache")
local Indexer = require("indexer")
local Search = require("search")
local _ = require("gettext")
local T = require("ffi/util").template

local BROWSER = BookStore:new()

-- Supported tabs and their types.
local TABS = {
    { key = "authors", text = _("Authors"), type = "authors" },
    { key = "genres",  text = _("Genres"),  type = "genre"   },
    { key = "tags",    text = _("Tags"),    type = "tag"     },
}

local NiceBrowser = {}

-- Browser instance state (kept per widget).
function NiceBrowser:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.store = BROWSER
    -- Navigation state
    o.tab = "authors"          -- current tab key
    o.level = "facet"          -- "facet" | "authors" | "books"
    o.facet_value = nil        -- selected genre/tag value (for genre/tag tabs)
    o.author = nil             -- selected author
    o.page = 1                 -- current page of the book list
    o.sort_asc = G_reader_settings:nilOrTrue("nicebrowser_sort_asc") -- SPEC §6
    o.menu = nil               -- current Menu widget instance
    o.cover_list = nil         -- current CoverList (books level)
    return o
end

-- Build the list of items for the current tab + level.
function NiceBrowser:_buildItemTable()
    local items
    local asc = self.sort_asc

    if self.tab == "genres" or self.tab == "tags" then
        local facet = self.tab == "genres" and "genre" or "tag"
        if self.level == "facet" then
            local rows = self.store:facetValues(facet, asc)
            items = {}
            for _i, r in ipairs(rows) do
                items[#items + 1] = {
                    text = r.value,
                    mandatory = tostring(r.count),
                    facet_value = r.value,
                }
            end
            return items
        elseif self.level == "authors" then
            local rows = self.store:authors(facet, self.facet_value, asc)
            items = {}
            for _i, r in ipairs(rows) do
                items[#items + 1] = {
                    text = r.author,
                    mandatory = tostring(r.count),
                    author = r.author,
                }
            end
            return items
        else -- books
            return self:_buildBooksItems(facet, self.facet_value, self.author)
        end
    else -- authors tab
        if self.level == "facet" then
            local rows = self.store:authors(nil, nil, asc)
            items = {}
            for _i, r in ipairs(rows) do
                items[#items + 1] = {
                    text = r.author or _("Unknown author"),
                    mandatory = tostring(r.count),
                    author = r.author,
                }
            end
            return items
        else -- books
            return self:_buildBooksItems(nil, nil, self.author)
        end
    end
end

-- Build book item rows for a given (optional) facet + author.
function NiceBrowser:_buildBooksItems(facet, facet_value, author)
    local asc = self.sort_asc
    local sort_by = G_reader_settings:nilOrTrue("nicebrowser_books_sort_filename") and "filename" or "year"
    local rows = self.store:booksForAuthor(author, facet, facet_value or nil, sort_by, asc)
    local items = {}
    for _idx, b in ipairs(rows) do
        local sub = {}
        if b.series then
            sub[#sub + 1] = b.series .. (b.series_index and (" " .. tostring(b.series_index)) or "")
        end
        if b.subseries then
            sub[#sub + 1] = b.subseries .. (b.subseries_index and (" " .. tostring(b.subseries_index)) or "")
        end
        local line2 = table.concat(sub, " · ")
        local line3 = {}
        if b.year then line3[#line3 + 1] = tostring(b.year) end
        if b.pages then line3[#line3 + 1] = tostring(b.pages) .. _(" p.") end
        local line3_str = table.concat(line3, " · ")
        items[#items + 1] = {
            text = b.title or b.series or _("(untitled)"),
            mandatory = line3_str ~= "" and line3_str or nil,
            filepath = b.path,
            book = {
                title = b.title, series = b.series, series_index = b.series_index,
                subseries = b.subseries, subseries_index = b.subseries_index,
                year = b.year, pages = b.pages, path = b.path,
                filepath = b.path,
                read_status = b.read_status,
                cover_file = b.has_cover == 1 and CoverCache.getPath(b.path) or nil,
            },
        }
    end
    return items
end

-- Current top-bar title for the breadcrumb (single-level, SPEC §3).
function NiceBrowser:_getTitle()
    if self.tab == "genres" or self.tab == "tags" then
        local facet = self.tab == "genres" and _("Genres") or _("Tags")
        if self.level == "facet" then
            return facet
        elseif self.level == "authors" then
            return facet .. " › " .. (self.facet_value or "")
        else
            return facet .. " › " .. (self.author or "")
        end
    else
        if self.level == "facet" then
            return _("Authors")
        else
            return _("Authors") .. " › " .. (self.author or "")
        end
    end
end

-- Persist the current navigation state (level, tab, facet, author, page)
-- so reopening restores position (SPEC §3 / §7).
function NiceBrowser:saveState()
    G_reader_settings:saveSetting("nicebrowser_state", {
        tab = self.tab,
        level = self.level,
        facet_value = self.facet_value,
        author = self.author,
        page = self.page,
    })
end

-- Restore a previously saved navigation state (called in show()).
function NiceBrowser:restoreState()
    local st = G_reader_settings:readSetting("nicebrowser_state")
    if not st then return end
    if st.tab then self.tab = st.tab end
    if st.level then self.level = st.level end
    self.facet_value = st.facet_value
    self.author = st.author
    self.page = tonumber(st.page) or 1
end

-- Handle a menu selection depending on current level.
function NiceBrowser:_onMenuSelect(menu, item)
    if not item then return end
    if self.level == "facet" then
        if self.tab == "genres" or self.tab == "tags" then
            self.facet_value = item.facet_value
            self.level = "authors"
        else
            self.author = item.author
            self.level = "books"
        end
    elseif self.level == "authors" then
        self.author = item.author
        self.level = "books"
    else -- books: open the book
        self:openBook(item.book)
        return
    end
    self.page = 1
    self:refresh()
    self:saveState()
end

-- Top-bar actions.

-- Jump to the top level (Home icon).
function NiceBrowser:onHome()
    self.level = "facet"
    self.facet_value = nil
    self.author = nil
    self.page = 1
    self:refresh()
    self:saveState()
end

-- Go up exactly one level (Up icon).
function NiceBrowser:onUp()
    self.page = 1
    if self.level == "books" then
        self.level = self.tab == "authors" and "facet" or "authors"
        self.author = nil
    elseif self.level == "authors" then
        self.level = "facet"
        self.facet_value = nil
    else
        return
    end
    self:refresh()
    self:saveState()
end

-- Switch tab (resets to the facet level of that tab, per SPEC).
function NiceBrowser:onTab(key)
    if self.tab == key then return end
    self.tab = key
    self.level = "facet"
    self.facet_value = nil
    self.author = nil
    self.page = 1
    self:refresh()
    self:saveState()
end

-- Toggle sort direction (sort head click).
function NiceBrowser:onToggleSort()
    self.sort_asc = not self.sort_asc
    G_reader_settings:saveSetting("nicebrowser_sort_asc", self.sort_asc)
    self:refresh()
end

-- Tab row: three tappable tab buttons pinned at the top of the item table.
-- Implemented as prefix entries of the Menu's item_table (see _fullItemTable).
function NiceBrowser:_tabItems()
    local items = {}
    for _i, t in ipairs(TABS) do
        items[#items + 1] = {
            text = (t.key == self.tab and "● " or "○ ") .. t.text,
            is_tab = true,
            tab_key = t.key,
            mandatory = nil,
        }
    end
    return items
end

-- Show the index actions menu (SPEC §7).
function NiceBrowser:onIndexMenu()
    local dialog
    local buttons = {
        {{
            text = _("Scan library (full)"),
            callback = function()
                UIManager:close(dialog)
                self:_runScan(false)
            end,
        }},
        {{
            text = _("Add new books"),
            callback = function()
                UIManager:close(dialog)
                self:_runScan(true)
            end,
        }},
        {{
            text = _("Clear cover cache"),
            callback = function()
                UIManager:close(dialog)
                CoverCache.clear()
                UIManager:show(InfoMessage:new{ text = _("Cover cache cleared."), timeout = 2 })
                self:refresh()
            end,
        }},
    }
    dialog = ButtonDialog:new{
        title = _("Index actions"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- Run a scan with a dismissable progress dialog (SPEC §7: blocking,
-- progress with percent + file counter + abort).
function NiceBrowser:_runScan(only_new, callback, silent)
    local self_b = self
    if silent then
        -- Auto-update: fast incremental scan without a progress dialog.
        local ok, err = pcall(Indexer.scanLibrary, nil, nil, { only_new = only_new })
        if not ok then
            logger.warn("NiceBrowser: auto-update failed:", err)
            return
        end
        UIManager:show(InfoMessage:new{
            text = T(_("Index updated: %1 books."), tonumber(self_b.store:countBooks()) or 0),
            timeout = 2,
        })
        if callback then callback() end
        self_b:refresh()
        self_b:saveState()
        return
    end
    Trapper:wrap(function()
        local go_on = Trapper:info(_("NiceBrowser: scanning library…\nTap to abort."), false, true)
        local total = Indexer.scanLibrary(nil, function(processed, total_count)
            go_on = Trapper:info(T(_("Indexing %1 / %2"), processed, total_count), true, true)
            if processed % 10 == 0 then
                -- plain info() checks whether the user dismissed (abort)
                go_on = Trapper:info()
            end
            return go_on
        end, { only_new = only_new })
        Trapper:reset()
        local n = tonumber(self_b.store:countBooks()) or 0
        UIManager:show(InfoMessage:new{
            text = T(_("Index updated: %1 books."), n),
            timeout = 3,
        })
        if callback then callback() end
        self_b:refresh()
        self_b:saveState()
    end)
end

local author_check, title_check, global_check

-- Search entry point (SPEC §5): freetext over author and/or title,
-- optionally limited to the current level and its descendants.
function NiceBrowser:onSearch()
    local search_authors = G_reader_settings:nilOrTrue("nicebrowser_search_authors")
    local search_titles = G_reader_settings:nilOrTrue("nicebrowser_search_titles")
    local search_global = G_reader_settings:isTrue("nicebrowser_search_global")

    local dialog
    local function sync_checks()
        G_reader_settings:saveSetting("nicebrowser_search_authors", author_check.checked)
        G_reader_settings:saveSetting("nicebrowser_search_titles", title_check.checked)
        G_reader_settings:saveSetting("nicebrowser_search_global", global_check.checked)
    end
    local function do_search()
        sync_checks()
        local query = dialog:getInputText()
        UIManager:close(dialog)
        self:_runSearch(query, author_check.checked, title_check.checked, global_check.checked)
    end
    dialog = InputDialog:new{
        title = _("Search books"),
        input = "",
        input_hint = _("Author or title"),
        buttons = {{
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Search"),
                is_enter_key = true,
                callback = do_search,
            },
        }},
    }
    author_check = CheckButton:new{
        text = _("Author"),
        checked = search_authors,
        parent = dialog,
    }
    title_check = CheckButton:new{
        text = _("Title"),
        checked = search_titles,
        parent = dialog,
    }
    global_check = CheckButton:new{
        text = _("Whole library"),
        checked = search_global,
        parent = dialog,
    }
    dialog:addWidget(author_check)
    dialog:addWidget(title_check)
    dialog:addWidget(global_check)
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Execute the search and show the flat result list.
function NiceBrowser:_runSearch(query, search_authors, search_titles, search_global)
    if not query or query:gsub("%s", "") == "" then return end
    local all
    if search_global then
        all = self.store:allBooks()
    else
        -- Current level + below: gather books of the current facet/author subtree.
        local facet = (self.tab == "genres" or self.tab == "tags")
            and (self.tab == "genres" and "genre" or "tag") or nil
        if self.level == "facet" and facet then
            all = {}
            for _i, r in ipairs(self.store:authors(facet, self.facet_value, true)) do
                for _i, b in ipairs(self.store:booksForAuthor(r.author, facet, self.facet_value, "filename", true)) do
                    b.authors = r.author
                    all[#all + 1] = { path = b.path, title = b.title, authors = r.author }
                end
            end
        elseif self.level == "authors" and facet then
            all = {}
            for _i, b in ipairs(self.store:booksForAuthor(self.author, facet, self.facet_value, "filename", true)) do
                all[#all + 1] = { path = b.path, title = b.title, authors = self.author }
            end
        elseif self.author then
            all = {}
            for _i, b in ipairs(self.store:booksForAuthor(self.author, nil, nil, "filename", true)) do
                all[#all + 1] = { path = b.path, title = b.title, authors = self.author }
            end
        else
            all = self.store:allBooks()
        end
    end
    local matched = Search.filter(all, query, {
        search_authors = search_authors,
        search_titles = search_titles,
    })

    local books = {}
    for _i, m in ipairs(matched) do
        books[#books + 1] = {
            title = m.title, path = m.path, filepath = m.path,
            read_status = m.read_status,
            cover_file = CoverCache.getPath(m.path),
        }
    end

    if self.menu then
        UIManager:close(self.menu)
        self.menu = nil
    end
    if self.cover_list then
        UIManager:close(self.cover_list)
        self.cover_list = nil
    end

    local self_b = self
    local CoverList = require("listview")
    local list = CoverList:new{
        books = books,
        rows_per_page = self:_booksPerPage(),
        jump_pages = self:_jumpPages(),
        title = T(_("Search: %1 (%2)"), query, #books),
        on_open_callback = function(book)
            self_b:openBook(book)
        end,
        close_callback = function()
            self_b.cover_list = nil
            self_b:_showMenu()
        end,
    }
    self.cover_list = list
    UIManager:show(list)
end

-- Config helpers ------------------------------------------------------------

function NiceBrowser:_booksPerPage()
    return tonumber(G_reader_settings:readSetting("nicebrowser_books_per_page")) or 4
end

function NiceBrowser:_jumpPages()
    return tonumber(G_reader_settings:readSetting("nicebrowser_jump_pages")) or 5
end

function NiceBrowser:_authorsPerPage()
    return tonumber(G_reader_settings:readSetting("nicebrowser_authors_per_page")) or 10
end

-- Books level: the cover list (listview).
function NiceBrowser:_openBooksLevel()
    local facet = (self.tab == "genres" or self.tab == "tags")
        and (self.tab == "genres" and "genre" or "tag") or nil
    local items = self:_buildBooksItems(facet, self.facet_value, self.author)
    local books = {}
    for _i, it in ipairs(items) do
        books[#books + 1] = it.book
    end

    if self.menu then
        UIManager:close(self.menu)
        self.menu = nil
    end

    local self_b = self
    local CoverList = require("listview")
    local list = CoverList:new{
        books = books,
        rows_per_page = self:_booksPerPage(),
        jump_pages = self:_jumpPages(),
        title = self:_getTitle(),
        initial_page = self.page,
        on_open_callback = function(book)
            self_b:openBook(book)
        end,
        on_page_callback = function(page)
            self_b.page = page
            self_b:saveState()
        end,
        close_callback = function()
            -- Return to the parent level (author/facet) when the list closes.
            self_b.cover_list = nil
            self_b.page = 1
            self_b.level = (self_b.tab == "authors") and "facet" or "authors"
            self_b.author = nil
            self_b:_showMenu()
            self_b:saveState()
        end,
    }
    self.cover_list = list
    UIManager:show(list)
end

-- Rebuild + redraw the underlying Menu widget (facet/author levels only).
function NiceBrowser:refresh()
    if self.level == "books" then
        -- Book level is rendered by CoverList; close the text menu if open.
        if self.menu then
            UIManager:close(self.menu)
            self.menu = nil
        end
        if not self.cover_list then
            self:_openBooksLevel()
        end
        return
    end
    if self.cover_list then
        UIManager:close(self.cover_list)
        self.cover_list = nil
    end
    if self.menu then
        self.menu:switchItemTable(self:_getTitle(), self:_fullItemTable())
        UIManager:setDirty(self.menu, "ui")
    end
end

-- Show the browser as a fullscreen dialog.
function NiceBrowser:show()
    local n = tonumber(self.store:countBooks()) or 0
    if n == 0 then
        -- SPEC §7: hint view on empty/missing library.
        local self_b = self
        UIManager:show(ConfirmBox:new{
            text = _("The library index is empty.\nScan the library folder now?"),
            ok_text = _("Scan"),
            cancel_text = _("Not now"),
            ok_callback = function()
                self_b:_runScan(false, function()
                    self_b:_showMenu()
                end)
            end,
            cancel_callback = function()
                self_b:_showMenu()
            end,
        })
        return
    end
    if G_reader_settings:isTrue("nicebrowser_restore_position") then
        self:restoreState()
        self:_applyRestore()
        return
    end
    self:_showMenu()
end

-- Rebuild the view after restoring state.
function NiceBrowser:_applyRestore()
    if self.level == "books" then
        self:_openBooksLevel()
    else
        self:_showMenu()
    end
end

-- Compose the item table: tab row on top, then the level items.
function NiceBrowser:_fullItemTable()
    local items = self:_tabItems()
    local level_items = self:_buildItemTable()
    for _i, it in ipairs(level_items) do
        items[#items + 1] = it
    end
    return items
end

-- Show the tabbed Menu (facet/author levels).
function NiceBrowser:_showMenu()
    if self.cover_list then
        UIManager:close(self.cover_list)
        self.cover_list = nil
    end
    if self.menu then
        UIManager:close(self.menu)
        self.menu = nil
    end

    local self_b = self
    local item_table = self:_fullItemTable()
    local titlebar = NbTitleBar:new{
        title = self:_getTitle(),
        show_parent = nil, -- set below once menu exists
        left_icons = {
            { icon = "home", callback = function() self_b:onHome() end },
            { icon = "back.top", callback = function() self_b:onUp() end },
            { icon = "appbar.search", callback = function() self_b:onSearch() end },
        },
        right_icons = {
            { icon = "move.up", callback = function() self_b:onToggleSort() end,
              hold_callback = function() self_b:onToggleSort() end },
            { icon = "appbar.tools", callback = function() self_b:onIndexMenu() end },
            { icon = "appbar.menu", callback = function() self_b:onReaderMenu() end },
            { icon = "close", callback = function()
                if self_b.menu then
                    UIManager:close(self_b.menu)
                    self_b.menu = nil
                end
            end },
        },
    }
    local MenuWidget = Menu:new{
        title = self:_getTitle(),
        item_table = item_table,
        custom_title_bar = titlebar,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuSelect = function(menu, item)
            if item.is_tab then
                self_b:onTab(item.tab_key)
            else
                self_b:_onMenuSelect(menu, item)
            end
        end,
    }
    titlebar.show_parent = MenuWidget
    self.menu = MenuWidget
    UIManager:show(MenuWidget)

    -- SPEC §7: automatic incremental update (default off).
    if G_reader_settings:isTrue("nicebrowser_auto_update")
        and (tonumber(self.store:countBooks()) or 0) > 0 then
        local self_b = self
        UIManager:nextTick(function()
            self_b:_runScan(true, nil, true)
        end)
    end
end

-- Open the standard KOReader menu (FileManager context) if available.
function NiceBrowser:onReaderMenu()
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance and FileManager.instance.menu then
        FileManager.instance.menu:onMenuShow()
    else
        UIManager:show(InfoMessage:new{
            text = _("The KOReader menu is only available in the library context."),
            timeout = 2,
        })
    end
end

-- Open a book via the KOReader Document API (bridged from main).
function NiceBrowser:openBook(book)
    if not book or not book.path then return end
    -- Drop the cached progress so the row reflects reading done in the
    -- meantime (session cache, see bookview).
    require("bookview").invalidateProgress(book.path)
    if self.on_open_book then
        self.on_open_book(book.path)
    end
end

-- Global (whole-library) freetext search over Author + Title (kept for
-- programmatic use; the UI entry point is onSearch()).
function NiceBrowser:onSearchQuery(query)
    if not query or query:gsub("%s", "") == "" then return end
    local all = self.store:allBooks()
    local opts = {
        search_authors = G_reader_settings:nilOrTrue("nicebrowser_search_authors"),
        search_titles = G_reader_settings:nilOrTrue("nicebrowser_search_titles"),
    }
    return Search.filter(all, query, opts)
end

return NiceBrowser
