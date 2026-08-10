-- store.lua -- the local SQLite store: durable memory (FTS5), conversation
-- sessions/transcripts (resumable), a general key/value table, and harness
-- metadata. One database at ~/.boggart/boggart.db, opened once and reused
-- across reloads (bog.db persists; only the code around it is hot-swapped).
local json = require("json")
local M = {}

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);

CREATE TABLE IF NOT EXISTS kv (
  key TEXT PRIMARY KEY, value TEXT, updated INTEGER
);

CREATE TABLE IF NOT EXISTS memory (
  id INTEGER PRIMARY KEY,
  title TEXT UNIQUE NOT NULL,
  body TEXT NOT NULL,
  created INTEGER, updated INTEGER
);

CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts
  USING fts5(title, body, content='memory', content_rowid='id');

CREATE TRIGGER IF NOT EXISTS memory_ai AFTER INSERT ON memory BEGIN
  INSERT INTO memory_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
END;
CREATE TRIGGER IF NOT EXISTS memory_ad AFTER DELETE ON memory BEGIN
  INSERT INTO memory_fts(memory_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
END;
CREATE TRIGGER IF NOT EXISTS memory_au AFTER UPDATE ON memory BEGIN
  INSERT INTO memory_fts(memory_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
  INSERT INTO memory_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
END;

-- A session doubles as an agent/thread: parent_id/status/subscriptions/spec are
-- used in swarm mode; they stay NULL for plain single-agent sessions.
CREATE TABLE IF NOT EXISTS sessions (
  id INTEGER PRIMARY KEY,
  title TEXT, model TEXT,
  created INTEGER, updated INTEGER,
  messages TEXT,             -- JSON array of message objects
  parent_id INTEGER,         -- spawning agent (NULL for root/plain sessions)
  status TEXT,               -- running | idle | done | error (swarm)
  subscriptions TEXT,        -- JSON array of topic strings
  spec TEXT                  -- JSON agent spec {agent=name, skills=[...]}
);

-- The swarm message journal. Rows are written by the C bus (src/lswarm.c);
-- Lua reads them for /journal views and resume.
CREATE TABLE IF NOT EXISTS journal (
  id INTEGER PRIMARY KEY,
  ts INTEGER,
  from_id INTEGER, to_id INTEGER,
  topic TEXT, kind TEXT, payload TEXT,
  processed_at INTEGER
);
CREATE INDEX IF NOT EXISTS journal_undelivered ON journal(processed_at, to_id);
]]

-- Add a column to an existing table if a prior DB predates it (CREATE TABLE
-- IF NOT EXISTS won't alter an existing table).
local function ensure_column(db, tbl, col, decl)
  for _, r in ipairs(db:query("PRAGMA table_info(" .. tbl .. ")")) do
    if r.name == col then return end
  end
  db:exec(string.format("ALTER TABLE %s ADD COLUMN %s %s", tbl, col, decl))
end

-- One-time import of any pre-SQLite flat memory files (~/.boggart/memory/*.md).
local function import_legacy(db)
  local row = db:query("SELECT value FROM meta WHERE key='legacy_imported'")
  if row[1] then return end
  local dir = bog.userdir .. "/memory"
  if sys.stat(dir) == "dir" then
    for _, name in ipairs(sys.listdir(dir) or {}) do
      if name:match("%.md$") then
        local data = bog.util.read_file(dir .. "/" .. name) or ""
        local title = data:match("^#%s*(.-)\n") or name:gsub("%.md$", "")
        local body = data:gsub("^#.-\n", "", 1)
        M.mem_put(title, body)
      end
    end
  end
  db:run("INSERT OR REPLACE INTO meta(key,value) VALUES('legacy_imported','1')")
end

-- Open (idempotent): connects bog.db the first time, always ensures schema.
function M.open()
  if not bog.db then
    local path = bog.userdir .. "/boggart.db"
    sys.mkdir_p(bog.userdir)
    local c, err = db.open(path)
    if not c then error("store: " .. tostring(err)) end
    bog.db = c
  end
  assert(bog.db:exec(SCHEMA))
  -- migrate older DBs to the agent/thread columns
  ensure_column(bog.db, "sessions", "parent_id", "INTEGER")
  ensure_column(bog.db, "sessions", "status", "TEXT")
  ensure_column(bog.db, "sessions", "subscriptions", "TEXT")
  ensure_column(bog.db, "sessions", "spec", "TEXT")
  bog.db:run("INSERT OR REPLACE INTO meta(key,value) VALUES('schema_version','2')")
  import_legacy(bog.db)
  return M
end

local function now() return os.time() end

-- ---- key/value -------------------------------------------------------------
function M.kv_set(k, v)
  return bog.db:run("INSERT INTO kv(key,value,updated) VALUES(?,?,?) "
    .. "ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated=excluded.updated",
    { k, v, now() })
end
function M.kv_get(k)
  local r = bog.db:query("SELECT value FROM kv WHERE key=?", { k })
  return r[1] and r[1].value or nil
end
function M.kv_del(k) return bog.db:run("DELETE FROM kv WHERE key=?", { k }) end
function M.kv_list(prefix)
  if prefix and prefix ~= "" then
    return bog.db:query("SELECT key,value FROM kv WHERE key LIKE ? ORDER BY key", { prefix .. "%" })
  end
  return bog.db:query("SELECT key,value FROM kv ORDER BY key")
end

-- ---- memory ----------------------------------------------------------------
function M.mem_put(title, body)
  return bog.db:run("INSERT INTO memory(title,body,created,updated) VALUES(?,?,?,?) "
    .. "ON CONFLICT(title) DO UPDATE SET body=excluded.body, updated=excluded.updated",
    { title, body or "", now(), now() })
end
function M.mem_get(title)
  local r = bog.db:query("SELECT title,body FROM memory WHERE title=?", { title })
  return r[1]
end
function M.mem_del(title)
  local r = bog.db:run("DELETE FROM memory WHERE title=?", { title })
  return r.changes > 0
end
function M.mem_list()
  return bog.db:query("SELECT title,body FROM memory ORDER BY updated DESC")
end

-- Turn free text into a safe FTS5 MATCH expression: quote each word token and
-- OR them together, so punctuation/operators in the query can't cause a syntax
-- error. Empty -> nil (caller does a LIKE fallback / lists all).
local function fts_query(q)
  local toks = {}
  for t in q:gmatch("%w+") do toks[#toks + 1] = '"' .. t .. '"' end
  if #toks == 0 then return nil end
  return table.concat(toks, " OR ")
end

function M.mem_search(query)
  if not query or query:match("^%s*$") then return M.mem_list() end
  local fq = fts_query(query)
  if not fq then
    local like = "%" .. query .. "%"
    return bog.db:query(
      "SELECT title,body FROM memory WHERE body LIKE ? OR title LIKE ? ORDER BY updated DESC",
      { like, like })
  end
  return bog.db:query(
    "SELECT m.title AS title, m.body AS body FROM memory_fts f "
    .. "JOIN memory m ON m.id = f.rowid WHERE memory_fts MATCH ? ORDER BY rank",
    { fq })
end

-- ---- sessions --------------------------------------------------------------
function M.sess_create(title, model)
  local r = bog.db:run("INSERT INTO sessions(title,model,created,updated,messages) VALUES(?,?,?,?, '[]')",
    { title, model, now(), now() })
  return r.rowid
end

function M.sess_save(id, title, model, messages)
  local ok, encoded = pcall(json.encode, messages)
  if not ok then encoded = "[]" end
  return bog.db:run("UPDATE sessions SET title=?, model=?, updated=?, messages=? WHERE id=?",
    { title, model, now(), encoded, id })
end

function M.sess_load(id)
  local r = bog.db:query("SELECT id,title,model,messages FROM sessions WHERE id=?", { id })
  local s = r[1]
  if not s then return nil end
  local ok, msgs = pcall(json.decode, s.messages or "[]")
  s.messages = ok and msgs or {}
  return s
end

function M.sess_list(limit)
  return bog.db:query(
    "SELECT id,title,model,updated FROM sessions ORDER BY updated DESC LIMIT ?",
    { limit or 20 })
end

function M.sess_delete(id) return bog.db:run("DELETE FROM sessions WHERE id=?", { id }) end

-- ---- threads / agents (a session row + swarm columns) ----------------------
-- opts: { parent_id?, title?, model?, spec? (table), status? }
function M.thread_create(opts)
  opts = opts or {}
  local r = bog.db:run(
    "INSERT INTO sessions(title,model,created,updated,messages,parent_id,status,subscriptions,spec) "
    .. "VALUES(?,?,?,?, '[]', ?, ?, '[]', ?)",
    { opts.title, opts.model, now(), now(), opts.parent_id,
      opts.status or "running", opts.spec and json.encode(opts.spec) or nil })
  return r.rowid
end

-- fields: any of title, model, status, messages(table), subscriptions(table), spec(table)
function M.thread_save(id, fields)
  local sets, vals = {}, {}
  local function put(col, v) sets[#sets + 1] = col .. "=?"; vals[#vals + 1] = v end
  if fields.title ~= nil then put("title", fields.title) end
  if fields.model ~= nil then put("model", fields.model) end
  if fields.status ~= nil then put("status", fields.status) end
  if fields.messages ~= nil then
    local ok, enc = pcall(json.encode, fields.messages)
    put("messages", ok and enc or "[]")
  end
  if fields.subscriptions ~= nil then put("subscriptions", json.encode(fields.subscriptions)) end
  if fields.spec ~= nil then put("spec", json.encode(fields.spec)) end
  put("updated", now())
  vals[#vals + 1] = id
  return bog.db:run("UPDATE sessions SET " .. table.concat(sets, ", ") .. " WHERE id=?", vals)
end

local function decode_or(s, default)
  if not s or s == "" then return default end
  local ok, v = pcall(json.decode, s)
  return ok and v or default
end

function M.thread_load(id)
  local r = bog.db:query(
    "SELECT id,title,model,parent_id,status,messages,subscriptions,spec FROM sessions WHERE id=?", { id })
  local t = r[1]
  if not t then return nil end
  t.messages = decode_or(t.messages, {})
  t.subscriptions = decode_or(t.subscriptions, {})
  t.spec = decode_or(t.spec, nil)
  return t
end

-- Live (non-terminal) threads, or all with include_done.
function M.thread_list(include_done)
  local sql = "SELECT id,title,model,parent_id,status,updated FROM sessions WHERE status IS NOT NULL"
  if not include_done then sql = sql .. " AND status IN ('running','idle')" end
  return bog.db:query(sql .. " ORDER BY id")
end

function M.thread_set_status(id, status)
  return bog.db:run("UPDATE sessions SET status=?, updated=? WHERE id=?", { status, now(), id })
end

-- ---- journal (read side; the C bus writes) ---------------------------------
function M.journal_list(limit)
  return bog.db:query(
    "SELECT id,ts,from_id,to_id,topic,kind,payload,processed_at FROM journal ORDER BY id DESC LIMIT ?",
    { limit or 50 })
end

function M.journal_for(id, limit)
  return bog.db:query(
    "SELECT id,ts,from_id,to_id,topic,kind,payload,processed_at FROM journal "
    .. "WHERE from_id=? OR to_id=? ORDER BY id DESC LIMIT ?", { id, id, limit or 50 })
end

return M
