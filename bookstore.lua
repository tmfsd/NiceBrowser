--[[--
NiceBrowser SQLite data layer.

Schema for the library index:
- books: one row per indexed EPUB, with Calibre metadata fields.
- book_authors / book_genres / book_tags: many-to-many facet tables so a
  book can appear under every author/genre/tag it belongs to.

@module nicebrowser.bookstore
--]]--

local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")

local DB_VERSION = 1000

local SCHEMA = [[
    CREATE TABLE IF NOT EXISTS books (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        path        TEXT NOT NULL UNIQUE,
        filename    TEXT NOT NULL,
        filesize    INTEGER,
        filemtime   INTEGER,
        uuid        TEXT,
        fingerprint TEXT,
        title       TEXT,
        series      TEXT,
        series_index REAL,
        subseries   TEXT,
        subseries_index REAL,
        year        INTEGER,
        pages       INTEGER,
        read_status INTEGER DEFAULT 0,
        has_cover   INTEGER DEFAULT 0,
        cover_path  TEXT
    );

    CREATE TABLE IF NOT EXISTS book_authors (
        book_id  INTEGER NOT NULL,
        author   TEXT NOT NULL,
        sort_name TEXT NOT NULL,
        ordering INTEGER NOT NULL,
        PRIMARY KEY (book_id, author)
    );

    CREATE TABLE IF NOT EXISTS book_genres (
        book_id INTEGER NOT NULL,
        genre   TEXT NOT NULL,
        PRIMARY KEY (book_id, genre)
    );

    CREATE TABLE IF NOT EXISTS book_tags (
        book_id INTEGER NOT NULL,
        tag     TEXT NOT NULL,
        PRIMARY KEY (book_id, tag)
    );

    CREATE INDEX IF NOT EXISTS idx_books_path ON books(path);
    CREATE INDEX IF NOT EXISTS idx_books_title ON books(title);
    CREATE INDEX IF NOT EXISTS idx_books_series ON books(series);
    CREATE INDEX IF NOT EXISTS idx_ba_sort ON book_authors(sort_name);
    CREATE INDEX IF NOT EXISTS idx_ba_author ON book_authors(author);
    CREATE INDEX IF NOT EXISTS idx_bg_genre ON book_genres(genre);
    CREATE INDEX IF NOT EXISTS idx_bt_tag ON book_tags(tag);
]]

local BookStore = {
    path = nil,
    db = nil,
}

-- Reading status constants (SPEC §2). Derived from the Calibre `#read`
-- flag; READING is reserved for a future progress-derived state.
BookStore.READ_UNSET = 0
BookStore.READ_READING = 1
BookStore.READ_FINISHED = 2

function BookStore:new(o)
    o = o or {}
    o.path = DataStorage:getSettingsDir() .. "/nicebrowser_index.sqlite3"
    setmetatable(o, self)
    self.__index = self
    return o
end

function BookStore:connect()
    if self.db then return self.db end
    local dir = self.path:match("^(.*)/[^/]*$")
    if dir then
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(dir, "mode") ~= "directory" then
            lfs.mkdir(dir)
        end
    end
    local db = SQ3.open(self.path)
    db:exec("PRAGMA journal_mode=WAL;")
    db:exec("PRAGMA synchronous=NORMAL;")
    db:exec(SCHEMA)
    local v = db:rowexec("PRAGMA user_version;")
    if not v or tonumber(v) < DB_VERSION then
        db:exec(string.format("PRAGMA user_version=%d;", DB_VERSION))
    end
    self.db = db
    return db
end

function BookStore:close()
    if self.db then
        self.db:close()
        self.db = nil
    end
end

function BookStore:begin()
    self:connect():exec("BEGIN")
end

function BookStore:commit()
    if self.db then
        self.db:exec("COMMIT")
    end
end

function BookStore:rollback()
    if self.db then
        self.db:exec("ROLLBACK")
    end
end

-- Insert or update a book and its facets within the current batch.
function BookStore:upsertBook(book)
    local db = self:connect()

    local upsert = db:prepare([[INSERT OR REPLACE INTO books
        (path, filename, filesize, filemtime, uuid, fingerprint, title, series,
         series_index, subseries, subseries_index, year, pages, read_status,
         has_cover, cover_path)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);]])
    upsert:reset():bind(book.path, book.filename, book.filesize, book.filemtime,
        book.uuid, book.fingerprint, book.title, book.series, book.series_index,
        book.subseries, book.subseries_index, book.year, book.pages,
        book.read_status, book.has_cover, book.cover_path):step()
    upsert:close()

    local sel = db:prepare("SELECT id FROM books WHERE path = ?;")
    local row = sel:reset():bind(book.path):step()
    if not row then
        sel:close()
        logger.warn("BookStore: could not resolve book id for", book.path)
        return
    end
    local id = tonumber(row[1])
    sel:close()

    local da = db:prepare("DELETE FROM book_authors WHERE book_id = ?;")
    local dg = db:prepare("DELETE FROM book_genres WHERE book_id = ?;")
    local dt = db:prepare("DELETE FROM book_tags WHERE book_id = ?;")
    da:reset():bind(id):step()
    dg:reset():bind(id):step()
    dt:reset():bind(id):step()
    da:close(); dg:close(); dt:close()

    local a = db:prepare("INSERT OR REPLACE INTO book_authors (book_id, author, sort_name, ordering) VALUES (?, ?, ?, ?);")
    for i, name in ipairs(book.authors or {}) do
        a:reset():bind(id, name, book.sort_names and book.sort_names[i] or name, i):step()
    end
    a:close()
    local g = db:prepare("INSERT OR REPLACE INTO book_genres (book_id, genre) VALUES (?, ?);")
    for _i, genre in ipairs(book.genres or {}) do
        g:reset():bind(id, genre):step()
    end
    g:close()
    local t = db:prepare("INSERT OR REPLACE INTO book_tags (book_id, tag) VALUES (?, ?);")
    for _i, tag in ipairs(book.tags or {}) do
        t:reset():bind(id, tag):step()
    end
    t:close()
end

function BookStore:removeBook(path)
    local db = self:connect()
    local stmt = db:prepare("SELECT id FROM books WHERE path = ?;")
    local row = stmt:reset():bind(path):step()
    if not row then stmt:close() return end
    local id = tonumber(row[1])
    stmt:close()
    local da = db:prepare("DELETE FROM book_authors WHERE book_id = ?;")
    local dg = db:prepare("DELETE FROM book_genres WHERE book_id = ?;")
    local dt = db:prepare("DELETE FROM book_tags WHERE book_id = ?;")
    local dbdel = db:prepare("DELETE FROM books WHERE id = ?;")
    da:reset():bind(id):step()
    dg:reset():bind(id):step()
    dt:reset():bind(id):step()
    dbdel:reset():bind(id):step()
    da:close(); dg:close(); dt:close(); dbdel:close()
end

function BookStore:getIdentity(path)
    local db = self:connect()
    local stmt = db:prepare("SELECT uuid, fingerprint, filesize, filemtime FROM books WHERE path = ?;")
    local row = stmt:reset():bind(path):step()
    stmt:close()
    if not row then return nil end
    return { uuid = row[1], fingerprint = row[2], filesize = tonumber(row[3]), filemtime = tonumber(row[4]) }
end

function BookStore:getPathByUuid(uuid)
    if not uuid then return nil end
    local db = self:connect()
    local stmt = db:prepare("SELECT path FROM books WHERE uuid = ? LIMIT 1;")
    local row = stmt:reset():bind(uuid):step()
    stmt:close()
    if not row then return nil end
    return row[1]
end

function BookStore:countBooks()
    local db = self:connect()
    -- rowexec returns the first column value (int64 cdata for COUNT).
    local n = db:rowexec("SELECT COUNT(*) FROM books;")
    return n and tonumber(n) or 0
end

-- All books with per-book authors (for global search / flat lists).
-- Returns rows of { path, title, read_status, author_names (space-joined) }.
function BookStore:allBooks()
    local db = self:connect()
    local out = {}
    local stmt = db:prepare([[
        SELECT b.path, b.title, b.read_status,
            (SELECT group_concat(ba.author, ' ') FROM book_authors ba WHERE ba.book_id = b.id)
        FROM books b;
    ]])
    for row in stmt:rows() do
        out[#out + 1] = {
            path = row[1], title = row[2],
            read_status = tonumber(row[3]) or self.READ_UNSET,
            authors = row[4] or "",
        }
    end
    stmt:close()
    return out
end

-- List distinct authors with book counts.
-- Optionally filter to books within a facet:
--   facet = "genre"|"tag"|nil, facet_value = string
function BookStore:authors(facet, facet_value, asc)
    local db = self:connect()
    local sql
    local params = {}
    if facet and facet_value then
        local ftab = facet == "genre" and "book_genres" or "book_tags"
        local fcol = facet == "genre" and "genre" or "tag"
        sql = string.format([[
            SELECT ba.author, ba.sort_name, COUNT(DISTINCT bs.id) AS cnt
            FROM book_authors ba
            JOIN books bs ON bs.id = ba.book_id
            JOIN %s f ON f.book_id = bs.id AND f.%s = ?
            GROUP BY ba.author
            ORDER BY ba.sort_name %s;
        ]], ftab, fcol, asc and "ASC" or "DESC")
        params = { facet_value }
    else
        sql = string.format([[
            SELECT ba.author, ba.sort_name, COUNT(DISTINCT bs.id) AS cnt
            FROM book_authors ba
            JOIN books bs ON bs.id = ba.book_id
            GROUP BY ba.author
            ORDER BY ba.sort_name %s;
        ]], asc and "ASC" or "DESC")
    end
    local out = {}
    local stmt = db:prepare(sql)
    if params[1] then
        stmt:bind(params[1])
    end
    for row in stmt:rows() do
        out[#out + 1] = {
            author = row[1],
            sort_name = row[2],
            count = tonumber(row[3]) or 0,
        }
    end
    stmt:close()
    return out
end

-- List distinct facet values (genres or tags) with book counts.
function BookStore:facetValues(facet, asc)
    local db = self:connect()
    local ftab = facet == "genre" and "book_genres" or "book_tags"
    local fcol = facet == "genre" and "genre" or "tag"
    local sql = string.format([[
        SELECT f.%s, COUNT(*)
        FROM %s f
        GROUP BY f.%s
        ORDER BY f.%s %s;
    ]], fcol, ftab, fcol, fcol, asc and "ASC" or "DESC")
    local out = {}
    local stmt = db:prepare(sql)
    for row in stmt:rows() do
        out[#out + 1] = { value = row[1], count = tonumber(row[2]) or 0 }
    end
    stmt:close()
    return out
end

-- Books of an author (optionally within an author + facet).
-- Returns rows of { title, series, series_index, subseries, subseries_index,
--   year, pages, path, has_cover, read_status }
function BookStore:booksForAuthor(author, facet, facet_value, sort_by, asc)
    local db = self:connect()
    local order_col = (sort_by == "year") and "bs.year" or "bs.filename"
    local sql = string.format([[
        SELECT bs.title, bs.series, bs.series_index, bs.subseries, bs.subseries_index,
               bs.year, bs.pages, bs.path, bs.has_cover, bs.read_status
        FROM books bs
        JOIN book_authors ba ON ba.book_id = bs.id
        WHERE ba.author = ?
    ]])
    local params = { author }
    if facet and facet_value then
        local ftab = facet == "genre" and "book_genres" or "book_tags"
        local fcol = facet == "genre" and "genre" or "tag"
        sql = sql .. string.format([[
            AND EXISTS (SELECT 1 FROM %s f WHERE f.book_id = bs.id AND f.%s = ?)
        ]], ftab, fcol)
        params[#params + 1] = facet_value
    end
    sql = sql .. string.format(" ORDER BY %s %s;", order_col, asc and "ASC" or "DESC")
    local out = {}
    local stmt = db:prepare(sql)
    stmt:bind(table.unpack(params))
    for row in stmt:rows() do
        out[#out + 1] = {
            title = row[1], series = row[2], series_index = tonumber(row[3]),
            subseries = row[4], subseries_index = tonumber(row[5]),
            year = tonumber(row[6]), pages = tonumber(row[7]), path = row[8],
            has_cover = tonumber(row[9]) or 0,
            read_status = tonumber(row[10]) or self.READ_UNSET,
        }
    end
    stmt:close()
    return out
end

function BookStore:allPaths()
    local db = self:connect()
    local out = {}
    local stmt = db:prepare("SELECT path FROM books;")
    for row in stmt:rows() do
        out[#out + 1] = row[1]
    end
    stmt:close()
    return out
end

return BookStore