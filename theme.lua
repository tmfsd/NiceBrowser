--[[--
NiceBrowser theme.

Central theme definition (SPEC §10): minimalist, flat design, own theme.

- Colours: white background, dark text; primary accent #07CAA0, secondary
  accent #FF5C8A (decorative). Configurable colour mode: colour / greyscale /
  B&W, default greyscale (Kaleido-3 friendly: only full-tone, clearly separated
  colours, no subtle gradients).
- Font: SourceSerif4 as the default serif, overridable in settings.

The view widgets read these helpers so the palette stays consistent. In the
default greyscale mode, widgets use KOReader's built-in gray/black colours;
the accent hexes are kept as data so a future colour-mode renderer can use them.

@module nicebrowser.theme
--]]--

local logger = require("logger")

local Theme = {}

-- Palette (RGB hex, per SPEC §10).
Theme.PRIMARY_HEX = "#07CAA0"
Theme.SECONDARY_HEX = "#FF5C8A"
Theme.BACKGROUND_HEX = "#FFFFFF"

-- The active colour mode: "color" | "greyscale" | "bw" (default greyscale).
function Theme.getColorMode()
    return G_reader_settings:readSetting("nicebrowser_color_mode") or "greyscale"
end

-- Whether we may use accent colours at all.
function Theme.usesColor()
    return Theme.getColorMode() == "color"
end

-- The theme's base face (serif or sans variant); overridable by settings.
-- Font style variants are derived as "<base>-Bold" / "<base>-It" / "-Regular".
function Theme.baseFace()
    return G_reader_settings:readSetting("nicebrowser_font_face") or "SourceSerif4"
end

-- The default serif face name (SourceSerif4); overridable by settings.
function Theme.defaultSerifFace()
    return Theme.baseFace()
end

-- Load-time sanity: log the theme config (guarded).
logger.dbg("NiceBrowser: theme module loaded (mode:", Theme.getColorMode(), ")")

return Theme