-- ctxgraph/sqlite.lua -- the minimal graph-memory backend: the `local` tier.
--
-- One graph per conversation in the local store (bog.db), keyed by session.
-- Text search is FTS5 over title, stub and body, and matches are ranked by
-- recency (newest first), nothing cleverer. There are no cross-session reads,
-- no relevance scoring and no promotion: those are what a richer backend
-- registered through the port (lua/ctxgraph/backend.lua) is for.
--
-- The tables are created on first use rather than in store.lua's SCHEMA, so
-- the backend owns its storage the way any other backend would; they are
-- additive (CREATE ... IF NOT EXISTS), so an older binary that does not know
-- them simply never reads them.
local json = require("json")

local M = { name = "sqlite" }

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS ctx_nodes (
  session TEXT NOT NULL, id TEXT NOT NULL,
  type TEXT NOT NULL, title TEXT, stub TEXT,
  frontmatter TEXT,          -- JSON object
  body TEXT, body_ref TEXT,
  raw TEXT,                  -- JSON: the transcript messages behind the node
  digest TEXT, state TEXT,
  seq INTEGER, tokens INTEGER, created INTEGER,
  PRIMARY KEY (session, id)
);
CREATE INDEX IF NOT EXISTS ctx_nodes_type ON ctx_nodes(session, type, seq);
CREATE TABLE IF NOT EXISTS ctx_edges (
  session TEXT NOT NULL, src TEXT NOT NULL, type TEXT NOT NULL, dst TEXT NOT NULL,
  PRIMARY KEY (session, src, type, dst)
);
CREATE INDEX IF NOT EXISTS ctx_edges_dst ON ctx_edges(session, dst, type);
CREATE TABLE IF NOT EXISTS ctx_meta (
  session TEXT NOT NULL, key TEXT NOT NULL, value TEXT,
  PRIMARY KEY (session, key)
);
]]
-- A plain (not external-content) FTS5 table whose rowid is the ctx_nodes
-- rowid, so a replaced node is re-indexed with one DELETE and one INSERT.
local FTS = "CREATE VIRTUAL TABLE IF NOT EXISTS ctx_fts USING fts5(title, body)"

-- Bind parameters that may contain nils. ldb binds 1..#params, and # of a
-- table with holes is any border, so a nil body_ref could silently unbind
-- every later column. An explicit length makes the holes NULLs.
local function P(...)
  local t = table.pack(...)
  return setmetatable(t, { __len = function() return t.n end })
end

local ready_for = nil   -- the connection the schema was ensured on
M.fts = nil             -- true when FTS5 is in use, false on the LIKE fallback

local function conn()
  local c = bog.db
  if not c then
    if bog.store and bog.store.open then bog.store.open() end
    c = bog.db
  end
  assert(c, "ctxgraph/sqlite: the local store is not open")
  if ready_for ~= c then
    assert(c:exec(SCHEMA))
    M.fts = c:exec(FTS) and true or false
    ready_for = c
  end
  return c
end

function M.available()
  local ok, err = pcall(conn)
  if not ok then return false, tostring(err) end
  return true
end

local function row_to_record(c, sid, r)
  if not r then return nil end
  local fm = {}
  if r.frontmatter and r.frontmatter ~= "" then
    local ok, t = pcall(json.decode, r.frontmatter)
    if ok and type(t) == "table" then fm = t end
  end
  local links = {}
  for _, e in ipairs(c:query("SELECT type, dst FROM ctx_edges WHERE session=? AND src=? ORDER BY type, dst",
                             { sid, r.id }) or {}) do
    links[#links + 1] = { type = e.type, dst = e.dst }
  end
  return { id = r.id, type = r.type, title = r.title or "", stub = r.stub or "",
           frontmatter = fm, body = r.body, body_ref = r.body_ref, raw = r.raw,
           digest = r.digest, state = r.state, seq = r.seq, tokens = r.tokens,
           created = r.created, links = links }
end

local COLS = "id, type, title, stub, frontmatter, body, body_ref, raw, digest, state, seq, tokens, created"

local function index(c, rowid, r)
  if not M.fts then return end
  c:run("DELETE FROM ctx_fts WHERE rowid=?", { rowid })
  c:run("INSERT INTO ctx_fts(rowid, title, body) VALUES (?,?,?)",
        { rowid, (r.title or "") .. "\n" .. (r.stub or ""), r.body or "" })
end

local function put_one(c, sid, r)
  local fm = json.encode(r.frontmatter or {})
  local have = c:query("SELECT rowid AS rid FROM ctx_nodes WHERE session=? AND id=?", { sid, r.id })[1]
  local rowid
  if have then
    assert(c:run("UPDATE ctx_nodes SET type=?, title=?, stub=?, frontmatter=?, body=?, body_ref=?, raw=?, "
      .. "digest=?, state=?, seq=?, tokens=?, created=? WHERE rowid=?",
      P(r.type, r.title, r.stub, fm, r.body, r.body_ref, r.raw, r.digest, r.state,
        r.seq, r.tokens, r.created, have.rid)))
    rowid = have.rid
  else
    local res = assert(c:run("INSERT INTO ctx_nodes(session, " .. COLS .. ") VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
      P(sid, r.id, r.type, r.title, r.stub, fm, r.body, r.body_ref, r.raw, r.digest, r.state,
        r.seq, r.tokens, r.created or os.time())))
    rowid = res.rowid
  end
  index(c, rowid, r)
  for _, l in ipairs(r.links or {}) do
    c:run("INSERT OR IGNORE INTO ctx_edges(session, src, type, dst) VALUES (?,?,?,?)", { sid, r.id, l.type, l.dst })
  end
end

-- One savepoint per batch: a compaction writes its records atomically or not
-- at all, and a savepoint nests inside whatever transaction the caller holds.
local function batch(c, fn)
  assert(c:exec("SAVEPOINT ctxgraph"))
  local ok, err = pcall(fn)
  if ok then assert(c:exec("RELEASE ctxgraph"))
  else c:exec("ROLLBACK TO ctxgraph"); c:exec("RELEASE ctxgraph"); error(err, 0) end
end

function M.put_nodes(sid, records)
  local c = conn()
  batch(c, function() for _, r in ipairs(records) do put_one(c, sid, r) end end)
  return true
end

function M.put_edges(sid, edges)
  local c = conn()
  batch(c, function()
    for _, e in ipairs(edges) do
      c:run("INSERT OR IGNORE INTO ctx_edges(session, src, type, dst) VALUES (?,?,?,?)", { sid, e.src, e.type, e.dst })
    end
  end)
  return true
end

function M.get(sid, id)
  local c = conn()
  return row_to_record(c, sid, c:query("SELECT " .. COLS .. " FROM ctx_nodes WHERE session=? AND id=?", { sid, id })[1])
end

local function many(c, sid, sql, params)
  local out = {}
  for _, r in ipairs(c:query(sql, params) or {}) do out[#out + 1] = row_to_record(c, sid, r) end
  return out
end

local NCOLS = "n.id, n.type, n.title, n.stub, n.frontmatter, n.body, n.body_ref, n.raw, n.digest, n.state, n.seq, n.tokens, n.created"

function M.children(sid, id, etype)
  local c = conn()
  return many(c, sid, "SELECT DISTINCT " .. NCOLS .. " FROM ctx_edges e JOIN ctx_nodes n ON n.session=e.session AND n.id=e.dst "
    .. "WHERE e.session=? AND e.src=? AND (? IS NULL OR e.type=?) ORDER BY n.seq, n.id", P(sid, id, etype, etype))
end

function M.referrers(sid, id, etype)
  local c = conn()
  return many(c, sid, "SELECT DISTINCT " .. NCOLS .. " FROM ctx_edges e JOIN ctx_nodes n ON n.session=e.session AND n.id=e.src "
    .. "WHERE e.session=? AND e.dst=? AND (? IS NULL OR e.type=?) ORDER BY n.seq, n.id", P(sid, id, etype, etype))
end

function M.versions(sid, entity_id)
  local c = conn()
  return many(c, sid, "SELECT DISTINCT " .. NCOLS .. " FROM ctx_edges e JOIN ctx_nodes n ON n.session=e.session AND n.id=e.src "
    .. "WHERE e.session=? AND e.dst=? AND e.type='version_of' ORDER BY n.seq, n.id", { sid, entity_id })
end

function M.scan(sid, types)
  local c = conn()
  if types and #types > 0 then
    local q = {}
    for i = 1, #types do q[i] = "?" end
    local params = { sid }
    for _, t in ipairs(types) do params[#params + 1] = t end
    return many(c, sid, "SELECT " .. COLS .. " FROM ctx_nodes WHERE session=? AND type IN (" .. table.concat(q, ",")
      .. ") ORDER BY seq, id", params)
  end
  return many(c, sid, "SELECT " .. COLS .. " FROM ctx_nodes WHERE session=? ORDER BY seq, id", { sid })
end

-- Words only: FTS5 query syntax (quotes, NEAR, column filters, `-`) is not
-- something a model's free-text query should be able to trip over.
local function words(q)
  local out = {}
  for w in tostring(q or ""):gmatch("[%w_]+") do out[#out + 1] = w end
  return out
end

function M.search(sid, query, opts)
  opts = opts or {}
  local c = conn()
  local limit = math.max(1, math.min(tonumber(opts.limit) or 8, 50))
  local ws = words(query)
  if #ws == 0 then return {} end
  local typeset
  if opts.types and #opts.types > 0 then
    typeset = {}
    for _, t in ipairs(opts.types) do typeset[t] = true end
  end
  local rows
  if M.fts then
    local quoted = {}
    for i, w in ipairs(ws) do quoted[i] = '"' .. w .. '"' end
    -- every word first; if nothing has them all, any of them
    for _, joiner in ipairs({ " ", " OR " }) do
      rows = c:query("SELECT n.id, n.type, n.stub, n.seq FROM ctx_fts f JOIN ctx_nodes n ON n.rowid=f.rowid "
        .. "WHERE ctx_fts MATCH ? AND n.session=? ORDER BY n.seq DESC, n.id LIMIT ?",
        { table.concat(quoted, joiner), sid, limit * 4 }) or {}
      if #rows > 0 then break end
    end
  else
    local cond, params = {}, { sid }
    for _, w in ipairs(ws) do
      cond[#cond + 1] = "(title LIKE ? OR stub LIKE ? OR body LIKE ?)"
      local p = "%" .. w .. "%"
      params[#params + 1] = p; params[#params + 1] = p; params[#params + 1] = p
    end
    params[#params + 1] = limit * 4
    rows = c:query("SELECT id, type, stub, seq FROM ctx_nodes WHERE session=? AND " .. table.concat(cond, " AND ")
      .. " ORDER BY seq DESC, id LIMIT ?", params) or {}
  end
  local out = {}
  for _, r in ipairs(rows) do
    if not typeset or typeset[r.type] then
      out[#out + 1] = { id = r.id, type = r.type, stub = r.stub or "", seq = r.seq }
      if #out >= limit then break end
    end
  end
  return out
end

function M.record_claim(sid, claim)
  local c = conn()
  if c:query("SELECT 1 AS x FROM ctx_nodes WHERE session=? AND id=?", { sid, claim.id })[1] then
    return claim.id, false
  end
  M.put_nodes(sid, { claim })
  return claim.id, true
end

function M.set_claim_state(sid, id, state)
  local c = conn()
  local r = c:run("UPDATE ctx_nodes SET state=? WHERE session=? AND id=? AND type='claim'", { state, sid, id })
  if not r or r.changes == 0 then return nil, "no claim " .. tostring(id) end
  return true
end

function M.meta(sid, key, value)
  local c = conn()
  if value ~= nil then
    c:run("INSERT INTO ctx_meta(session, key, value) VALUES (?,?,?) "
      .. "ON CONFLICT(session, key) DO UPDATE SET value=excluded.value", { sid, key, tostring(value) })
    return tostring(value)
  end
  local r = c:query("SELECT value FROM ctx_meta WHERE session=? AND key=?", { sid, key })[1]
  return r and r.value or nil
end

function M.export_bundle(sid)
  return { records = M.scan(sid) }
end

return M
