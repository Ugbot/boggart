-- story/index.lua -- a rebuildable index over a book's markdown.
--
-- The files are the truth; these tables are a cache of them, dropped and
-- rebuilt at will (`story book reindex rebuild=true`). Reindexing is
-- incremental: a file whose (mtime, size) is unchanged is skipped; a changed
-- one is hashed, and only reparsed if the bytes really changed. Derived tables
-- (chapters, characters, mentions, payoffs) are recomputed from the file rows
-- whenever anything changed -- cheap, and never stale.
--
--   sty_books     name, root, manifest, indexed_at
--   sty_files     book, path, kind (chapter|character|canon|outline|payoffs|other), role, mtime, size, hash, words, title
--   sty_fts       full-text (porter) over titles and bodies
--   sty_chapters  book, n, ord, label, variant, path, title, words, done
--   sty_entities  book, id, kind, title, path, aliases (json)
--   sty_mentions  book, entity, n, count
--   sty_payoffs   book, n, title, carrier, span, text
local sb = require("story.book")
local M = {}

local function db() return bog.db end
local function q(sql, p) return db():query(sql, p or {}) or {} end
local function one(sql, p) return q(sql, p)[1] end
local function run(sql, p) return db():run(sql, p or {}) end

M.TABLES = { "sty_books", "sty_files", "sty_fts", "sty_chapters", "sty_entities", "sty_mentions", "sty_payoffs" }

local ready = false
function M.ensure_schema()
  if ready then return true end
  if not (bog and bog.db) then return nil, "store not open" end
  -- The tables are a cache: an older shape is dropped, not migrated.
  local cols = {}
  for _, r in ipairs(q("PRAGMA table_info(sty_chapters)")) do cols[r.name] = true end
  if next(cols) and not cols.longest then run("DROP TABLE sty_chapters") end
  for _, sql in ipairs{
    [[CREATE TABLE IF NOT EXISTS sty_books (name TEXT PRIMARY KEY, root TEXT, manifest TEXT, indexed_at INTEGER)]],
    [[CREATE TABLE IF NOT EXISTS sty_files (book TEXT, path TEXT, kind TEXT, role TEXT, mtime INTEGER, size INTEGER,
        hash TEXT, words INTEGER, title TEXT, PRIMARY KEY (book, path))]],
    [[CREATE VIRTUAL TABLE IF NOT EXISTS sty_fts USING fts5(book UNINDEXED, path UNINDEXED, kind UNINDEXED,
        title, body, tokenize = 'porter unicode61')]],
    [[CREATE TABLE IF NOT EXISTS sty_chapters (book TEXT, n INTEGER, ord INTEGER, label TEXT, variant TEXT,
        path TEXT, variants TEXT, title TEXT, words INTEGER, done INTEGER,
        longest INTEGER, longest_variant TEXT, PRIMARY KEY (book, n))]],
    [[CREATE TABLE IF NOT EXISTS sty_entities (book TEXT, id TEXT, kind TEXT, title TEXT, path TEXT, aliases TEXT,
        PRIMARY KEY (book, id))]],
    [[CREATE TABLE IF NOT EXISTS sty_mentions (book TEXT, entity TEXT, n INTEGER, count INTEGER)]],
    [[CREATE TABLE IF NOT EXISTS sty_payoffs (book TEXT, n INTEGER, title TEXT, carrier TEXT, span TEXT, text TEXT,
        PRIMARY KEY (book, n))]],
  } do run(sql) end
  ready = true
  return true
end

function M.drop_book(name)
  for _, t in ipairs(M.TABLES) do
    local col = (t == "sty_books") and "name" or "book"
    run("DELETE FROM " .. t .. " WHERE " .. col .. " = ?", { name })
  end
end

-- ---- classification --------------------------------------------------------------
-- What each file is to the book, from the manifest.
local function classify(book)
  local kinds = {}
  local function mark(list, kind, role)
    for _, rel in ipairs(list) do if not kinds[rel] then kinds[rel] = { kind = kind, role = role } end end
  end
  local chapters = sb.chapters(book)
  for _, c in ipairs(chapters) do
    for _, rel in pairs(c.variants) do kinds[rel] = { kind = "chapter", role = "manuscript" } end
  end
  mark(sb.glob(book, book.m.characters), "character", "character")
  if book.m.payoffs then mark({ book.m.payoffs }, "payoffs", "payoffs") end
  mark(sb.glob(book, book.m.outline), "outline", "outline")
  -- an explicit path outranks a glob that also matches it (the ledger
  -- 07-truth-knowledge-ledger.md is a ledger, not just another numbered doc)
  for _, c in ipairs(book.m.canon or {}) do
    if c.path then mark(sb.glob(book, { c.path }), "canon", c.role or "canon") end
  end
  for _, c in ipairs(book.m.canon or {}) do
    if c.glob then mark(sb.glob(book, { c.glob }), "canon", c.role or "canon") end
  end
  return kinds, chapters
end

local function title_of(text)
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local t = line:match("^%s*#+%s*(.-)%s*$")
    if t and t ~= "" then return t end
  end
  return ""
end

-- ---- characters and aliases ------------------------------------------------------------
local STOP = { LOCKED = 1, TBD = 1, SEE = 1, COVER = 1, CODENAME = 1, POV = 1, THE = 1, AND = 1, OR = 1,
               ON = 1, A = 1, AN = 1, OF = 1, IN = 1, TO = 1, SHEET = 1, CHARACTER = 1, CONCISE = 1, NOTES = 1,
               -- ranks and honorifics: a title, not a name
               COMMANDER = 1, CAPTAIN = 1, GENERAL = 1, COLONEL = 1, AGENT = 1, LORD = 1, LADY = 1, SIR = 1,
               DOCTOR = 1, DR = 1, MR = 1, MRS = 1, MS = 1, MISS = 1, KING = 1, QUEEN = 1, PRINCE = 1, PRINCESS = 1 }

-- Names a character goes by: the sheet's "**Name:**" line, a trailing
-- parenthetical in its title, and -- for sheets that have neither -- the
-- capitalised words of the title and the file name ("01-daniel-vale" -> Daniel, Vale).
function M.aliases(title, text, rel)
  local out, seen = {}, {}
  local function add(t)
    if #t < 3 or STOP[t:upper()] then return end
    local k = t:lower()
    if not seen[k] then seen[k] = true; out[#out + 1] = t end
  end
  local from_name = false
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local nv = line:match("%*%*Name:%*%*(.+)") or line:match("^%s*%-?%s*Name:%s*(.+)")
    if nv then
      from_name = true
      for seg in (nv .. "/"):gmatch("(.-)/") do
        for t in seg:gmatch("[%u][%u%l]+") do add(t) end
      end
    end
  end
  -- A title's parenthetical is a name only when the sheet gives none: in
  -- ~/novel's sheets it names the author influence ("(Fleming)"), and taking
  -- it as an alias would count Fleming's every mention as Vera's.
  local paren = (not from_name) and title:match("%(([^%)]+)%)%s*$")
  if paren then for t in paren:gmatch("[%u][%u%l]+") do add(t) end end
  if not from_name and not paren then
    -- the name is the title's head: "Daniel Vale — Agent One, principal
    -- viewpoint" names Daniel Vale, not an Agent called One
    -- (dashes as whole strings: a multi-byte dash in a [class] matches bytes)
    local head = title
    for _, dash in ipairs{ "\u{2014}", "\u{2013}", " - ", ":", "," } do
      local at = head:find(dash, 1, true)
      if at then head = head:sub(1, at - 1) end
    end
    for t in head:gmatch("[%u][%a]+") do add(t) end
    if #out == 0 then
      local base = (rel:match("([^/]+)$") or rel):gsub("%.md$", ""):gsub("^%d+[_%-]", "")
      for w in base:gmatch("[%a]+") do add(w:sub(1, 1):upper() .. w:sub(2):lower()) end
    end
  end
  return out
end

-- ---- payoffs ------------------------------------------------------------------------------
-- The payoff ledger's numbered items: "N. **Title** — ... — carrier: X `[span: ...]`"
function M.parse_payoffs(text)
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local n, title, rest = line:match("^%s*(%d+)%.%s+%*%*(.-)%*%*(.*)$")
    if n then
      local carrier = rest:match("carrier:%s*([^`\n]-)%s*`") or rest:match("carrier:%s*(.-)%s*$")
      local span = rest:match("`%[(.-)%]`")
      out[#out + 1] = { n = tonumber(n), title = title, carrier = carrier, span = span, text = line }
    end
  end
  return out
end

-- ---- reindex ------------------------------------------------------------------------------
-- -> stats { files, changed, removed, chapters, characters, payoffs }
function M.reindex(book, rebuild)
  M.ensure_schema()
  if rebuild then M.drop_book(book.name) end
  local kinds, chapters = classify(book)
  local all = sb.all_markdown(book)
  local present = {}
  local changed, removed = 0, 0
  local rows = {}
  for _, r in ipairs(q("SELECT path, mtime, size, hash FROM sty_files WHERE book = ?", { book.name })) do rows[r.path] = r end
  local hash = require("workflow").hash
  for _, rel in ipairs(all) do
    present[rel] = true
    local full = book.root .. "/" .. rel
    local _, mtime, size = sys.stat(full)
    mtime, size = math.floor(tonumber(mtime) or 0), math.floor(tonumber(size) or 0)
    local k = kinds[rel] or { kind = "other", role = "" }
    local old = rows[rel]
    if not old or old.mtime ~= mtime or old.size ~= size then
      local text = sb.read(full) or ""
      local h = hash(text)
      if old and old.hash == h then
        run("UPDATE sty_files SET mtime = ?, size = ?, kind = ?, role = ? WHERE book = ? AND path = ?",
          { mtime, size, k.kind, k.role, book.name, rel })
      else
        changed = changed + 1
        local title = title_of(text)
        run([[INSERT OR REPLACE INTO sty_files(book,path,kind,role,mtime,size,hash,words,title)
              VALUES(?,?,?,?,?,?,?,?,?)]], { book.name, rel, k.kind, k.role, mtime, size, h, sb.word_count(text), title })
        run("DELETE FROM sty_fts WHERE book = ? AND path = ?", { book.name, rel })
        run("INSERT INTO sty_fts(book, path, kind, title, body) VALUES(?,?,?,?,?)", { book.name, rel, k.kind, title, text })
      end
    elseif old then
      run("UPDATE sty_files SET kind = ?, role = ? WHERE book = ? AND path = ?", { k.kind, k.role, book.name, rel })
    end
  end
  for rel in pairs(rows) do
    if not present[rel] then
      removed = removed + 1
      run("DELETE FROM sty_files WHERE book = ? AND path = ?", { book.name, rel })
      run("DELETE FROM sty_fts WHERE book = ? AND path = ?", { book.name, rel })
    end
  end
  run("INSERT OR REPLACE INTO sty_books(name, root, manifest, indexed_at) VALUES(?,?,?,?)",
    { book.name, book.root, require("json").encode(book.raw or {}), os.time() })

  -- derived tables: recomputed only when something changed (or first time)
  local have = one("SELECT count(*) AS n FROM sty_chapters WHERE book = ?", { book.name }).n
  if changed > 0 or removed > 0 or have == 0 or rebuild then M.derive(book, chapters) end
  return { files = #all, changed = changed, removed = removed,
           chapters = one("SELECT count(*) AS n FROM sty_chapters WHERE book = ?", { book.name }).n,
           characters = one("SELECT count(*) AS n FROM sty_entities WHERE book = ? AND kind = 'character'", { book.name }).n,
           payoffs = one("SELECT count(*) AS n FROM sty_payoffs WHERE book = ?", { book.name }).n }
end

function M.derive(book, chapters)
  chapters = chapters or sb.chapters(book)
  local json = require("json")
  for _, t in ipairs{ "sty_chapters", "sty_entities", "sty_mentions", "sty_payoffs" } do
    run("DELETE FROM " .. t .. " WHERE book = ?", { book.name })
  end
  local drops = book.m.drop_sections or {}
  local bodies = {}
  for _, c in ipairs(chapters) do
    local text = sb.read(book.root .. "/" .. c.path) or ""
    local body = sb.drop_sections(text, drops)
    bodies[c.n] = body
    -- The longest OTHER variant: a preferred "revised" file much shorter than
    -- its base is how a revision pass quietly cut a chapter from 6.5k words to
    -- 900 while reporting it expanded. The views flag it; nothing hides it.
    local longest, longest_v = 0, ""
    local alternates = {}
    for _, v in ipairs(sb.as_list(book.m.manuscript.alternates)) do alternates[v] = true end
    for v, rel in pairs(c.variants) do
      if rel ~= c.path and not alternates[v] then
        local w = sb.word_count(sb.drop_sections(sb.read(book.root .. "/" .. rel) or "", drops))
        if w > longest then longest, longest_v = w, v end
      end
    end
    run([[INSERT INTO sty_chapters(book,n,ord,label,variant,path,variants,title,words,done,longest,longest_variant)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,?)]],
      { book.name, c.n, c.ord, c.label or "", c.variant or "", c.path, json.encode(c.variants),
        title_of(text), sb.word_count(body), c.done and 1 or 0, longest, longest_v })
  end
  for _, rel in ipairs(sb.glob(book, book.m.characters)) do
    local text = sb.read(book.root .. "/" .. rel) or ""
    local title = title_of(text)
    local id = (rel:match("([^/]+)$") or rel):gsub("%.md$", "")
    local aliases = M.aliases(title, text, rel)
    run("INSERT OR REPLACE INTO sty_entities(book,id,kind,title,path,aliases) VALUES(?,?,?,?,?,?)",
      { book.name, id, "character", title, rel, json.encode(aliases) })
    for n, body in pairs(bodies) do
      local c = 0
      for _, a in ipairs(aliases) do
        c = c + select(2, body:gsub("%f[%w]" .. a:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0") .. "%f[%W]", ""))
      end
      if c > 0 then run("INSERT INTO sty_mentions(book, entity, n, count) VALUES(?,?,?,?)", { book.name, id, n, c }) end
    end
  end
  if book.m.payoffs then
    local text = sb.read(book.root .. "/" .. book.m.payoffs)
    for _, p in ipairs(text and M.parse_payoffs(text) or {}) do
      run("INSERT OR REPLACE INTO sty_payoffs(book,n,title,carrier,span,text) VALUES(?,?,?,?,?,?)",
        { book.name, p.n, p.title, p.carrier or "", p.span or "", p.text })
    end
  end
end

-- Reindex only if the book was never indexed or anything on disk moved. Cheap:
-- a stat per file. Called by every `story` action that reads the index.
function M.fresh(book)
  M.ensure_schema()
  return M.reindex(book, false)
end

-- ---- queries ----------------------------------------------------------------------------------
function M.chapters(book) return q("SELECT * FROM sty_chapters WHERE book = ? ORDER BY ord", { book.name }) end

-- A preferred variant under this share of a sibling's length is flagged.
M.SHRINK = 0.6
function M.shrunk(c)
  return (c.longest or 0) > 0 and (c.words or 0) < M.SHRINK * c.longest
end
function M.files(book, kind)
  if kind then return q("SELECT * FROM sty_files WHERE book = ? AND kind = ? ORDER BY path", { book.name, kind }) end
  return q("SELECT * FROM sty_files WHERE book = ? ORDER BY kind, path", { book.name })
end
function M.characters(book) return q("SELECT * FROM sty_entities WHERE book = ? AND kind = 'character' ORDER BY id", { book.name }) end
function M.mentions(book, id) return q("SELECT * FROM sty_mentions WHERE book = ? AND entity = ? ORDER BY n", { book.name, id }) end
function M.payoffs(book) return q("SELECT * FROM sty_payoffs WHERE book = ? ORDER BY n", { book.name }) end

-- FTS query, as porter-stemmed AND of the words (quoted, so punctuation in a
-- query cannot become FTS syntax). -> files ranked by bm25.
function M.search_files(book, query, kind, mode)
  local terms = {}
  for w in tostring(query):gmatch("[%w']+") do terms[#terms + 1] = '"' .. w:gsub('"', "") .. '"' end
  if #terms == 0 then return {} end
  local match = table.concat(terms, mode == "or" and " OR " or " AND ")
  local sql = [[SELECT path, kind, title, bm25(sty_fts) AS rank FROM sty_fts
                WHERE sty_fts MATCH ? AND book = ?]]
  local p = { match, book.name }
  if kind and kind ~= "" and kind ~= "all" then sql = sql .. " AND kind = ?"; p[#p + 1] = kind end
  return q(sql .. " ORDER BY rank LIMIT 50", p)
end

return M
