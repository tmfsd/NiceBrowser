--[[--
NiceBrowser cover cache.

Extracts a book cover from the EPUB, renders a scaled thumbnail and stores it
as a PNG file in the KOReader data dir, so the library view can render covers
quickly without re-opening the book each time.

Covers are rendered natively (high/full format), un-cropped and un-distorted.
When a book has no extractable cover, a light-grey placeholder is drawn by the
view layer (see Theme; Phase 4). This module only exposes the cached cover
search path; it does not own the display logic.

@module nicebrowser.covercache
--]]--

local Archiver = require("ffi/archiver")
local DataStorage = require("datastorage")
local Device = require("device")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local CoverCache = {}

-- Cover thumbnail target height, in pixels (PPI-independent; the view scales on render).
-- Sized for ~2x scaled row heights; keeps thumbnails small but crisp on eInk.
local THUMB_HEIGHT = 720

-- Generate a deterministic cache filename from a book path (so it survives
-- re-indexing without re-deriving, and stays stable across scans).
local function cache_filename_for_path(path)
    local safe = tostring(path)
        :gsub("[^%w%.%-_]", "_")     -- sanitize for the filesystem
    return safe .. ".png"
end

-- Determine the cache directory (one folder for all covers).
function CoverCache.getDir()
    local dir = DataStorage:getSettingsDir() .. "/nicebrowser/covers"
    if lfs.attributes(dir, "mode") ~= "directory" then
        -- Create the full parent chain ("settings" always exists; "nicebrowser" may not).
        local parent = dir:match("^(.*)/[^/]*$")
        if parent and lfs.attributes(parent, "mode") ~= "directory" then
            lfs.mkdir(parent)
        end
        lfs.mkdir(dir)
    end
    return dir
end

-- Full path of a cached cover for a book path (may not exist yet).
function CoverCache.getPath(path)
    local dir = CoverCache.getDir()
    if not path then return nil end
    return dir .. "/" .. cache_filename_for_path(path)
end

-- Convenience: extract a cover entry from an EPUB archive by its entry path.
-- @return string image bytes, or nil
-- NOTE: the archive entries table must be enumerated first (via iterate()),
-- otherwise extractToMemory -> seek() finds nothing (see indexer.read_zip_entry).
local function read_entry_bytes(filepath, entry_path)
    if not entry_path then return nil end
    local arc = Archiver.Reader:new()
    if not arc:open(filepath) then return nil end
    for _ in arc:iterate() do end -- populate the entries table
    local data = arc:extractToMemory(entry_path)
    arc:close()
    return data
end

-- Try to refresh/update the cover regardless of presence of existing file.
-- Returns the cached file path on success, nil otherwise.
-- Call this during indexing (Phase 1 pipeline) or on demand.
-- @param filepath string path of the EPUB
-- @param cover_entry string path of the cover image inside the archive
function CoverCache.ensure(filepath, cover_entry)
    if not filepath or not cover_entry then return nil end

    local dest_file = CoverCache.getPath(filepath)
    if not dest_file then return nil end
    -- Reuse existing cache entry if present (covers are stable per book).
    if lfs.attributes(dest_file, "mode") == "file" then
        return dest_file
    end

    local data = read_entry_bytes(filepath, cover_entry)
    if not data or #data == 0 then
        logger.warn("NiceBrowser: no cover data for", cover_entry, "in", filepath)
        return nil
    end

    -- Get the cover's native size to derive aspect ratio; keep it un-cropped.
    local ok, bb = pcall(function()
        return RenderImage:renderImageData(data, #data, nil)
    end)
    if not ok or not bb then
        logger.warn("NiceBrowser: could not render cover for", filepath)
        return nil
    end

    local nat_w, nat_h = bb:getWidth(), bb:getHeight()
    -- Scale to the target height, preserving the aspect ratio (never distort).
    local target_h = THUMB_HEIGHT
    local target_w = nat_h > 0 and math.floor(nat_w * target_h / nat_h + 0.5) or nat_w

    local scaled = RenderImage:scaleBlitBuffer(bb, target_w, target_h, true)
    local ok_write, wrote, err = pcall(function()
        return scaled:writePNG(dest_file)
    end)
    -- scaleBlitBuffer frees the original bb when it scales; when no scaling
    -- was needed it returns the original bb, which we free ourselves.
    if scaled then scaled:free() end
    if not ok_write or not wrote then
        logger.warn("NiceBrowser: could not write cover thumbnail:", tostring(err or wrote))
        return nil
    end
    logger.dbg("NiceBrowser: wrote cover thumbnail", dest_file)
    return dest_file
end

-- Invalidate (delete) a cached cover (used when a book is removed).
function CoverCache.invalidate(path)
    local p = CoverCache.getPath(path)
    if p and lfs.attributes(p, "mode") == "file" then
        os.remove(p)
    end
end

-- Clear all cached covers.
function CoverCache.clear()
    local dir = CoverCache.getDir()
    for f in lfs.dir(dir) do
        if f:sub(-4) == ".png" then
            os.remove(dir .. "/" .. f)
        end
    end
end

return CoverCache