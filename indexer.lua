--[[--
NiceBrowser library indexer.

Scans the KOReader library folder for EPUB files, extracts Calibre metadata
from each book's OPF (via libarchive), and maintains the SQLite index with an
incremental diff keyed by UUID/fingerprint.

@module nicebrowser.indexer
--]]--

local Archiver = require("ffi/archiver")
local DataStorage = require("datastorage")
local Device = require("device")
local BookStore = require("bookstore")
local CoverCache = require("covercache")
local logger = require("logger")
local util = require("util")

local _ = require("gettext")

local BOOKSTORE = BookStore:new()
local Indexer = {}

-- Regex fragments for common OPF tags (namespace-agnostic).
local function unescape_text(t)
    return util.htmlEntitiesToUtf8(t or "")
end

-- Strip one trailing newline/nesting from a captured text value.
local function clean_text(t)
    if not t then return nil end
    t = t:gsub("^%s+", ""):gsub("%s+$", "")
    if t == "" then return nil end
    return unescape_text(t)
end

-- Derive a sort name from a display name: last space = surname (SPEC §2).
local function derive_sort_name(name)
    if not name then return name end
    local trimmed = name:gsub("^%s+", ""):gsub("%s+$", "")
    local given, surname = trimmed:match("^(.*)%s([^%s]+)$")
    if surname then
        return surname .. ", " .. given
    end
    return trimmed
end

-- Extract text content between two tags (non-greedy, single match).
local function match_tag(text, tagname)
    -- tagname e.g. "dc:title" ; also matches namespaced variants like "dc:title"
    local pat = "<" .. tagname .. "[^>]*>(.-)</" .. tagname .. ">"
    return text:match(pat)
end

-- Extract all text contents of a tag (for multiple occurrences, e.g. subject).
local function match_all_tags(text, tagname)
    local res = {}
    local pat = "<" .. tagname .. "[^>]*>(.-)</" .. tagname .. ">"
    for content in text:gmatch(pat) do
        local c = clean_text(content)
        if c then res[#res + 1] = c end
    end
    return res
end

-- Extract a <meta> ... content="..." /> value by name.
local function match_meta(text, name)
    local pat = '<meta name="' .. name .. '" content="([^"]*)"'
    return text:match(pat)
end

-- Read a single entry from the EPUB archive to memory.
-- We must first enumerate the archive so `Reader` builds its entry table
-- (extractToMemory/seek depend on it).
local function read_zip_entry(filepath, key)
    local arc = Archiver.Reader:new()
    if not arc:open(filepath) then return nil end
    for _ in arc:iterate() do end -- populate the entries table
    local content = arc:extractToMemory(key)
    arc:close()
    return content
end

-- Locate the OPF file path inside the EPUB.
local function find_opf_path(filepath)
    local content = read_zip_entry(filepath, "META-INF/container.xml")
    if content then
        local opf = content:match('rootfile.-full%-path="([^"]+)"')
        if opf then return opf end
    end
    -- Fallback: scan archive entries for a .opf that contains "<package"
    local arc = Archiver.Reader:new()
    if not arc:open(filepath) then return nil end
    local found
    for entry in arc:iterate() do
        if entry.mode == "file" and entry.path:lower():find("%.opf$") then
            local c = arc:extractToMemory(entry.path)
            if c and c:find("<package", 1, true) then
                found = entry.path
                break
            end
        end
    end
    arc:close()
    return found
end

-- Extract the unique identifier (UUID preferred).
local function extract_uuid(opf)
    -- <dc:identifier id="uuid_id" opf:scheme="uuid">VALUE</dc:identifier>
    local best
    local fallback
    for scheme, value in opf:gmatch('<dc:identifier[^>]*opf:scheme="([^"]+)"[^>]*>(.-)</dc:identifier>') do
        if scheme:lower() == "uuid" then
            return clean_text(value)
        end
        if not best then best = clean_text(value) end
        fallback = clean_text(value)
    end
    return best or fallback
end

-- Extract title.
local function extract_title(opf)
    local title = clean_text(match_tag(opf, "dc:title"))
    return title or ""
end

-- Extract all authors (display names, one per dc:creator).
local function extract_authors(opf)
    local authors = {}
    for content in opf:gmatch('<dc:creator[^>]*>(.-)</dc:creator>') do
        local name = clean_text(content)
        if name then authors[#authors + 1] = name end
    end
    return authors
end

-- Extract the metadata JSON value of a custom column (#genre, #pages, #read...)
-- The value is a JSON object whose "#value#" key holds the actual value.
local function extract_custom_column(opf, name)
    local raw = match_meta(opf, "calibre:user_metadata:" .. name)
    if not raw then return nil end
    raw = raw:gsub("&quot;", '"'):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
    -- find "#value#": <value>
    local val = raw:match('"#value#"%s*:%s*"?%s*"([^"]*)"')
    if val then
        if val == "" then return nil end
        return val
    end
    -- bool true/false or number
    val = raw:match('"#value#"%s*:%s*([^,}]+)')
    if val then
        val = val:gsub('^%s+', ""):gsub('%s+$', "")
        if val == "true" then return true end
        if val == "false" then return false end
        return tonumber(val) or val
    end
    return nil
end

-- Extract series + series_index.
local function extract_series(opf)
    local series = clean_text(match_meta(opf, "calibre:series"))
    local index = match_meta(opf, "calibre:series_index")
    if index then index = tonumber(index) end
    if not series then return nil, index end
    return series, index
end

-- Extract subseries + subseries_index from the custom column JSON.
local function extract_subseries(opf)
    local raw = match_meta(opf, "calibre:user_metadata:#subseries")
    if not raw then return nil, nil end
    raw = raw:gsub("&quot;", '"'):gsub("&amp;", "&")
    local name = raw:match('"#value#"%s*:%s*"([^"]*)"')
    local extra = raw:match('"#extra#"%s*:%s*"?%s*"*([%d%.]+)"?')
    if extra then extra = tonumber(extra) end
    return clean_text(name) or nil, extra
end

-- Extract year from dc:date (first 4 digits).
local function extract_year(opf)
    local date = clean_text(match_tag(opf, "dc:date"))
    if not date then return nil end
    local y = date:match("^(%d%d%d%d)")
    if y then return tonumber(y) end
    return nil
end

-- Extract tags (dc:subject, multiple).
local function extract_tags(opf)
    return match_all_tags(opf, "dc:subject")
end

-- Extract the cover path (meta name="cover" content="ID" -> manifest item href).
local function extract_cover_path(opf)
    local cover_id = match_meta(opf, "cover")
    if not cover_id then return nil end
    local escaped = cover_id:gsub("%W", "%%%1")
    -- Manifest items may list id before href, or href before id: handle both.
    local href = opf:match('item[^>]*id="' .. escaped .. '"[^>]*href="([^"]*)"')
        or opf:match('item[^>]*href="([^"]*)"[^>]*id="' .. escaped .. '"')
    return href
end

-- Build the metadata record for a given EPUB path.
-- @return table (book) or nil if the file could not be parsed.
function Indexer.extractBook(filepath)
    local opf_path = find_opf_path(filepath)
    if not opf_path then
        logger.warn("NiceBrowser: no OPF found in", filepath)
        return nil
    end
    local opf = read_zip_entry(filepath, opf_path)
    if not opf then
        logger.warn("NiceBrowser: could not read OPF", opf_path, "from", filepath)
        return nil
    end

    local lfs = require("libs/libkoreader-lfs")
    local attr = lfs.attributes(filepath)
    local filename = filepath:match("([^/]+)$")

    local authors = extract_authors(opf)
    local sort_names = {}
    for i, a in ipairs(authors) do
        sort_names[i] = derive_sort_name(a)
    end

    local series, series_index = extract_series(opf)
    local subseries, subseries_index = extract_subseries(opf)
    local pages = extract_custom_column(opf, "#pages")
    local genre = extract_custom_column(opf, "#genre")
    local read = extract_custom_column(opf, "#read")

    local book = {
        path = filepath,
        filename = filename,
        filesize = attr and attr.size or nil,
        filemtime = attr and attr.modification or nil,
        uuid = extract_uuid(opf),
        fingerprint = nil, -- set by the caller via file identity
        title = extract_title(opf),
        series = series,
        series_index = series_index,
        subseries = subseries,
        subseries_index = subseries_index,
        year = extract_year(opf),
        pages = type(pages) == "number" and pages or nil,
        read_status = read and BookStore.READ_FINISHED or BookStore.READ_UNSET,
        has_cover = 0,
        cover_path = nil,
        authors = authors,
        sort_names = sort_names,
        genres = genre and { genre } or {},
        tags = extract_tags(opf),
    }
    local cover = extract_cover_path(opf)
    if cover then
        -- Decode percent-encoding (e.g. %20) in manifest hrefs.
        cover = cover:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16) or 0) end)
        book.has_cover = 1
        book.cover_path = cover
    end
    return book
end

-- Compute a fingerprint: name + size + mtime (SPEC §7).
local function compute_fingerprint(filepath)
    local lfs = require("libs/libkoreader-lfs")
    local attr = lfs.attributes(filepath)
    local filename = filepath:match("([^/]+)$")
    return (filename or "") .. "|" .. tostring(attr and attr.size or "") .. "|" .. tostring(attr and attr.modification or "")
end

-- Determine the library root: home folder by default.
local function get_library_root()
    return require("apps/filemanager/filemanagerutil").getHomeFolder()
        or Device.home_dir
        or "."
end

-- Should this file be skipped during the scan? (SPEC §2: hidden files,
-- temporary/backup files are filtered; only ePubs are indexed.)
local function is_filtered_file(path, filename)
    if filename:sub(1, 1) == "." then return true end
    local lower = filename:lower()
    if lower:find("^%.") or lower:find("%.tmp$") or lower:find("%.bak$")
        or lower:find("%~$") or lower:find("%.partial$") then
        return true
    end
    return false
end

-- The main scanning entry point. Fills the index incrementally.
-- @param base_dir string Library root. If nil, uses the library root.
-- @param progress_cb function(processed, total) called periodically;
--        returning false from the callback aborts the scan.
-- @param opts table{ only_new = boolean, force = boolean }
-- @return total number of epub files seen, or nil on error (+ err message)
function Indexer.scanLibrary(base_dir, progress_cb, opts)
    opts = opts or {}
    base_dir = base_dir or get_library_root()

    logger.info("NiceBrowser: scanning", base_dir)
    local files = {}
    util.findFiles(base_dir, function(path, name)
        if is_filtered_file(path, name) then return end
        local _, suffix = util.splitFileNameSuffix(path)
        if suffix and suffix:lower() == "epub" then
            files[#files + 1] = path
        end
    end, true, 20000)

    table.sort(files)
    local total = #files
    local processed = 0
    local seen_paths = {}
    local aborted = false

    BOOKSTORE:begin()
    for _i, path in ipairs(files) do
        processed = processed + 1
        seen_paths[path] = true

        local ok, book = pcall(Indexer.extractBook, path)
        if ok and book then
            book.fingerprint = compute_fingerprint(path)

            local known_ok, known = pcall(function() return BOOKSTORE:getIdentity(path) end)
            if known_ok and known then
                -- Same path already indexed: only update if changed
                if (known.filesize == book.filesize and known.filemtime == book.filemtime
                        and known.uuid == book.uuid) then
                    -- unchanged; leave as-is
                else
                    BOOKSTORE:upsertBook(book)
                    if book.has_cover == 1 and book.cover_path then
                        pcall(CoverCache.ensure, path, book.cover_path)
                    end
                end
            else
                -- New path. Check for a rename carrying the same UUID,
                -- and remove the stale old-path row.
                local old_ok, old_path = pcall(function() return BOOKSTORE:getPathByUuid(book.uuid) end)
                if old_ok and old_path and old_path ~= path then
                    BOOKSTORE:removeBook(old_path)
                    pcall(CoverCache.invalidate, old_path)
                end
                BOOKSTORE:upsertBook(book)
                if book.has_cover == 1 and book.cover_path then
                    pcall(CoverCache.ensure, path, book.cover_path)
                end
            end
        elseif not ok then
            logger.warn("NiceBrowser: skipping corrupt epub", path, ":", book)
        end

        -- Batch commit periodically (SPEC §7).
        if processed % 100 == 0 then
            BOOKSTORE:commit()
            BOOKSTORE:begin()
        end
        if progress_cb then
            local go_on = progress_cb(processed, total)
            if go_on == false then
                aborted = true
                break
            end
        end
    end

    -- Remove books whose files no longer exist (unless only_new).
    if not aborted and not opts.only_new then
        local paths_ok, all_paths = pcall(function() return BOOKSTORE:allPaths() end)
        if paths_ok then
            for _i, p in ipairs(all_paths) do
                if not seen_paths[p] then
                    BOOKSTORE:removeBook(p)
                    pcall(CoverCache.invalidate, p)
                end
            end
        end
    end

    BOOKSTORE:commit()
    BOOKSTORE:close()
    if aborted then
        logger.info("NiceBrowser: scan aborted by user at", processed, "/", total)
    else
        logger.info("NiceBrowser: scan complete,", total, "epub files")
    end
    return total
end

return Indexer