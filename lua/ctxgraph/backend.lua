-- ctxgraph/backend.lua -- the storage port for graph memory.
--
-- Everything that decides WHAT goes in the graph (ingest, entity rules, spans,
-- stubs, the outline, compaction, the expand/graph_recall/note tools, auto-expand,
-- telemetry) lives in core and talks only to this port. A backend decides how
-- records are stored, searched and exported. The default is lua/ctxgraph/
-- sqlite.lua, deliberately minimal: one graph per conversation in the local
-- store, FTS5 text search ranked by recency, nothing shared across sessions.
-- A richer backend (scored retrieval, named graphs, promotion) is registered
-- at runtime by an extension:
--
--   require("ctxgraph").register_backend("mine", impl)
--
-- or by shipping a module `ctxgraph.backends.<name>` on the overlay path
-- (~/.boggart/lua/ctxgraph/backends/<name>.lua) that returns `impl`. It is
-- then selected with BOGGART_MEMORY=<name>.
--
-- ---- records (LOKF-shaped) --------------------------------------------------
-- Every node crosses the port as one record:
--
--   id          string, unique within the session's graph ("s/7/step/3",
--               "file/src/a.c", "file/src/a.c@v2", "claim/1f0c...")
--   type        step | reasoning | span | thread | compaction |
--               file | version | package | command | test | error | claim
--   title       one line, human-readable
--   stub        the outline line for this node (rule-made, byte-stable)
--   links       array of { type = <edge type>, dst = <id> }, typed out-links
--   frontmatter table of scalar fields (strings, numbers, booleans), the
--               record's YAML frontmatter
--   body        string or nil: the full content
--   body_ref    string or nil: where content too big for body lives (a path
--               the harness wrote with util.shape_result)
--   raw         string or nil: the transcript messages the record came from
--               (JSON), so collapsing a conversation deletes nothing
--   digest      sha256 of the body (or of the canonical fields when no body)
--   state       claims only: unverified | reproduced | refuted
--   seq         integer, ingest order within the session (recency)
--   tokens      integer estimate of the body's size
--
-- Events (step, reasoning, span, thread, compaction) never change once put,
-- with one exception: a thread is put again when its child's answer is seen
-- (an await's result), with the answer folded into its body, stub and
-- frontmatter (returned, returned_ok, returned_step). Its id and seq stay.
-- Entities (file, package, command, test, error) are replaced in place as new
-- versions or observations arrive; their history is in version records and
-- links. Claims only add; set_claim_state is the one mutation they allow.
-- Once a graph has been forked, a record core replaces in place also carries
-- two frontmatter fields, opaque to a backend: `useq` (the seq of the batch
-- that last changed it) and `asof` (a JSON string: the earlier states a fork
-- saw). Core reads them to give a fork its parent's records as of the fork
-- (lua/ctxgraph/ingest.lua M.snapshot); a backend stores them like any field.
--
-- ---- operations ---------------------------------------------------------------
-- `sid` is the conversation's key (a string). Every operation is scoped to it:
-- a backend must never return another session's records from these calls.
--
--   put_nodes(sid, records)            insert or replace, as one batch; each
--                                       record's links are stored as its edges.
--                                       Core calls it once per compaction and
--                                       once per tool round (live ingest), with
--                                       a batch's edges carried as links, so
--                                       put_edges is rarely needed. A tool
--                                       round's port traffic in steady state:
--                                       one put_nodes, one meta write ("graph"),
--                                       a get per entity the round touches
--   put_edges(sid, edges)              add { src, type, dst } links (idempotent)
--   get(sid, id) -> record | nil       with its links
--   children(sid, id, type?) -> {record}   records `id` links to (by edge type),
--                                       in seq order
--   referrers(sid, id, type?) -> {record}  records that link to `id`, seq order
--   versions(sid, entity_id) -> {record}   version records of an entity, oldest
--                                       first
--   scan(sid, types?) -> {record}      every record (of these types), seq order
--   search(sid, query, opts) -> {hit}  text search; opts = { limit, types };
--                                       hit = { id, type, stub, seq, score? },
--                                       best first. Ranking is the backend's.
--   record_claim(sid, claim) -> id, created   add a claim record unless one with
--                                       its id exists (claims only add)
--   set_claim_state(sid, id, state) -> true | nil, err
--   meta(sid, key, value?) -> value    small per-session state; with a value,
--                                       stores it (strings only). Values are
--                                       opaque to a backend. Keys core uses:
--                                       "graph"  the graph's state, one JSON
--                                         value (counters, live step ranges,
--                                         a fork's parent chain); read once
--                                         per session per process, written at
--                                         most once per tool round and once
--                                         per compaction or note. Its size does
--                                         not grow with the conversation.
--                                       "thread_agent/<agent id>"  a spawned
--                                         child's thread record id; written
--                                         when a spawn is ingested, read when
--                                         its answer is seen.
--                                       Older graphs used "seq", "steps",
--                                       "spans", "threads", "compactions",
--                                       "live" and "parent_graph"; core reads
--                                       them only when "graph" is missing (and
--                                       probes "seq" once to find out), and
--                                       never writes them again.
--   export_bundle(sid) -> { records = {record...} }   the whole graph, for a
--                                       LOKF bundle (lua/ctxgraph/export.lua)
--
-- Optional: `name` (string), `available() -> bool, why` (false when its
-- substrate is missing; the tier is then refused rather than half-run).
local M = {}

M.OPS = { "put_nodes", "put_edges", "get", "children", "referrers", "versions",
          "scan", "search", "record_claim", "set_claim_state", "meta", "export_bundle" }

M.EVENT_TYPES = { step = true, reasoning = true, span = true, thread = true, compaction = true }
M.ENTITY_TYPES = { file = true, version = true, package = true, command = true, test = true, error = true }
M.CLAIM_STATES = { unverified = true, reproduced = true, refuted = true }

-- Does `impl` implement the port? -> true | nil, "missing: a, b"
function M.check(impl)
  if type(impl) ~= "table" then return nil, "a backend is a table of functions" end
  local missing = {}
  for _, op in ipairs(M.OPS) do
    if type(impl[op]) ~= "function" then missing[#missing + 1] = op end
  end
  if #missing > 0 then return nil, "missing: " .. table.concat(missing, ", ") end
  return true
end

-- Is `r` a well-formed record? -> true | nil, why. Used by the contract test
-- and by put paths in debug builds; cheap enough to run on every record.
function M.valid_record(r)
  if type(r) ~= "table" then return nil, "not a table" end
  if type(r.id) ~= "string" or r.id == "" then return nil, "id" end
  if type(r.type) ~= "string" or not (M.EVENT_TYPES[r.type] or M.ENTITY_TYPES[r.type] or r.type == "claim") then
    return nil, "type " .. tostring(r.type)
  end
  if type(r.title) ~= "string" then return nil, "title" end
  if r.links ~= nil and type(r.links) ~= "table" then return nil, "links" end
  if r.frontmatter ~= nil and type(r.frontmatter) ~= "table" then return nil, "frontmatter" end
  if r.type == "claim" and not M.CLAIM_STATES[r.state or ""] then return nil, "claim state" end
  if type(r.digest) ~= "string" or #r.digest ~= 64 then return nil, "digest" end
  return true
end

return M
