-- store.lua -- the local SQLite store: durable memory (FTS5), conversation
-- sessions/transcripts (resumable), a general key/value table, and harness
-- metadata. One database at ~/.boggart/boggart.db, opened once and reused
-- across reloads (bog.db persists; only the code around it is hot-swapped).
local json = require("json")
local lifecycle = require("lifecycle")
local M = {}

-- Bumped whenever an *old* boggart could no longer read a database this one
-- writes. The additive ensure_column() migrations below do not need a bump:
-- they only add columns, and an older binary ignores columns it does not
-- select. A bump is for the other direction -- a newer store meeting an older
-- binary, which is refused in M.open() rather than half-migrated.
M.SCHEMA_VERSION = 2

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);

CREATE TABLE IF NOT EXISTS kv (
  key TEXT PRIMARY KEY, value TEXT, updated INTEGER
);

-- Titles are unique WITHIN a project, not globally: two stories both have a
-- "protagonist", and a title that could only exist once in the whole store
-- would make them overwrite each other -- exactly the collision projects exist
-- to prevent. The uniqueness therefore lives in an index over
-- (title, COALESCE(project,'')) rather than on the column, because a plain
-- UNIQUE index would treat every NULL project as distinct and let global
-- accumulate duplicates.
CREATE TABLE IF NOT EXISTS memory (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
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

-- The record envelope: an append-only log of what agents DID and what was
-- DECIDED -- one row per event (a telemetry span, a permission decision, an
-- agent exit). It is the substrate the reliability layer MEASURES over now and
-- the event source Phase 2's reducer will replay for resume/fork/branch. Kept
-- distinct from `journal` (which is bus DELIVERY, with redelivery semantics) on
-- purpose: records are history and are never redelivered.
CREATE TABLE IF NOT EXISTS records (
  id INTEGER PRIMARY KEY,       -- monotonic append order
  ts INTEGER,
  run_id INTEGER,               -- the root run this belongs to
  agent_id INTEGER,             -- the agent that produced it
  parent_id INTEGER,            -- agent lineage
  kind TEXT NOT NULL,           -- span:turn | span:tool | span:request | decision | agent:exit
  payload TEXT                  -- JSON detail
);
CREATE INDEX IF NOT EXISTS records_run ON records(run_id, id);

-- The model catalog: where each model lives, what it can do, and which model
-- answers to which role.
--
-- Rows rather than a JSON blob, for three reasons that all bite in practice:
-- "which models do vision above 500k context" is a query; the agent can already
-- read and edit these through the `sql`/`kv` tools it has; and telemetry can
-- join against them to report what a model actually cost. JSON is how a catalog
-- is imported, exported and refreshed (lua/catalog.lua) -- it is the exchange
-- format, not the store.
--
-- `providers.key_slot` is load-bearing beyond configuration: it is the registry
-- of which credential may be used with which host, and src/lauth.c refuses a
-- (url, slot) pair that is not recorded here. Editing this table therefore
-- changes what a key is allowed to reach, which is exactly where that decision
-- should live -- once, in the store, rather than in whichever caller assembled
-- a request.
CREATE TABLE IF NOT EXISTS providers (
  name TEXT PRIMARY KEY,        -- "xai", "zai", "openrouter"
  label TEXT,                   -- "xAI (Grok)"
  url TEXT,                     -- base endpoint
  wire TEXT,                    -- anthropic | openai | responses
  auth TEXT,                    -- bearer | x-api-key  (independent of wire)
  key_slot TEXT,                -- credential slot name; NULL = derive from url
  env TEXT,                     -- environment variable holding a key
  headers TEXT,                 -- JSON object of extra request headers
  catalog_url TEXT,             -- where `models refresh` reads a live list
  source TEXT,                  -- seed | import | refresh | user
  updated INTEGER
);

CREATE TABLE IF NOT EXISTS models (
  id TEXT PRIMARY KEY,          -- "grok-4.6", "anthropic/claude-opus-5"
  provider TEXT,                -- -> providers.name
  label TEXT,
  context INTEGER,              -- context window in tokens
  max_output INTEGER,
  tools INTEGER,                -- 0/1 capability flags, read by api.lua
  vision INTEGER,
  effort INTEGER,               -- accepts reasoning_effort
  input_price REAL,             -- per 1M tokens, for the cost estimate
  output_price REAL,
  source TEXT,
  updated INTEGER
);
CREATE INDEX IF NOT EXISTS models_provider ON models(provider);

CREATE TABLE IF NOT EXISTS roles (
  name TEXT PRIMARY KEY,        -- "default", "utility", "critic"
  spec TEXT,                    -- JSON: a model id, or an ordered list of them
  updated INTEGER
);

-- Projects: the unit of context (docs/projects.md).
--
-- A project is NAMED, not a directory, and owns zero or more roots -- git is
-- used where a root is a repo and everything else still works where it is not,
-- so a story project is as real as a codebase.
--
-- `global` is itself a project rather than a separate tier: the loose chat you
-- have when you are not working on anything in particular. Every project reads
-- it, ranked below its own results; no project reads another. That one rule is
-- the whole isolation model.
CREATE TABLE IF NOT EXISTS projects (
  name TEXT PRIMARY KEY,        -- "global", "nightjar", "boggart"
  label TEXT,
  roots TEXT,                   -- JSON array of directories
  created INTEGER, updated INTEGER
);

-- Which projects a skill serves.
--
-- Deliberately NOT a join table: the skill carries its list, and nothing
-- carries a list of skills. One direction of reference, one place to edit, no
-- pair of foreign keys to drift apart. A skill with no row here is global --
-- available everywhere -- which is what every skill that exists today is.
--
-- The BODY of a skill stays a file (lua/skills/*.lua, builtin or overlay);
-- this table holds only the keying, so nothing about how skills are written or
-- loaded changes.
CREATE TABLE IF NOT EXISTS skills (
  name TEXT PRIMARY KEY,
  projects TEXT,                -- JSON list; NULL/empty = every project
  updated INTEGER
);
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

-- ---- session search index (FTS5) -------------------------------------------
-- Modelled on skills_fts below, with one deliberate difference: skills_fts is a
-- throwaway cache the router rebuilds wholesale from the live Lua module set,
-- whereas sessions are durable data with no such source to rebuild from. So
-- this index is maintained incrementally -- every write path re-indexes just
-- the row it touched (fts_index_session), and open() seeds it once from any
-- sessions that predate the feature (backfill_sessions_fts). A regular (not
-- external-content) fts5 table is used so a row can be replaced with an
-- ordinary DELETE ... WHERE rowid=?; the rowid IS the session id, which is what
-- lets sess_search join straight back to sessions and return sess_list's shape.
--
-- Tradeoff, the other option being "rebuild the whole index on each search":
-- the sidebar calls sess_search on every keystroke, and a full rebuild there
-- would re-read every transcript blob per letter typed. Two tiny writes per
-- save keeps search itself O(matches); the price is that the four save paths
-- (sess_create/save, thread_create/save) must remember to call
-- fts_index_session, and sess_delete to drop the row.
local SESSIONS_FTS = "CREATE VIRTUAL TABLE IF NOT EXISTS sessions_fts "
  .. "USING fts5(title, body)"

-- Flatten a transcript into searchable text. Message shapes vary (bare
-- strings, {role, content=string}, content arrays of typed parts), so rather
-- than assume one, walk the decoded structure and keep every string VALUE it
-- holds -- keys are skipped, so "role"/"content" themselves never match. The
-- byte budget stops a pathological pasted-log transcript from bloating the row.
local function collect_text(v, out, budget)
  if budget[1] <= 0 then return end
  local t = type(v)
  if t == "string" then
    out[#out + 1] = v
    budget[1] = budget[1] - #v
  elseif t == "table" then
    for _, item in pairs(v) do collect_text(item, out, budget) end
  end
end

-- messages may arrive as the JSON string stored in the column or as an
-- already-decoded table (the thread writers hand us the latter).
local function sess_body(messages)
  local msgs = messages
  if type(msgs) == "string" then
    local ok, decoded = pcall(json.decode, msgs)
    msgs = ok and decoded or nil
  end
  if type(msgs) ~= "table" then return "" end
  local out = {}
  collect_text(msgs, out, { 256 * 1024 })
  return table.concat(out, " ")
end

-- Re-index one session by id, reading its current title/messages back from the
-- row so the result is right no matter which columns the caller changed. A
-- regular fts5 table takes a plain DELETE, so "replace" is delete-then-insert.
local function fts_index_session(id)
  if not id then return end
  local r = bog.db:query("SELECT id,title,messages FROM sessions WHERE id=?", { id })
  local s = r[1]
  if not s then return end
  bog.db:run("DELETE FROM sessions_fts WHERE rowid=?", { id })
  bog.db:run("INSERT INTO sessions_fts(rowid,title,body) VALUES(?,?,?)",
    { id, s.title or "", sess_body(s.messages) })
end

-- One-time seed for sessions written before this index existed, guarded by a
-- meta flag so later opens skip the whole-table scan. Runs for the CLI too --
-- that is what makes search work everywhere, not just the studio. Cost is a
-- single pass over existing transcripts on the first open after upgrade.
local function backfill_sessions_fts(conn)
  if conn:query("SELECT value FROM meta WHERE key='sessions_fts_backfilled'")[1] then return end
  conn:exec(SESSIONS_FTS)
  conn:run("DELETE FROM sessions_fts")
  for _, s in ipairs(conn:query("SELECT id,title,messages FROM sessions")) do
    conn:run("INSERT INTO sessions_fts(rowid,title,body) VALUES(?,?,?)",
      { s.id, s.title or "", sess_body(s.messages) })
  end
  conn:run("INSERT OR REPLACE INTO meta(key,value) VALUES('sessions_fts_backfilled','1')")
end

-- The schema version recorded in a database, or nil if it has none (a store
-- from before this key, or one created seconds ago). Takes a connection rather
-- than using bog.db so `doctor` can ask the same question of a store it has
-- opened separately, without adopting it.
function M.schema_version(conn)
  local ok, rows = pcall(conn.query, conn, "SELECT value FROM meta WHERE key='schema_version'")
  if not ok or not rows or not rows[1] then return nil end
  return tonumber(rows[1].value)
end

-- Is this file a working SQLite database? PRAGMA integrity_check rather than
-- "did open() succeed": sqlite3_open() is lazy and happily returns a handle for
-- a file of shell script, which then fails on the first statement -- which is
-- exactly the traceback this replaces.
local function integrity(conn)
  -- Three ways this says no: the call raises, it returns nil plus the SQLite
  -- error (a file that is not a database fails at prepare), or it returns a
  -- verdict that is not "ok". The middle one is the common case and carries
  -- the only message worth showing.
  local ok, rows, qerr = pcall(conn.query, conn, "PRAGMA integrity_check")
  if not ok then return false, tostring(rows) end
  if not rows then return false, tostring(qerr or "integrity_check returned nothing") end
  local verdict = rows[1] and (rows[1].integrity_check or rows[1][1])
  if verdict == "ok" then return true end
  return false, tostring(verdict)
end

-- Move a damaged store aside. Renamed, never removed: it is the user's data,
-- it may still be salvageable with the sqlite3 CLI, and a program that deletes
-- a file it has just declared unreadable is a program you cannot trust with the
-- next one. The -wal and -shm sidecars travel with it, or SQLite would try to
-- replay the old WAL into the new database.
function M.quarantine(path)
  local stamp = os.date("%Y%m%d-%H%M%S")
  local dest = path .. ".corrupt-" .. stamp
  local ok, err = os.rename(path, dest)
  if not ok then return nil, err end
  for _, sfx in ipairs({ "-wal", "-shm" }) do
    if sys.stat(path .. sfx) == "file" then os.rename(path .. sfx, dest .. sfx) end
  end
  return dest
end

-- Open (idempotent): creates the directory and the database if they are not
-- there, verifies the one that is, and always ensures the schema. Every part
-- of that is the normal path on a new machine, so none of it is an error.
--
-- M.state records what this start actually did, for the first-run notice and
-- for `doctor`: { path, first_run, recovered = <quarantined path> }.
function M.open()
  if not bog.db then
    local path = bog.userdir .. "/boggart.db"
    lifecycle.ensure_dir(bog.userdir)
    local state = { path = path, first_run = sys.stat(path) ~= "file" }
    local c, err = db.open(path)
    if not c then
      lifecycle.fail("cannot open the local store at " .. path .. ": " .. tostring(err) .. ".",
        "Check that " .. bog.userdir .. " is writable, or set BOGGART_HOME to a\n" ..
        "directory boggart may use.")
    end
    if not state.first_run then
      local sound, why = integrity(c)
      if not sound then
        c:close()
        local dest, rerr = M.quarantine(path)
        if not dest then
          lifecycle.fail("the local store at " .. path .. " is damaged (" .. tostring(why) ..
            ") and could not be moved aside: " .. tostring(rerr) .. ".",
            "Move or rename that file yourself, then start boggart again.")
        end
        -- Loud, on stderr, every time it happens: this is real data loss and
        -- pretending otherwise -- "recovered!" -- would be a lie.
        io.stderr:write(
          "\nboggart: the local store at ", path, " is damaged (", tostring(why), ").\n",
          "boggart: it has been MOVED ASIDE to ", dest, " and a new, empty store created.\n",
          "boggart: saved sessions and stored memories are NOT in the new store.\n",
          "boggart: nothing was deleted. Run `boggart doctor` to see where things stand.\n\n")
        -- Deliberately not state.first_run: the database is new but the user
        -- is not, and greeting someone with "welcome to boggart" straight
        -- after telling them their history is gone would be grotesque.
        state.recovered = dest
        c, err = db.open(path)
        if not c then
          lifecycle.fail("cannot create a new store at " .. path .. ": " .. tostring(err) .. ".",
            "The old one was moved to " .. dest .. ".")
        end
      end
    end
    bog.db = c
    -- The semantic data API. From here on the harness talks to bog.repo (a C
    -- module, src/lrepo.c) for operations like kv_*, not to bog.db with SQL.
    -- The backend (SQLite today, Postgres later) lives entirely behind repo, so
    -- swapping it changes no Lua and no skill. store.lua still owns schema,
    -- migrations and FTS via bog.db until those ops move behind repo too.
    bog.repo = repo.sqlite(c)
    M.state = state
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
  -- Refuse a store from the future *before* touching it. CREATE TABLE IF NOT
  -- EXISTS and ALTER TABLE ADD COLUMN would each half-apply this build's idea
  -- of the schema to a database that has moved past it, and the resulting mix
  -- is worse than either version -- and is what the newer binary would then
  -- have to cope with. Downgrading is a thing people do; corrupting their
  -- store while they do it is not acceptable.
  local found = M.schema_version(bog.db)
  if found and found > M.SCHEMA_VERSION then
    local path = M.state and M.state.path or (bog.userdir .. "/boggart.db")
    bog.db:close()
    bog.db = nil
    lifecycle.fail(
      "the store at " .. path .. " was written by a newer boggart (schema version " ..
      found .. "; this build understands " .. M.SCHEMA_VERSION .. ").",
      "Nothing has been changed. Upgrade boggart, or set BOGGART_HOME to a\n" ..
      "different directory to start fresh.")
  end
  assert(bog.db:exec(SCHEMA))
  -- migrate older DBs to the agent/thread columns
  ensure_column(bog.db, "sessions", "parent_id", "INTEGER")
  ensure_column(bog.db, "sessions", "status", "TEXT")
  ensure_column(bog.db, "sessions", "subscriptions", "TEXT")
  ensure_column(bog.db, "sessions", "spec", "TEXT")
  -- Which project a conversation and a memory belong to. NULL means `global`,
  -- so every row that exists today is already correctly classified and the
  -- migration is a no-op rather than a rewrite of the store.
  ensure_column(bog.db, "sessions", "project", "TEXT")
  ensure_column(bog.db, "memory", "project", "TEXT")
  -- Drop the old column-level UNIQUE(title) on stores that predate projects.
  -- SQLite cannot alter a constraint away, so the table is rebuilt once --
  -- guarded by a meta flag, and by keeping every row and id so the FTS content
  -- table (content_rowid='id') stays valid.
  do
    local done = bog.db:query("SELECT value FROM meta WHERE key='memory_title_unscoped'")[1]
    if not done then
      local uniq = false
      for _, idx in ipairs(bog.db:query("PRAGMA index_list(memory)") or {}) do
        if (idx.origin == "u" or idx.origin == "pk") and tostring(idx.name):find("autoindex") then
          uniq = true
        end
      end
      if uniq then
        bog.db:exec([[
          CREATE TABLE memory_rebuilt (
            id INTEGER PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL,
            created INTEGER, updated INTEGER, project TEXT
          );
          INSERT INTO memory_rebuilt(id,title,body,created,updated,project)
            SELECT id,title,body,created,updated,project FROM memory;
          DROP TABLE memory;
          ALTER TABLE memory_rebuilt RENAME TO memory;
        ]])
        -- the triggers and the FTS content table referenced the old table
        bog.db:exec(SCHEMA)
        bog.db:run("INSERT INTO memory_fts(memory_fts) VALUES('rebuild')")
      end
      bog.db:run("INSERT OR REPLACE INTO meta(key,value) VALUES('memory_title_unscoped','1')")
    end
  end
  bog.db:exec("CREATE UNIQUE INDEX IF NOT EXISTS memory_title_project "
    .. "ON memory(title, COALESCE(project,''))")
  bog.db:run("INSERT OR REPLACE INTO meta(key,value) VALUES('schema_version',?)",
    { tostring(M.SCHEMA_VERSION) })
  -- Hand C the store so it can consult the credential-slot registry (the
  -- `providers` table) when a routed request names a slot. Without this the
  -- registry is simply absent and credentials resolve exactly as they did
  -- before the catalog existed -- see boggart_auth_header_for in src/lauth.c.
  if auth and auth.bind_store then pcall(auth.bind_store, bog.db) end
  -- Seed the model catalog the first time its tables are empty. Idempotent and
  -- quiet: a user who has curated their own catalog is never re-seeded over.
  pcall(function() require("catalog").seed_if_empty() end)
  -- The `global` project exists from the first run: it is where every chat and
  -- memory that is not about a particular body of work lives, and every other
  -- project reads it. Then adopt the project owning this directory, if exactly
  -- one does (docs/projects.md).
  pcall(function()
    local proj = require("project")
    proj.ensure_global()
    proj.adopt_cwd()
  end)
  -- Sweep out blank sessions left by the era when starting a conversation
  -- created a row before anyone had said anything. Silent when there are none,
  -- which is every run after the first.
  pcall(function()
    local n = M.prune_empty_sessions()
    if n and n > 0 then
      bog.log(string.format("removed %d empty session%s", n, n == 1 and "" or "s"))
    end
  end)
  import_legacy(bog.db)
  -- Session full-text index: ensure the table, then seed it once from sessions
  -- that predate it (see backfill_sessions_fts). Additive -- an older boggart
  -- that meets this table just ignores it.
  bog.db:exec(SESSIONS_FTS)
  backfill_sessions_fts(bog.db)
  -- `announced` because open() is idempotent and may be called again in the
  -- same process (the studio, a reload); the install happened only once.
  if M.state and (M.state.first_run or M.state.recovered) and not M.state.announced then
    M.state.announced = true
    bog.db:run("INSERT OR IGNORE INTO meta(key,value) VALUES('installed_at',?)",
      { tostring(os.time()) })
    if bog.events then
      bog.events.emit(M.state.recovered and "store:recovered" or "store:created",
        { path = M.state.path, moved_to = M.state.recovered })
    end
  end
  return M
end

local function now() return os.time() end

-- ---- key/value -------------------------------------------------------------
-- These now delegate to the C data API (bog.repo). The SQL that used to live
-- here moved into src/lrepo.c behind the backend seam; callers (bog.store.kv_*)
-- are unchanged. This is the template every other op follows as it moves.
function M.kv_set(k, v) return bog.repo:kv_set(k, v) end

-- ---- the model catalog -----------------------------------------------------
-- Thin pass-throughs to the C operations (src/lrepo.c), the same shape as the
-- kv ones above: the harness calls named operations, never SQL, so a second
-- backend is a second set of identically-named methods.
function M.model_get(id)        return bog.repo:model_get(id) end
function M.model_put(row)       return bog.repo:model_put(row) end
function M.models_where(filter) return bog.repo:models_where(filter or {}) end
function M.provider_get(name)   return bog.repo:provider_get(name) end
function M.provider_put(row)    return bog.repo:provider_put(row) end
function M.catalog_list(what)   return bog.repo:catalog_list(what or "models") end
function M.role_get(name)       return bog.repo:role_get(name) end
function M.role_put(name, spec) return bog.repo:role_put(name, spec) end
function M.kv_get(k) return bog.repo:kv_get(k) end
function M.kv_del(k) return bog.repo:kv_del(k) end
function M.kv_list(prefix)
  if prefix and prefix ~= "" then
    return bog.repo:kv_list(prefix)
  end
  return bog.repo:kv_list()
end

-- ---- memory ----------------------------------------------------------------
-- ---- projects --------------------------------------------------------------
--
-- The current project is process state (bog.project); these are the rows.
-- GLOBAL is the name of the project every other one can read.
M.GLOBAL = "global"

-- NOTE ON NIL PARAMETERS, which cost an hour: a params array with an interior
-- nil has an UNDEFINED length in Lua, so `{name, nil, roots, t, t}` can bind one
-- parameter instead of five and the statement silently stores nothing. The C
-- binder handles nil correctly (it binds NULL); the array never reaches it
-- intact. So nothing in this file ever puts a nil inside a params array --
-- either the value is made real, or the SQL branches.
function M.project_put(name, fields)
  fields = fields or {}
  local cur = M.project_get(name)
  local label = fields.label or (cur and cur.label) or ""
  local roots = json.encode(fields.roots or (cur and cur.roots) or {})
  bog.db:run(
    "INSERT INTO projects(name,label,roots,created,updated) VALUES(?,?,?,?,?) "
    .. "ON CONFLICT(name) DO UPDATE SET label=excluded.label, "
    .. "roots=excluded.roots, updated=excluded.updated",
    { name, label, roots, now(), now() })
  return name
end

function M.project_get(name)
  local r = bog.db:query("SELECT name,label,roots,created,updated FROM projects WHERE name=?",
    { name })
  local p = r[1]
  if not p then return nil end
  if type(p.roots) == "string" and p.roots ~= "" then
    local ok, t = pcall(json.decode, p.roots)
    p.roots = ok and t or {}
  else
    p.roots = {}
  end
  return p
end

function M.project_list()
  local rows = bog.db:query("SELECT name,label,roots,updated FROM projects ORDER BY name")
  for _, p in ipairs(rows) do
    if type(p.roots) == "string" and p.roots ~= "" then
      local ok, t = pcall(json.decode, p.roots)
      p.roots = ok and t or {}
    else
      p.roots = {}
    end
  end
  return rows
end

function M.project_del(name)
  if name == M.GLOBAL then return false end   -- global is not deletable
  local r = bog.db:run("DELETE FROM projects WHERE name=?", { name })
  return r.changes > 0
end

-- Everything a project owns comes home to `global` rather than disappearing
-- with it: deleting a project must not silently delete a year of chat.
function M.project_absorb(name)
  if name == M.GLOBAL then return 0 end
  local a = bog.db:run("UPDATE sessions SET project=NULL WHERE project=?", { name })
  local b = bog.db:run("UPDATE memory   SET project=NULL WHERE project=?", { name })
  return (a.changes or 0) + (b.changes or 0)
end

-- ---- which projects a skill serves -----------------------------------------
-- One row per skill carrying its project list. Not a join table: the skill
-- names its projects and nothing names its skills, so there is one direction of
-- reference and one place to edit.
function M.skill_projects_put(name, projects)
  local payload = json.encode(projects or {})
  bog.db:run("INSERT INTO skills(name,projects,updated) VALUES(?,?,?) "
    .. "ON CONFLICT(name) DO UPDATE SET projects=excluded.projects, updated=excluded.updated",
    { name, payload, now() })
  return true
end

function M.skill_projects(name)
  local r = bog.db:query("SELECT projects FROM skills WHERE name=?", { name })[1]
  if not r or type(r.projects) ~= "string" or r.projects == "" then return {} end
  local ok, t = pcall(json.decode, r.projects)
  return (ok and type(t) == "table") and t or {}
end

function M.skill_projects_all()
  local out = {}
  for _, r in ipairs(bog.db:query("SELECT name,projects FROM skills") or {}) do
    local ok, t = pcall(json.decode, r.projects or "[]")
    out[r.name] = (ok and type(t) == "table") and t or {}
  end
  return out
end

-- ---- memory, scoped ---------------------------------------------------------
--
-- The resolution rule, in one place: a read returns THIS project's rows first,
-- then `global`'s underneath, and never another project's. A row with a NULL
-- project is global, which is why no migration was needed -- every memory that
-- existed before projects did is already correctly classified.
local function proj_or_global(p)
  if p == nil or p == "" or p == M.GLOBAL then return nil end
  return p
end
M.proj_or_global = proj_or_global

-- Update-then-insert rather than ON CONFLICT: the uniqueness is an expression
-- index over (title, COALESCE(project,'')), and naming that as a conflict
-- target is both fiddly and easy to get subtly wrong. Two plain statements say
-- what is meant.
function M.mem_put(title, body, project)
  local p = proj_or_global(project)
  local upd
  if p then
    upd = bog.db:run("UPDATE memory SET body=?, updated=? WHERE title=? AND project=?",
      { body or "", now(), title, p })
  else
    upd = bog.db:run("UPDATE memory SET body=?, updated=? WHERE title=? AND project IS NULL",
      { body or "", now(), title })
  end
  if (upd.changes or 0) > 0 then return upd end
  if p then
    return bog.db:run(
      "INSERT INTO memory(title,body,created,updated,project) VALUES(?,?,?,?,?)",
      { title, body or "", now(), now(), p })
  end
  return bog.db:run(
    "INSERT INTO memory(title,body,created,updated,project) VALUES(?,?,?,?,NULL)",
    { title, body or "", now(), now() })
end

function M.mem_get(title, project)
  local p = proj_or_global(project)
  -- own first, then global; never a sibling's
  if p then
    return bog.db:query(
      "SELECT title,body,project FROM memory WHERE title=? AND (project=? OR project IS NULL) "
      .. "ORDER BY (project IS NULL) LIMIT 1", { title, p })[1]
  end
  return bog.db:query(
    "SELECT title,body,project FROM memory WHERE title=? AND project IS NULL LIMIT 1",
    { title })[1]
end

-- Forget, scoped. Without a project this removes the global memory; with one it
-- removes that project's and leaves global (and every sibling) untouched.
function M.mem_del(title, project)
  local p = proj_or_global(project)
  local r
  if p then r = bog.db:run("DELETE FROM memory WHERE title=? AND project=?", { title, p })
  else r = bog.db:run("DELETE FROM memory WHERE title=? AND project IS NULL", { title }) end
  return (r.changes or 0) > 0
end

-- Move a memory into `global` -- the only way project knowledge becomes
-- universal, and deliberately an explicit act.
function M.mem_promote(title, project)
  local p = proj_or_global(project)
  if not p then return false end
  local r = bog.db:run("UPDATE memory SET project=NULL, updated=? WHERE title=? AND project=?",
    { now(), title, p })
  return (r.changes or 0) > 0
end

function M.mem_list(project)
  local p = proj_or_global(project)
  -- ORDER BY (project IS NULL): own rows sort before global ones, which is the
  -- ranking rule expressed once, in SQL, rather than in every caller.
  if p then
    return bog.db:query(
      "SELECT title,body,project FROM memory WHERE (project=? OR project IS NULL) "
      .. "ORDER BY (project IS NULL), updated DESC", { p })
  end
  return bog.db:query(
    "SELECT title,body,project FROM memory WHERE project IS NULL ORDER BY updated DESC")
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

function M.mem_search(query, project)
  local p = proj_or_global(project)
  if not query or query:match("^%s*$") then return M.mem_list(project) end
  local fq = fts_query(query)
  if not fq then
    local like = "%" .. query .. "%"
    if p then
      return bog.db:query(
        "SELECT title,body,project FROM memory WHERE (body LIKE ? OR title LIKE ?) "
        .. "AND (project=? OR project IS NULL) ORDER BY (project IS NULL), updated DESC",
        { like, like, p })
    end
    return bog.db:query(
      "SELECT title,body,project FROM memory WHERE (body LIKE ? OR title LIKE ?) "
      .. "AND project IS NULL ORDER BY updated DESC", { like, like })
  end
  -- Rank own-project hits above global ones, and relevance within each. A
  -- global hit still surfaces (that is the point of global) but never outranks
  -- something this project actually knows.
  if p then
    return bog.db:query(
      "SELECT m.title AS title, m.body AS body, m.project AS project FROM memory_fts f "
      .. "JOIN memory m ON m.id = f.rowid WHERE memory_fts MATCH ? "
      .. "AND (m.project=? OR m.project IS NULL) ORDER BY (m.project IS NULL), rank",
      { fq, p })
  end
  return bog.db:query(
    "SELECT m.title AS title, m.body AS body, m.project AS project FROM memory_fts f "
    .. "JOIN memory m ON m.id = f.rowid WHERE memory_fts MATCH ? AND m.project IS NULL "
    .. "ORDER BY rank", { fq })
end

-- ---- skill search (FTS5) ---------------------------------------------------
-- A derived cache, not durable data: the live skill set is Lua modules
-- (embedded + overlay + session-defined), so the router rebuilds this table
-- from that set and queries it with FTS5's built-in bm25(). Created lazily
-- here rather than in SCHEMA: it carries no state worth versioning, and an
-- older boggart finding it in the DB just ignores it.
--
-- Column order matters: bm25() weights are positional, and skills_search's
-- (4,3,2,1) means a hit on the name says more than one deep in instructions.
local SKILLS_FTS = "CREATE VIRTUAL TABLE IF NOT EXISTS skills_fts "
  .. "USING fts5(name, description, tools, instructions)"

-- rows: { { name=, description=, tools=, instructions= }, ... } -- full rebuild.
function M.skills_reindex(rows)
  bog.db:exec(SKILLS_FTS)
  bog.db:run("DELETE FROM skills_fts")
  for _, r in ipairs(rows or {}) do
    bog.db:run("INSERT INTO skills_fts(name,description,tools,instructions) VALUES(?,?,?,?)",
      { r.name, r.description or "", r.tools or "", r.instructions or "" })
  end
end

-- Best matches first. FTS5's bm25() is smaller-is-better (negative for good
-- hits); it is negated here so callers see the intuitive bigger-is-better.
function M.skills_search(query, n)
  local fq = fts_query(query or "")
  if not fq then return {} end
  return bog.db:query(
    "SELECT name, description, -bm25(skills_fts, 4.0, 3.0, 2.0, 1.0) AS score "
    .. "FROM skills_fts WHERE skills_fts MATCH ? "
    .. "ORDER BY score DESC, name ASC LIMIT ?",
    { fq, n or 5 })
end

-- ---- code search (FTS5) ----------------------------------------------------
-- A native bm25 index over the working tree's source files, so `code_search`
-- has a ranked, tokenised backend even when no code-intelligence MCP server is
-- up. Like skills_fts it is a derived cache: rebuilt from disk, incremental by
-- mtime, and safe for an older boggart to ignore. code_meta tracks each file's
-- mtime and its FTS rowid, so a changed file is re-indexed and an unchanged one
-- is skipped. path is UNINDEXED (stored, not tokenised); body carries the bm25.
local CODE_FTS  = "CREATE VIRTUAL TABLE IF NOT EXISTS code_fts USING fts5(path UNINDEXED, body)"
local CODE_META = "CREATE TABLE IF NOT EXISTS code_meta(path TEXT PRIMARY KEY, mtime INTEGER, rowid INTEGER)"

local CODE_MAX_FILES = 20000
local CODE_MAX_BYTES = 512 * 1024
local CODE_SKIP_DIR = { [".git"] = 1, node_modules = 1, build = 1, dist = 1,
  target = 1, [".venv"] = 1, venv = 1, __pycache__ = 1, [".cache"] = 1 }
local CODE_SKIP_EXT = { png=1,jpg=1,jpeg=1,gif=1,webp=1,ico=1,svg=1,pdf=1,zip=1,
  gz=1,tgz=1,tar=1,bz2=1,xz=1,["7z"]=1,mp3=1,mp4=1,mov=1,wav=1,flac=1,bin=1,
  exe=1,dll=1,so=1,dylib=1,o=1,a=1,class=1,jar=1,wasm=1,ttf=1,otf=1,woff=1,
  woff2=1,db=1,sqlite=1,lock=1 }

local function code_skip_ext(path)
  local ext = path:match("%.([%w]+)$")
  return ext ~= nil and CODE_SKIP_EXT[ext:lower()] ~= nil
end

-- The files to index: git's own list (tracked + untracked-not-ignored) when this
-- is a repo -- it respects .gitignore and skips build junk for free -- else a
-- bounded recursive walk that skips the usual noise dirs. The git call is
-- pcall'd because proc.run yields, which is only valid under the scheduler; a
-- --eval/headless context falls through to the walk.
local function code_file_list()
  local ok, r = pcall(function()
    return require("proc").run("git ls-files --cached --others --exclude-standard 2>/dev/null", 30)
  end)
  if ok and r and r.code == 0 and type(r.out) == "string" and r.out:match("%S") then
    local files = {}
    for line in r.out:gmatch("[^\n]+") do files[#files + 1] = line end
    return files
  end
  local files, stack = {}, { "." }
  while #stack > 0 and #files < CODE_MAX_FILES do
    local dir = table.remove(stack)
    for _, name in ipairs(sys.listdir(dir) or {}) do
      local p = (dir == ".") and name or (dir .. "/" .. name)
      local kind = sys.stat(p)
      if kind == "dir" then
        if not CODE_SKIP_DIR[name] then stack[#stack + 1] = p end
      elseif kind == "file" then
        files[#files + 1] = p
      end
    end
  end
  return files
end

-- Rebuild/refresh the code index. opts.rebuild wipes it first; otherwise it is
-- incremental by mtime. Returns { indexed, skipped, total }.
function M.code_reindex(opts)
  opts = opts or {}
  bog.db:exec(CODE_FTS)
  bog.db:exec(CODE_META)
  if opts.rebuild then
    bog.db:run("DELETE FROM code_fts")
    bog.db:run("DELETE FROM code_meta")
  end
  local indexed, skipped, total = 0, 0, 0
  for _, path in ipairs(code_file_list()) do
    total = total + 1
    if total > CODE_MAX_FILES then break end
    local kind, mtime, size = sys.stat(path)
    if kind ~= "file" or code_skip_ext(path) or (size and size > CODE_MAX_BYTES) then
      skipped = skipped + 1
    else
      local prev = bog.db:query("SELECT mtime, rowid FROM code_meta WHERE path=?", { path })[1]
      if prev and not opts.rebuild and tonumber(prev.mtime) == math.floor(mtime or 0) then
        skipped = skipped + 1
      else
        local data = bog.util.read_file(path)
        if not data or data:find("\0", 1, true) then
          skipped = skipped + 1
        else
          if prev then bog.db:run("DELETE FROM code_fts WHERE rowid=?", { prev.rowid }) end
          local ins = bog.db:run("INSERT INTO code_fts(path, body) VALUES(?, ?)", { path, data })
          bog.db:run("INSERT OR REPLACE INTO code_meta(path, mtime, rowid) VALUES(?, ?, ?)",
            { path, math.floor(mtime or 0), ins.rowid })
          indexed = indexed + 1
        end
      end
    end
  end
  return { indexed = indexed, skipped = skipped, total = total }
end

-- How many files the native index currently holds (0 = never built).
function M.code_index_count()
  local ok = pcall(function() bog.db:exec(CODE_META) end)
  if not ok then return 0 end
  local r = bog.db:query("SELECT COUNT(*) AS n FROM code_meta")
  return (r and r[1] and tonumber(r[1].n)) or 0
end

-- Ranked bm25 search over the index. Returns { { path, score, snippet }, ... },
-- best match first (bm25 is smaller-is-better, so it is negated).
function M.code_search(query, n)
  bog.db:exec(CODE_FTS)
  local fq = fts_query(query or "")
  if not fq then return {} end
  return bog.db:query(
    "SELECT path, -bm25(code_fts) AS score, "
    .. "snippet(code_fts, 1, '>>>', '<<<', ' … ', 12) AS snippet "
    .. "FROM code_fts WHERE code_fts MATCH ? ORDER BY score DESC LIMIT ?",
    { fq, n or 12 })
end

-- ---- sessions --------------------------------------------------------------
function M.sess_create(title, model, project)
  local p = proj_or_global(project)
  local r
  if p then
    r = bog.db:run(
      "INSERT INTO sessions(title,model,created,updated,messages,project) VALUES(?,?,?,?, '[]',?)",
      { title or "", model or "", now(), now(), p })
  else
    r = bog.db:run(
      "INSERT INTO sessions(title,model,created,updated,messages,project) VALUES(?,?,?,?, '[]',NULL)",
      { title or "", model or "", now(), now() })
  end
  fts_index_session(r.rowid)
  return r.rowid
end

-- Move a chat into a project (or into global with no name). Retroactive by
-- design: you often only realise a conversation belonged to a body of work
-- after having it.
function M.sess_assign(id, project)
  local p = proj_or_global(project)
  local r
  if p then r = bog.db:run("UPDATE sessions SET project=?, updated=? WHERE id=?", { p, now(), id })
  else r = bog.db:run("UPDATE sessions SET project=NULL, updated=? WHERE id=?", { now(), id }) end
  return (r.changes or 0) > 0
end

function M.sess_save(id, title, model, messages)
  local ok, encoded = pcall(json.encode, messages)
  if not ok then encoded = "[]" end
  local res = bog.db:run("UPDATE sessions SET title=?, model=?, updated=?, messages=? WHERE id=?",
    { title, model, now(), encoded, id })
  fts_index_session(id)
  return res
end

function M.sess_load(id)
  local r = bog.db:query("SELECT id,title,model,messages FROM sessions WHERE id=?", { id })
  local s = r[1]
  if not s then return nil end
  local ok, msgs = pcall(json.decode, s.messages or "[]")
  s.messages = ok and msgs or {}
  return s
end

-- Recent chats for a project: its own, then global's underneath -- the same
-- own-first rule memory follows, so the recents list matches what the agent
-- can actually see.
function M.sess_list(limit, project)
  local p = proj_or_global(project)
  if p then
    return bog.db:query(
      "SELECT id,title,model,updated,project FROM sessions "
      .. "WHERE (project=? OR project IS NULL) "
      .. "ORDER BY (project IS NULL), updated DESC LIMIT ?", { p, limit or 20 })
  end
  return bog.db:query(
    "SELECT id,title,model,updated,project FROM sessions WHERE project IS NULL "
    .. "ORDER BY updated DESC LIMIT ?", { limit or 20 })
end

-- Remove session rows that hold nothing at all.
--
-- Sessions used to be created the moment a conversation was STARTED rather than
-- when it had content, so every launch, every `/new` and every service start
-- left a blank row behind. Those rows carry no title, no transcript and no
-- lineage: deleting one loses literally nothing, which is why this can run
-- unattended where a general "tidy up old sessions" could not.
--
-- The guards are what keep it safe. A row is only junk if it has no messages,
-- no title, no parent (so it is not an agent's thread) and is not marked
-- running (so it is not an agent mid-flight). Anything a person or an agent put
-- a single word into is left alone.
function M.prune_empty_sessions()
  if not bog.db then return 0 end
  local sql = "FROM sessions WHERE (messages IS NULL OR messages = '[]') "
    .. "AND (title IS NULL OR title = '') AND parent_id IS NULL "
    .. "AND (status IS NULL OR status <> 'running')"
  local rows = bog.db:query("SELECT id " .. sql)
  if #rows == 0 then return 0 end
  for _, r in ipairs(rows) do
    bog.db:run("DELETE FROM sessions_fts WHERE rowid=?", { r.id })
  end
  bog.db:run("DELETE " .. sql)
  return #rows
end

function M.sess_delete(id)
  bog.db:run("DELETE FROM sessions_fts WHERE rowid=?", { id })
  return bog.db:run("DELETE FROM sessions WHERE id=?", { id })
end

-- Full-text search over session titles and transcripts, best match first. Rows
-- come back in the exact shape sess_list returns (id, title, model, updated) so
-- the sidebar can render a hit identically to a recent and open it the same
-- way. Title is weighted above body via bm25; an empty or word-less query falls
-- through to plain recents. bm25() is smaller-is-better, hence ascending.
function M.sess_search(query, limit)
  if not query or query:match("^%s*$") then return M.sess_list(limit or 40) end
  local fq = fts_query(query)
  if not fq then return {} end
  return bog.db:query(
    "SELECT s.id AS id, s.title AS title, s.model AS model, s.updated AS updated "
    .. "FROM sessions_fts f JOIN sessions s ON s.id = f.rowid "
    .. "WHERE sessions_fts MATCH ? ORDER BY bm25(sessions_fts, 5.0, 1.0), s.updated DESC "
    .. "LIMIT ?",
    { fq, limit or 40 })
end

-- ---- threads / agents (a session row + swarm columns) ----------------------
-- opts: { parent_id?, title?, model?, spec? (table), status? }
function M.thread_create(opts)
  opts = opts or {}
  local r = bog.db:run(
    "INSERT INTO sessions(title,model,created,updated,messages,parent_id,status,subscriptions,spec) "
    .. "VALUES(?,?,?,?, '[]', ?, ?, '[]', ?)",
    { opts.title, opts.model, now(), now(), opts.parent_id,
      opts.status or "running", opts.spec and json.encode(opts.spec) or nil })
  fts_index_session(r.rowid)
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
  local res = bog.db:run("UPDATE sessions SET " .. table.concat(sets, ", ") .. " WHERE id=?", vals)
  fts_index_session(id)
  return res
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

-- ---- records (the append-only envelope: telemetry spans + decisions) --------
-- Written synchronously via the normal connection (unlike the bus journal, which
-- the C writer thread owns). Callers aggregate to turn/tool boundaries, so the
-- write rate is low and a per-event INSERT never hammers the store.
function M.record_append(kind, f)
  f = f or {}
  -- No interior nils in the params array: a nil hole makes Lua's `#` (and so the
  -- C binder's luaL_len) miscount and bind the row wrong. Absent parent_id -> 0
  -- ("no parent"), absent payload -> "" -- a dense 6-element array binds cleanly.
  return bog.db:run(
    "INSERT INTO records(ts,run_id,agent_id,parent_id,kind,payload) VALUES(?,?,?,?,?,?)",
    { now(), f.run_id or 0, f.agent_id or 0, f.parent_id or 0, kind,
      f.payload ~= nil and json.encode(f.payload) or "" })
end

function M.records_for(run_id, limit)
  return bog.db:query("SELECT id,ts,run_id,agent_id,parent_id,kind,payload FROM records "
    .. "WHERE run_id=? ORDER BY id LIMIT ?", { run_id, limit or 100000 })
end

function M.records_recent(limit)
  return bog.db:query("SELECT id,ts,run_id,agent_id,parent_id,kind,payload FROM records "
    .. "ORDER BY id DESC LIMIT ?", { limit or 200 })
end

return M
