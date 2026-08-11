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
-- Provenance and usage for model-defined tools (paper §17, §24).
--
-- Deliberately not in the tool file: description/schema/body are stable and
-- belong on disk where they can be read and edited, whereas call counts change
-- on every invocation and rewriting the file each time would be absurd.
--
-- The counts are the point. The paper's sharpest observation is that a tool
-- costing 2,000 tokens to build that saves 50 once is noise, while one that
-- removes four round trips on each of twenty later calls is infrastructure --
-- and you cannot tell those apart without measuring. git_rev is recorded so a
-- project tool can later be flagged as possibly stale when the repo has moved
-- on (§18).
CREATE TABLE IF NOT EXISTS tools (
  name TEXT NOT NULL,
  scope TEXT NOT NULL,           -- session | project | global
  project TEXT NOT NULL DEFAULT '',
  created INTEGER,
  created_session INTEGER,
  version TEXT,
  git_rev TEXT,
  calls INTEGER NOT NULL DEFAULT 0,
  failures INTEGER NOT NULL DEFAULT 0,
  last_used INTEGER,
  total_ms INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (name, scope, project)
);

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
    -- WAL: readers never block the writer and the writer never blocks readers,
    -- which is what lets many actors read the journal while one appends to it.
    -- It also survives across processes (via the -shm file), so it is the mode
    -- a multi-process swarm would need anyway. Note there is still exactly ONE
    -- writer at a time for the whole database -- WAL widens read concurrency,
    -- it does not parallelise writes.
    --
    -- WAL needs a local filesystem; on a network mount SQLite refuses and stays
    -- in the previous mode, so we check rather than assume.
    local mode = c:query("PRAGMA journal_mode=WAL")
    M.journal_mode = (mode and mode[1] and (mode[1].journal_mode or mode[1][1])) or "unknown"
    -- NORMAL is the documented-safe pairing with WAL: a crash can lose the tail
    -- of the last transaction but cannot corrupt the database, and it drops an
    -- fsync per commit. Every send/publish writes a journal row, so this is on
    -- the hot path of the bus.
    c:run("PRAGMA synchronous=NORMAL")
    -- Don't fail instantly if another connection holds the write lock; wait.
    c:run("PRAGMA busy_timeout=5000")
    c:run("PRAGMA foreign_keys=ON")
    -- The store can hold an API key, so it is owner-only. The -wal and -shm
    -- sidecars carry the same data before a checkpoint, so they get the same
    -- treatment; they may not exist yet, hence the pcall.
    for _, suffix in ipairs({ "", "-wal", "-shm" }) do
      pcall(sys.chmod, path .. suffix, 0x180) -- 0600
    end
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

-- ---- credentials -----------------------------------------------------------
-- Deliberately NOT here. Credentials live in src/lauth.c, in their own 0600
-- file, precisely so they are not in this database -- the `sql` tool can read
-- every table in it, and a model dumping kv contents into its context is the
-- leak that actually happens. See src/lauth.c for what that does and does not
-- protect against.

-- ---- tool provenance + usage (paper §17, §24) ------------------------------
function M.tool_record(name, scope, project, meta)
  meta = meta or {}
  return bog.db:run(
    "INSERT INTO tools(name,scope,project,created,created_session,version,git_rev) "
    .. "VALUES(?,?,?,?,?,?,?) ON CONFLICT(name,scope,project) DO UPDATE SET "
    -- Re-defining a tool keeps its call history: the counts describe the
    -- *procedure*, and losing them on every edit would defeat the measurement.
    .. "created=excluded.created, created_session=excluded.created_session, "
    .. "version=excluded.version, git_rev=excluded.git_rev",
    { name, scope, project or "", now(), meta.session_id, meta.version, meta.git_rev })
end

function M.tool_used(name, scope, project, ms, failed)
  return bog.db:run(
    "UPDATE tools SET calls=calls+1, failures=failures+?, last_used=?, total_ms=total_ms+? "
    .. "WHERE name=? AND scope=? AND project=?",
    { failed and 1 or 0, now(), math.floor(ms or 0), name, scope, project or "" })
end

function M.tool_stats(project)
  return bog.db:query(
    "SELECT name,scope,project,created,created_session,version,calls,failures,"
    .. "last_used,total_ms,git_rev FROM tools "
    .. "WHERE project='' OR project=? ORDER BY calls DESC, name", { project or "" })
end

function M.tool_forget(name, scope, project)
  return bog.db:run("DELETE FROM tools WHERE name=? AND scope=? AND project=?",
    { name, scope, project or "" })
end

-- ---- journal (read side; the C bus writes) ---------------------------------
-- Journal writes are asynchronous: src/lswarm.c hands rows to the writer
-- thread in src/jwriter.c, which batches them into one transaction. That makes
-- the table eventually-consistent for readers, so every read-back below has to
-- drain the ring first or it can miss rows that have already been "sent".
-- swarm.redeliver() does the same internally for the same reason.
local function flush_journal()
  if swarm and swarm.flush then swarm.flush() end
end

function M.journal_list(limit)
  flush_journal()
  return bog.db:query(
    "SELECT id,ts,from_id,to_id,topic,kind,payload,processed_at FROM journal ORDER BY id DESC LIMIT ?",
    { limit or 50 })
end

function M.journal_for(id, limit)
  flush_journal()
  return bog.db:query(
    "SELECT id,ts,from_id,to_id,topic,kind,payload,processed_at FROM journal "
    .. "WHERE from_id=? OR to_id=? ORDER BY id DESC LIMIT ?", { id, id, limit or 50 })
end

return M
