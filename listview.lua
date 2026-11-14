--[[--
NiceBrowser cover list container.

A dedicated, paginated list for the book level: renders a configurable number
of book rows (SPEC §4: books 4–5 per page) using `bookview.renderRow`, with:
- page navigation (hardware keys, horizontal swipes, and 1/x-page buttons),
- a title bar (breadcrumb + close), a combined bottom status bar (SPEC §3),
- an optional A–Z register on the right (SPEC §5),
- tap / double-tap to open.

It reuses KOReader widget primitives (InputContainer, GestureRange) to stay
consistent with the framework.

@module nicebrowser.listview
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Font = require("ui/font")
local BookView = require("bookview")
local Search = require("search")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

-- NOTE: Blitbuffer.gray(level) expects DARKNESS (0 = white, 1 = black).
local BAR_BG = Blitbuffer.gray(1 - 0xF2 / 255)
local BAR_FG = Blitbuffer.COLOR_BLACK
local BTN_BG = Blitbuffer.gray(1 - 0xE4 / 255)
local CONTENT_BG = Blitbuffer.COLOR_WHITE

local CoverList = InputContainer:extend{
    align = "left",
    vertical_align = "top",
    -- Config
    rows_per_page = 4,          -- SPEC §4 default: 4–5 books/page
    jump_pages = 5,             -- x-page jump (SPEC nav)
    books = {},                 -- array of book records
    title = nil,                -- breadcrumb title (current level)
    initial_page = 1,           -- page to restore (SPEC §3)
    on_open_callback = nil,     -- function(book) end
    on_page_callback = nil,     -- function(page) end (persist page)
    close_callback = nil,       -- function() end
}

function CoverList:_init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.page = self.initial_page or 1
    self.doubletap_open = G_reader_settings:isTrue("nicebrowser_doubletap_open")
    self.az_enabled = G_reader_settings:nilOrTrue("nicebrowser_az_register")
    self.show_bars = G_reader_settings:nilOrTrue("nicebrowser_show_ui_bars")
    self.reduced_effects = G_reader_settings:isTrue("nicebrowser_reduced_effects")
    self:_buildLayout()
    self:_buildGestureMaps()
    self:_buildKeyMaps()
    self:_renderPage()
end

-- Split book list into pages (store start index + count per page).
function CoverList:_buildLayout()
    self.pages = {}
    local perpage = math.max(1, self.rows_per_page or 1)
    local n = #self.books
    for i = 1, n, perpage do
        self.pages[#self.pages + 1] = { start = i, count = math.min(perpage, n - i + 1) }
    end
    if #self.pages == 0 then
        self.pages[1] = { start = 1, count = 0 }
    end
    self.max_page = #self.pages
    if self.page > self.max_page then self.page = self.max_page end
    if self.page < 1 then self.page = 1 end
end

-- Gesture maps: horizontal swipes page; tap / double-tap opens.
function CoverList:_buildGestureMaps()
    self.ges_events = {}
    local w, h = self.dimen.w, self.dimen.h
    self.ges_events.swipe = {
        GestureRange:new{ ges = "swipe", range = Geom:new{ x = 0, y = 0, w = w, h = h } },
    }
    if self.doubletap_open then
        self.ges_events.double_tap = {
            GestureRange:new{ ges = "double_tap", range = Geom:new{ x = 0, y = 0, w = w, h = h } },
        }
    else
        self.ges_events.tap = {
            GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = w, h = h } },
        }
    end
end

-- Hardware keys: 1-page turns and Back to close.
function CoverList:_buildKeyMaps()
    self.key_events = {}
    if Device:hasKeys() then
        self.key_events.PrevPage = { { "Left" }, { "PgBack" } }
        self.key_events.NextPage = { { "Right" }, { "PgFwd" } }
        self.key_events.Back = { { "Back" } }
    end
end

function CoverList:onSwipe(arg, ges)
    if ges.direction == "east" then
        self:prevPage()
    elseif ges.direction == "west" then
        self:nextPage()
    end
    return true
end

function CoverList:onPrevPage() self:prevPage(1) end
function CoverList:onNextPage() self:nextPage(1) end
function CoverList:onBack()
    self:onClose()
end

function CoverList:onClose()
    UIManager:close(self)
    if self.close_callback then self.close_callback() end
    return true
end

function CoverList:pageBooks()
    local p = self.pages[self.page] or { start = 1, count = 0 }
    local first = p.start
    local last = math.min(first + p.count - 1, #self.books)
    local out = {}
    for i = first, last do
        out[#out + 1] = self.books[i]
    end
    return out
end

function CoverList:prevPage(jump)
    jump = jump or 1
    local target = math.max(1, self.page - jump)
    if target ~= self.page then
        self.page = target
        self:_renderPage()
        if self.on_page_callback then self.on_page_callback(self.page) end
    end
end

function CoverList:nextPage(jump)
    jump = jump or 1
    local target = math.min(self.max_page, self.page + jump)
    if target ~= self.page then
        self.page = target
        self:_renderPage()
        if self.on_page_callback then self.on_page_callback(self.page) end
    end
end

-- Jump to the first page containing a book of the given A–Z group letter.
function CoverList:jumpToLetter(letter)
    local idx = Search.jumpToLetter(self.books, letter, function(b) return b.title or "" end)
    local perpage = math.max(1, self.rows_per_page or 1)
    local target = math.floor((idx - 1) / perpage) + 1
    if target ~= self.page then
        self.page = target
        self:_renderPage()
        if self.on_page_callback then self.on_page_callback(self.page) end
    end
end

-- Compute bar heights and row geometry.
function CoverList:_computeHeights()
    local h = self.dimen.h
    self.top_bar_h = self.show_bars and Screen:scaleBySize(36) or 0
    self.bottom_bar_h = self.show_bars and Screen:scaleBySize(44) or 0
    self.content_top = self.top_bar_h
    self.content_h = h - self.top_bar_h - self.bottom_bar_h
    local perpage = math.max(1, self.rows_per_page or 1)
    self.row_height = math.max(1, math.floor(self.content_h / perpage))
    self.az_width = self.az_enabled and Screen:scaleBySize(28) or 0
end

-- Render the title bar (breadcrumb + close button).
function CoverList:_buildTopBar()
    local btn_w = self.top_bar_h
    local close = FrameContainer:new{
        width = btn_w, height = btn_w, bordersize = 0, padding = 0,
        background = BAR_BG,
        TextWidget:new{ text = "✕", face = Font:getFace("cfont", 20), fgcolor = BAR_FG },
    }
    -- Tap zone for the close button (top-left corner).
    self._close_rect = { x0 = 0, x1 = btn_w, y0 = 0, y1 = btn_w }

    local title = TextBoxWidget:new{
        text = self.title or "",
        width = self.dimen.w - 2 * btn_w,
        face = Font:getFace("cfont", 18),
        fgcolor = BAR_FG,
        bgcolor = BAR_BG,
        max_lines = 1,
        alignment = "center",
    }
    return FrameContainer:new{
        width = self.dimen.w, height = self.top_bar_h,
        bordersize = 0, padding = 0, background = BAR_BG,
        HorizontalGroup:new{
            close,
            title,
            HorizontalSpan:new{ width = btn_w },
        },
    }
end

-- Render the bottom status bar: pagination buttons + page info (SPEC §3).
function CoverList:_buildBottomBar()
    local btn_w = Screen:scaleBySize(52)
    local btn_h = self.bottom_bar_h - Screen:scaleBySize(8)
    local function button(glyph, action)
        return FrameContainer:new{
            width = btn_w, height = btn_h, bordersize = 0,
            padding = 0, margin = 0, radius = 4,
            background = BTN_BG,
            TextWidget:new{ text = glyph, face = Font:getFace("cfont", 18), fgcolor = BAR_FG },
        }, { w = btn_w, h = btn_h, action = action }
    end

    local jump = self.jump_pages or 5
    local b_back_x, r1 = button("◀◀", function() self:prevPage(jump) end)
    local b_back1, r2 = button("◀", function() self:prevPage(1) end)
    local page_text = T(_("Page %1 of %2"), self.page, self.max_page)
    local page_w_meas = TextWidget:new{ text = page_text, face = Font:getFace("cfont", 16) }
    local page_w = page_w_meas:getWidth()
    page_w_meas:free()
    local page_info = TextWidget:new{
        text = page_text, face = Font:getFace("cfont", 16), fgcolor = BAR_FG,
    }
    local b_fwd1, r4 = button("▶", function() self:nextPage(1) end)
    local b_fwd_x, r5 = button("▶▶", function() self:nextPage(jump) end)

    local gap = Screen:scaleBySize(12)
    local total = r1.w + gap + r2.w + gap + page_w + gap + r4.w + gap + r5.w
    local left = math.floor((self.dimen.w - total) / 2)
    local btn_y0 = self.dimen.h - self.bottom_bar_h + Screen:scaleBySize(4)
    local btn_y1 = btn_y0 + btn_h
    -- Tap zones (bar spans the full screen width).
    self._buttons = {
        { x0 = left, x1 = left + r1.w, y0 = btn_y0, y1 = btn_y1, action = r1.action },
        { x0 = left + r1.w + gap, x1 = left + r1.w + gap + r2.w, y0 = btn_y0, y1 = btn_y1, action = r2.action },
        { x0 = left + r1.w + gap + r2.w + gap + page_w + gap, x1 = left + r1.w + gap + r2.w + gap + page_w + gap + r4.w, y0 = btn_y0, y1 = btn_y1, action = r4.action },
        { x0 = left + r1.w + gap + r2.w + gap + page_w + gap + r4.w + gap, x1 = left + total, y0 = btn_y0, y1 = btn_y1, action = r5.action },
    }

    local group = HorizontalGroup:new{
        HorizontalSpan:new{ width = left },
        b_back_x,
        HorizontalSpan:new{ width = gap },
        b_back1,
        HorizontalSpan:new{ width = gap },
        page_info,
        HorizontalSpan:new{ width = gap },
        b_fwd1,
        HorizontalSpan:new{ width = gap },
        b_fwd_x,
    }
    return FrameContainer:new{
        width = self.dimen.w, height = self.bottom_bar_h,
        bordersize = 0, padding = 0, background = BAR_BG,
        group,
    }
end

-- Render the A–Z register strip on the right edge of the content area.
function CoverList:_buildAzBar()
    if not self.az_enabled or #self.books == 0 then
        self._az_rect = nil
        return nil
    end
    local letters = Search.buildRegister(self.books, function(b) return b.title or "" end)
    self._az_letters = letters
    local strip_h = self.content_h
    local n = #letters
    local row_h = math.max(1, math.floor(strip_h / n))
    local group = VerticalGroup:new{ align = "center" }
    for i, l in ipairs(letters) do
        group[#group + 1] = FrameContainer:new{
            width = self.az_width, height = math.min(row_h, strip_h - (i-1)*row_h),
            bordersize = 0, padding = 0,
            TextWidget:new{
                text = l,
                face = Font:getFace("cfont", l == "★" and 12 or 14),
                fgcolor = BAR_FG,
            },
        }
    end
    self._az_rect = {
        x0 = self.dimen.w - self.az_width, x1 = self.dimen.w,
        y0 = self.top_bar_h, y1 = self.top_bar_h + strip_h,
        row_h = row_h,
    }
    return group
end

-- Render the current page of cover rows.
function CoverList:_renderPage()
    self:_computeHeights()
    local page_books = self:pageBooks()
    local rows = {}
    -- The A–Z strip eats into the row width on the right.
    local text_width = math.floor(self.dimen.w * 0.72) - self.az_width

    for _i, book in ipairs(page_books) do
        local row = BookView.renderRow(book, self.row_height, text_width)
        rows[#rows + 1] = FrameContainer:new{
            height = self.row_height,
            width = self.dimen.w,
            bordersize = 0,
            padding = 0,
            row,
        }
    end

    local rows_group = VerticalGroup:new{ align = "left", unpack(rows) }
    local content
    if self.az_enabled and #page_books > 0 then
        local az = self:_buildAzBar()
        if az then
            -- Rows fill the content area; the A–Z strip overlays the right edge.
            content = OverlapGroup:new{
                dimen = Geom:new{ w = self.dimen.w, h = self.content_h },
                rows_group,
                HorizontalGroup:new{
                    HorizontalSpan:new{ width = self.dimen.w - self.az_width },
                    az,
                },
            }
        end
    end
    if not content then
        content = rows_group
    end

    self[1] = VerticalGroup:new{
        align = "left",
        self.show_bars and self:_buildTopBar() or nil,
        content,
        self.show_bars and self:_buildBottomBar() or nil,
    }
    -- Paint a full-screen background so no stale pixels from previously
    -- displayed widgets remain (rows may not fill the whole content area).
    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        bordersize = 0,
        padding = 0,
        background = CONTENT_BG,
        self[1],
    }
    self._rendered_rows = #page_books
    UIManager:setDirty(self, self.reduced_effects and "partial" or "full")
end

-- Hit-test helpers ----------------------------------------------------------

function CoverList:_hitRect(rect, x, y)
    return rect and x >= rect.x0 and x <= rect.x1 and y >= rect.y0 and y <= rect.y1
end

-- Handle taps: bottom bar buttons, A–Z strip, then row selection.
function CoverList:onTap(arg, ges)
    local x, y = ges.pos.x, ges.pos.y
    if self:_hitRect(self._close_rect, x, y) then
        return self:onClose()
    end
    for _i, btn in ipairs(self._buttons or {}) do
        if self:_hitRect(btn, x, y) then
            btn.action()
            return true
        end
    end
    if self._az_rect and self:_hitRect(self._az_rect, x, y) then
        local n = #self._az_letters
        local idx = math.floor((y - self._az_rect.y0) / self._az_rect.row_h) + 1
        if idx >= 1 and idx <= n then
            self:jumpToLetter(self._az_letters[idx])
        end
        return true
    end
    if y >= self.content_top and y < self.content_top + self.content_h then
        local idx = math.floor((y - self.content_top) / self.row_height) + 1
        local page_books = self:pageBooks()
        if idx >= 1 and idx <= #page_books then
            if self.on_open_callback then
                self.on_open_callback(page_books[idx])
            end
            return true
        end
    end
    return true
end

-- Double-tap opens (SPEC §8: tap/double-tap mode).
CoverList.onDoubleTap = CoverList.onTap

return CoverList
