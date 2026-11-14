--[[--
NiceBrowser book row widget.

Builds a single library book row as a combined, keep-it-lean widget (SPEC §4):
- Cover left (native aspect ratio, never distorted; light-grey placeholder
  with a line-style icon if absent).
- Metatext right: title (bold/large, 2-line ellipsis), series+volume · subseries,
  year · pages, and a progress bar + status pill.

Also exposes the on-demand reading progress helper (SPEC §2 / §6) that reads
KOReader's docsettings.

@module nicebrowser.bookview
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local DocSettings = require("docsettings")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local BookStore = require("bookstore")
local Theme = require("theme")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local BookView = {}

-- Placeholder / frame colours (SPEC §10: light grey).
-- NOTE: Blitbuffer.gray(level) expects DARKNESS (0 = white, 1 = black), so
-- light greys are expressed as gray(1 - value/255).
local PLACEHOLDER_COLOR = Blitbuffer.gray(1 - 0xEE / 255)
local COVER_FRAME_COLOR = Blitbuffer.gray(1 - 0xDD / 255)
-- Bar background gray (unfilled).
local BAR_BG = Blitbuffer.gray(1 - 0xD0 / 255)

-- Progress bar min/max page thresholds (SPEC §4).
local PAGES_MIN = 100
local PAGES_MAX = 1000

-- Read the reading progress (0..1) for a book from its docsettings.
-- Results are cached per path for the session (avoids re-opening sidecar
-- files on every re-render); call invalidateProgress() when a book opens.
-- Returns a number 0..1 (0 when not started / unavailable).
local progress_cache = {}

function BookView.getProgress(filepath)
    if not filepath then return 0 end
    local cached = progress_cache[filepath]
    if cached then return cached end
    local ok, doc = pcall(DocSettings.open, filepath)
    if not ok or not doc then return 0 end
    local percent = tonumber(doc:readSetting("percent_finished")) or 0
    doc:close()
    if percent < 0 then percent = 0 elseif percent > 1 then percent = 1 end
    progress_cache[filepath] = percent
    return percent
end

-- Drop the cached progress for a book (call before/after reading it).
function BookView.invalidateProgress(filepath)
    if filepath then progress_cache[filepath] = nil end
end

-- Determine the reading status for the pill/badge (SPEC §4).
-- `read_status` (from the Calibre `#read` flag, see BookStore constants)
-- acts as a floor: a book marked read in Calibre shows "Finished" even
-- when no KOReader progress exists.
-- Returns "unread" | "reading" | "finished".
function BookView.getStatusLabel(progress, read_status)
    if read_status == BookStore.READ_FINISHED then
        return "finished"
    elseif not progress or progress <= 0 then
        return "unread"
    elseif progress >= 1 then
        return "finished"
    else
        return "reading"
    end
end

-- Map a page count to a normalised bar length factor within [0.4, 1.0].
local function page_bar_factor(pages)
    if not pages then return 0.6 end
    if pages <= PAGES_MIN then return 0.4 end
    if pages >= PAGES_MAX then return 1.0 end
    return 0.4 + (pages - PAGES_MIN) / (PAGES_MAX - PAGES_MIN) * 0.6
end

-- Font helper. Resolves the theme's bundled face (SourceSerif4 by default,
-- SourceSans3 alternative) with the requested style variant. Falls back to
-- KOReader's built-in faces if a requested face is not available.
local function font(size, bold, italic)
    local base = Theme.baseFace() -- "SourceSerif4" or "SourceSans3"
    local variant = bold and "-Bold" or (italic and "-It" or "-Regular")
    -- 1st choice: themed face with the exact style variant (bundled files).
    local ok, f = pcall(Font.getFace, Font, base .. variant, size)
    if ok and f then return f end
    -- 2nd choice: themed face without variant (style synthesised upstream).
    ok, f = pcall(Font.getFace, Font, base, size)
    if ok and f then return f end
    -- Last resort: KOReader's content font.
    ok, f = pcall(Font.getFace, Font, "cfont", size)
    if ok and f then return f end
    return nil
end

-- Cover widget (left). Native aspect ratio (never distorted, SPEC §10);
-- thin light-grey frame; light-grey placeholder with a line-style icon if absent.
local function cover_widget(book, row_height)
    local cover_w = math.floor(row_height * 0.6)
    local frame_border = math.max(1, (Size.border and Size.border.default) or 1)
    local cover_path = book.cover_file
    local image
    if cover_path and util.pathExists(cover_path) then
        -- scale_factor = 0: best fit into width/height keeping the aspect ratio.
        image = ImageWidget:new{
            file = cover_path,
            width = cover_w,
            height = row_height,
            scale_factor = 0,
        }
    else
        -- Placeholder: light grey area with a simple line-style book glyph.
        local ph_bb = Blitbuffer.new(cover_w, row_height)
        ph_bb:fill(PLACEHOLDER_COLOR)
        local icon_face = font(math.floor(row_height * 0.25))
        local icon = icon_face and TextWidget:new{
            text = "⬚", -- simple line-style placeholder glyph
            face = icon_face,
            fgcolor = Blitbuffer.gray(0xAA / 255),
        } or nil
        if icon then
            image = OverlapGroup:new{
                dimen = { w = cover_w, h = row_height },
                ImageWidget:new{ image = ph_bb, width = cover_w, height = row_height },
                icon,
            }
        else
            image = ImageWidget:new{ image = ph_bb, width = cover_w, height = row_height }
        end
    end
    return FrameContainer:new{
        margin = 0,
        padding = 0,
        bordersize = frame_border,
        border_color = COVER_FRAME_COLOR,
        width = cover_w,
        height = row_height,
        image,
    }
end

-- Build the bottom row: a slim progress bar + the status pill (SPEC §4/§10).
local function buildProgressRow(width, status, progress, pages)
    -- Reserve room for the pill so bar + pill stay inside the metatext column.
    local pill_reserve = Screen:scaleBySize(90)
    local bar_span = math.floor(math.max(0, width - pill_reserve) * page_bar_factor(pages))
    local filled_px = status == "unread" and 0 or math.floor(bar_span * (progress or 0))

    -- Filled colour: 'Finished'/'reading' both use dark (text-colour); Unread stays grey (empty).
    local fill_color = Blitbuffer.COLOR_DARK_GRAY
    if status == "finished" then
        fill_color = Blitbuffer.COLOR_BLACK
    end

    local bar = FrameContainer:new{
        height = 4, bordersize = 0, padding = 0,
        background = BAR_BG,
        width = bar_span,
        HorizontalGroup:new{
            -- The fill frame needs a (zero-size) child: a childless
            -- FrameContainer crashes in getSize() at paint time.
            FrameContainer:new{
                background = fill_color, width = filled_px, height = 4,
                bordersize = 0, padding = 0,
                HorizontalSpan:new{ width = 0, height = 4 },
            },
            HorizontalSpan:new{ width = bar_span - filled_px, height = 4 },
        },
    }

    local text
    if status == "unread" then
        text = _("Unread")
    elseif status == "finished" then
        text = _("Finished")
    else
        text = T(_("%1%"), math.floor((progress or 0) * 100))
    end
    local pill_face = font(14)
    local pill = FrameContainer:new{
        bordersize = 0, padding = 2,
        background = fill_color,
        radius = 2,
        TextBoxWidget:new{
            text = text, face = pill_face, max_lines = 1,
            fgcolor = Blitbuffer.COLOR_WHITE,
            -- TextBoxWidget fills its own background (default white):
            -- match the pill colour so the text stays readable.
            bgcolor = fill_color,
        },
    }

    return HorizontalGroup:new{
        bar,
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        pill,
    }
end

-- Build the right-hand metatext column.
local function metatext_widget(book, status, progress, text_width)
    local title = book.title or book.series or (book.filename or _("(untitled)"))
    -- SPEC §10 default: 2-line title (configurable).
    local max_lines = G_reader_settings:nilOrTrue("nicebrowser_title_two_lines") and 2 or 1

    local title_w = TextBoxWidget:new{
        text = title,
        width = text_width,
        face = font(24, true), -- theme serif, bold variant
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_lines = max_lines,
    }

    local series_parts = {}
    if book.series then
        series_parts[#series_parts + 1] = book.series .. (book.series_index and (" " .. tostring(book.series_index)) or "")
    end
    if book.subseries then
        series_parts[#series_parts + 1] = book.subseries .. (book.subseries_index and (" " .. tostring(book.subseries_index)) or "")
    end
    local series_str = table.concat(series_parts, " · ")

    local detail_parts = {}
    if book.year then detail_parts[#detail_parts + 1] = tostring(book.year) end
    if book.pages then detail_parts[#detail_parts + 1] = tostring(book.pages) .. _(" p.") end
    local detail_str = table.concat(detail_parts, "  ·  ")

    local series_w = series_str ~= "" and TextBoxWidget:new{
        text = series_str, width = text_width, max_lines = 1,
        face = font(20),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    } or HorizontalSpan:new{ width = 0 }

    local detail_w = detail_str ~= "" and TextBoxWidget:new{
        text = detail_str, width = text_width, max_lines = 1,
        face = font(18),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    } or HorizontalSpan:new{ width = 0 }

    local bar_row = buildProgressRow(text_width, status, progress, book.pages)

    return VerticalGroup:new{
        align = "left",
        title_w,
        VerticalSpan:new{ width = Size.span.vertical_default },
        series_w,
        detail_w,
        VerticalSpan:new{ width = Size.span.vertical_default },
        bar_row,
    }
end

-- Assemble a full book row.
-- @param book table: title, series, series_index, subseries, subseries_index,
--   year, pages, filepath (actual EPUB path), cover_file (thumbnail path)
-- @param row_height number pixel row height
-- @param text_width number pixel width of the metatext column
-- @return widget
function BookView.renderRow(book, row_height, text_width)
    local filepath = book.filepath or book.path
    local progress = BookView.getProgress(filepath)
    local status = BookView.getStatusLabel(progress, book.read_status)
    local cover = cover_widget(book, row_height)
    local meta = metatext_widget(book, status, progress, text_width or math.floor(Screen:getWidth() * 0.6))

    return HorizontalGroup:new{
        cover,
        HorizontalSpan:new{ width = Size.span.horizontal_default },
        meta,
    }
end

return BookView
