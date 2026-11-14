--[[--
NiceBrowser top bar (SPEC §3): Home · Up · Search · Sort · Index actions ·
KOReader menu · Close, around a centered breadcrumb title.

Implements the interface KOReader's Menu expects from a custom_title_bar:
getHeight(), setTitle(), setSubTitle(), generateVerticalLayout().

@module nicebrowser.nbtitlebar
--]]--

local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconButton = require("ui/widget/iconbutton")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local NbTitleBar = FrameContainer:extend{
    title = "",
    show_parent = nil,
    left_icons = {},   -- array of { icon = "home", callback = fn, hold_callback = fn }
    right_icons = {},  -- ditto, laid out from the right edge
    icon_size = Screen:scaleBySize(40),
    icon_margin_lr = Screen:scaleBySize(14),
    icon_padding_top = Screen:scaleBySize(2),
    icon_padding_bottom = Screen:scaleBySize(2),
    bordersize = 0,
    padding = 0,
    margin = 0,
}

function NbTitleBar:init()
    self.width = Screen:getWidth()
    self.titlebar_height = self.icon_size + self.icon_padding_top + self.icon_padding_bottom
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.titlebar_height }
    self.icon_total_width = self.icon_size + self.icon_margin_lr

    local function make_button(spec)
        return IconButton:new{
            icon = spec.icon,
            width = self.icon_size,
            height = self.icon_size,
            padding = 0,
            padding_bottom = self.icon_padding_bottom,
            padding_top = self.icon_padding_top,
            callback = spec.callback,
            hold_callback = spec.hold_callback,
            show_parent = self.show_parent,
        }
    end

    local left_group = HorizontalGroup:new{}
    local left_w = 0
    for i, spec in ipairs(self.left_icons) do
        local b = make_button(spec)
        left_group[#left_group + 1] = b
        left_w = left_w + self.icon_total_width
    end

    local right_group = HorizontalGroup:new{}
    local right_w = 0
    for i, spec in ipairs(self.right_icons) do
        local b = make_button(spec)
        right_group[#right_group + 1] = b
        right_w = right_w + self.icon_total_width
    end

    -- Breadcrumb title, centered and single-line (truncated with max_width).
    local title_max = math.max(50, self.width - left_w - right_w)
    self._title_max = title_max
    self._title_w = TextWidget:new{
        text = self.title or "",
        face = Font:getFace("cfont", 20),
        max_width = title_max,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local title_box = CenterContainer:new{
        dimen = Geom:new{ w = title_max, h = self.titlebar_height },
        self._title_w,
    }

    self[1] = HorizontalGroup:new{
        HorizontalSpan:new{ width = Screen:scaleBySize(4) },
        left_group,
        title_box,
        right_group,
        HorizontalSpan:new{ width = Screen:scaleBySize(4) },
    }
end

function NbTitleBar:getHeight()
    return self.titlebar_height
end

function NbTitleBar:setTitle(title, no_refresh)
    self.title = title or ""
    local new_w = TextWidget:new{
        text = self.title,
        face = Font:getFace("cfont", 20),
        max_width = self._title_max,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    -- Replace the title widget inside the CenterContainer.
    local title_box = self[1][3]
    title_box[1] = new_w
    self._title_w:free()
    self._title_w = new_w
    if not no_refresh then
        UIManager:setDirty(self.show_parent, "ui", self.dimen)
    end
end

function NbTitleBar:setSubTitle(subtitle, no_refresh)
    -- No subtitle in NiceBrowser's breadcrumb (single-level title).
end

function NbTitleBar:generateVerticalLayout()
    -- Skip focus-navigation integration (tap-first UI).
    return {}
end

return NbTitleBar
