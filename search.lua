--[[--
NiceBrowser search support.

Provides the in-memory search index and filtering used by the browser's
Freetext search, plus A–Z register helpers (SPEC §5):
- Fields: Author and Title (checkbox-selectable, OR-combined).
- Scope: current level + descendants, or the whole library (global).
- Result: a flat book list shown as a temporary view.

The search index is built lazily from the book list supplied by the browser;
SQLite already exposes the per-book fields we search on.

@module nicebrowser.search
--]]--

local util = require("util")

local Search = {}

-- Normalise a string for matching (lowercase via UTF-8-aware KOReader, trimmed).
local function norm(s)
    if not s then return "" end
    s = util.stringLower(tostring(s))
    return s:gsub("^%s+", ""):gsub("%s+$", "")
end

-- Whether a string matches a search term (substring, case-insensitive).
local function contains(haystack, needle)
    return needle ~= "" and haystack:find(needle, 1, true) ~= nil
end

-- Filter a book list by a query, searching the given set of field labels.
-- @param books array of { title, author, path, ... }
-- @param query string (trimmed; empty means no filtering)
-- @param opts table{ search_authors = bool, search_titles = bool }
-- @return filtered array (books whose author/title match; OR across chosen fields)
function Search.filter(books, query, opts)
    if not books or #books == 0 then return {} end
    opts = opts or {}
    if not query or query:gsub("%s", "") == "" then
        return books -- no filter
    end

    local q = norm(query:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
    local search_authors = opts.search_authors ~= false
    local search_titles = opts.search_titles ~= false
    if not search_authors and not search_titles then
        return {}
    end

    local out = {}
    for _i, b in ipairs(books) do
        local title_n = norm(b.title or "")
        local author_n = ""
        if search_authors then
            -- b.authors may be a string or an array; handle both.
            if type(b.authors) == "string" then
                author_n = norm(b.authors)
            elseif type(b.authors) == "table" then
                for _i, a in ipairs(b.authors) do
                    author_n = author_n .. " " .. norm(a or "")
                end
            end
        end
        local title_match = search_titles and contains(title_n, q)
        local author_match = search_authors and author_n ~= "" and contains(author_n, q)
        if title_match or author_match then
            out[#out + 1] = b
        end
    end
    return out
end

-- Collect the searchable string of a book (for index-like preloading, if needed).
function Search.normalisedParts(book)
    return norm(book.title or "") .. " " .. norm(
        type(book.authors) == "string" and book.authors
            or (type(book.authors) == "table" and table.concat(book.authors, " ") or ""))
end

-- A–Z register helpers.
-- Return the "group letter" (uppercase ASCII A..Z) of a sortable string.
local LETTER_SET = {}
for i = 65, 90 do LETTER_SET[string.char(i)] = true end -- A..Z

function Search.groupLetter(str)
    if not str then return "★" end
    local c = str:gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 1)
    c = c:upper()
    if LETTER_SET[c] then return c end
    return "★" -- non-letter placeholder group
end

-- Build the A–Z register (ordered list of present letters followed by ★).
function Search.buildRegister(items, get_sort)
    local seen = {}
    local order = {}
    for _i, it in ipairs(items) do
        local letter = Search.groupLetter(get_sort and get_sort(it) or (it and it.text) or it)
        if not seen[letter] then
            seen[letter] = true
            order[#order + 1] = letter
        end
    end
    -- Alphabetical, with ★ (non-letter) moved to the end.
    table.sort(order, function(a, b)
        if a == "★" then return false end
        if b == "★" then return true end
        return a < b
    end)
    return order
end

-- Find the first item index whose group letter is >= the given letter.
function Search.jumpToLetter(items, letter, get_sort)
    for i, it in ipairs(items) do
        local l = Search.groupLetter(get_sort and get_sort(it) or (it and it.text) or it)
        if l >= letter then
            return i
        end
    end
    return 1
end

return Search