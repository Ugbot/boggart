-- ctxgraph.lua -- graph memory: compaction into a knowledge graph.
--
-- The context window becomes a rendered view of a graph. At a compaction the
-- old part of the conversation is ingested as records (steps, spans, files,
-- packages, commands, tests, errors, claims) and replaced by an outline of
-- stub lines that name them; the most recent tail stays in full. `expand`
-- brings any record back, `graph_recall` searches them, `note` records a claim.
-- Compaction makes no model call: stubs are rules.
--
-- One setting picks the memory tier (lua/runflags.lua validates it):
--
--   BOGGART_MEMORY / --memory / sess.memory
--     summary   prose-summary compaction (the default)
--     local     graph memory on the minimal SQLite backend (lua/ctxgraph/sqlite.lua)
--     <name>    graph memory on a backend an extension registered as <name>
--
-- Lower-level overrides, for experiments: BOGGART_COMPACT=summary|graph and
-- BOGGART_GRAPH_BACKEND=<name> (default sqlite). BOGGART_MEMORY wins when both
-- are set and disagree, and the conflict is logged.
--
-- Storage sits behind the port in lua/ctxgraph/backend.lua; everything here
-- calls only that port.
local port = require("ctxgraph.backend")
local events = require("events")
local json = require("json")

local M = {}

M.TIERS = { summary = true, ["local"] = true }
-- Tiers this release knows will be provided by an extension, so asking for one
-- that is not installed says "not installed" rather than "unknown value".
M.EXTENSION_TIERS = { gestalt = true }
M.BUILTIN_BACKENDS = { sqlite = "ctxgraph.sqlite" }

M.AUTOEXPAND_MAX = 2          -- nodes per step (assumption 15)
M.AUTOEXPAND_TOKENS = 4000    -- budget per step for those nodes
M.OUTLINE_MAX_TOKENS = 8000   -- the outline's own cap, before the share rule
M.OUTLINE_SHARE = 0.15        -- ...and at most this share of the threshold

-- Registrations hang off `bog` so a /reload keeps an extension's backend.
local function state()
  local holder = rawget(_G, "bog")
  local st = holder and rawget(holder, "__ctxgraph")
  if not st then
    st = { backends = {}, warned = {} }
    if holder then holder.__ctxgraph = st end
  end
  return st
end

-- ---- backends -----------------------------------------------------------------

function M.register_backend(name, impl)
  if type(name) ~= "string" or not name:match("^[%w_%-]+$") then
    return nil, "a backend name is letters, digits, _ and -"
  end
  if M.TIERS[name] then return nil, "'" .. name .. "' is a built-in tier, not a backend name" end
  local ok, err = port.check(impl)
  if not ok then return nil, "backend '" .. name .. "' does not implement the port (" .. err .. ")" end
  state().backends[name] = impl
  return true
end

function M.unregister_backend(name) state().backends[name] = nil end

-- The backend called `name`: registered, built in, or a module on the overlay
-- path (ctxgraph.backends.<name>) that registers itself or returns its impl.
-- -> impl | nil, why
function M.get_backend(name)
  local st = state()
  if st.backends[name] then return st.backends[name] end
  local mod = M.BUILTIN_BACKENDS[name]
  if mod then
    local impl = require(mod)
    st.backends[name] = impl
    return impl
  end
  if type(name) == "string" and name:match("^[%w_%-]+$") then
    local ok, got = pcall(require, "ctxgraph.backends." .. name)
    if ok then
      if st.backends[name] then return st.backends[name] end
      if type(got) == "table" and port.check(got) then st.backends[name] = got; return got end
    end
  end
  return nil, "no graph backend '" .. tostring(name) .. "' is installed"
end

function M.backend_names()
  local names = {}
  for n in pairs(state().backends) do names[#names + 1] = n end
  for n in pairs(M.BUILTIN_BACKENDS) do if not state().backends[n] then names[#names + 1] = n end end
  table.sort(names)
  return names
end

-- ---- the tier -------------------------------------------------------------------

-- resolve(value, getenv) -> { memory, mode, backend } | nil, err, kind
-- `value` is the memory setting (nil: read BOGGART_MEMORY, then the
-- lower-level overrides). kind is "unknown" or "not_installed".
function M.resolve(value, getenv)
  getenv = getenv or os.getenv
  local from = "--memory"
  if value == nil or value == "" then value, from = getenv("BOGGART_MEMORY"), "BOGGART_MEMORY" end
  local low_mode = getenv("BOGGART_COMPACT")
  local low_backend = getenv("BOGGART_GRAPH_BACKEND")
  if low_mode == "" then low_mode = nil end
  if low_backend == "" then low_backend = nil end
  if value == nil or value == "" then
    if low_mode == "graph" then
      local b = low_backend or "sqlite"
      if not M.get_backend(b) then
        return nil, "BOGGART_GRAPH_BACKEND: graph backend '" .. b .. "' is not installed", "not_installed"
      end
      return { memory = b == "sqlite" and "local" or b, mode = "graph", backend = b }
    end
    if low_mode ~= nil and low_mode ~= "summary" then
      return nil, string.format("BOGGART_COMPACT: %q is not a compaction mode (summary|graph)", low_mode), "unknown"
    end
    return { memory = "summary", mode = "summary" }
  end
  local v = tostring(value):lower()
  local out
  if v == "summary" then out = { memory = "summary", mode = "summary" }
  elseif v == "local" then out = { memory = "local", mode = "graph", backend = "sqlite" }
  elseif M.get_backend(v) and not M.BUILTIN_BACKENDS[v] then out = { memory = v, mode = "graph", backend = v }
  elseif M.EXTENSION_TIERS[v] then
    return nil, string.format("%s: memory tier '%s' needs a graph backend named '%s', and none is installed "
      .. "(an extension registers it; see lua/ctxgraph/backend.lua)", from, v, v), "not_installed"
  else
    local accepted = { "summary", "local" }
    for n in pairs(M.EXTENSION_TIERS) do accepted[#accepted + 1] = n end
    for _, n in ipairs(M.backend_names()) do
      if not M.BUILTIN_BACKENDS[n] and not M.EXTENSION_TIERS[n] then accepted[#accepted + 1] = n end
    end
    table.sort(accepted, function(a, b)
      local order = { summary = 1, ["local"] = 2 }
      return (order[a] or 3) < (order[b] or 3) or ((order[a] or 3) == (order[b] or 3) and a < b)
    end)
    return nil, string.format("%s: %q is not a memory tier (%s, or the name of a registered graph backend)",
      from, value, table.concat(accepted, "|")), "unknown"
  end
  local impl = M.get_backend(out.backend or "")
  if out.backend and impl and impl.available then
    local ok, why = impl.available()
    if not ok then return nil, from .. ": graph backend '" .. out.backend .. "' is unavailable: " .. tostring(why), "not_installed" end
  end
  -- the lower-level switches lose to the tier, loudly
  local disagree = (low_mode and low_mode ~= out.mode)
    or (low_backend and out.backend and low_backend ~= out.backend)
  if disagree and not state().warned[v] then
    state().warned[v] = true
    local log = rawget(_G, "bog") and bog.log
    if log then
      log(string.format("%s=%s overrides BOGGART_COMPACT=%s BOGGART_GRAPH_BACKEND=%s", from, v,
        tostring(low_mode), tostring(low_backend)))
    end
  end
  return out
end

-- The tier a session runs on. sess.memory (set from --memory/BOGGART_MEMORY by
-- runflags, or by a caller) wins; otherwise the environment. Resolved once per
-- session and cached, so the offered tools cannot flip mid-conversation.
function M.tier(sess)
  if sess and sess._ctxg_tier and sess._ctxg_tier.memory_for == (sess.memory or false) then
    return sess._ctxg_tier
  end
  local t = M.resolve(sess and sess.memory)
  t = t or { memory = "summary", mode = "summary" }
  t.memory_for = sess and sess.memory or false
  if sess then sess._ctxg_tier = t end
  return t
end

function M.enabled(sess) return M.tier(sess).mode == "graph" end

function M.backend(sess)
  local t = M.tier(sess)
  if t.mode ~= "graph" then return nil end
  return assert(M.get_backend(t.backend))
end

function M.sid(sess) return tostring(sess and sess.id or "0") end

-- Per-session runtime state: what is expanded in the live tail, file digests
-- seen at tool time. Not persisted; it is rebuilt from nothing on resume.
function M.rt(sess)
  sess._ctxg = sess._ctxg or { expanded = {}, digests = {} }
  return sess._ctxg
end

-- ---- the read view: this conversation's graph, then the ones it forked from ------
--
-- A forked child (spawn{ fork = true }, lua/fork.lua) starts from a copy of its
-- parent's transcript, outline included, so the ids in that outline name
-- records in the PARENT's graph. The child reads through to the parent's graph
-- for ids it does not hold, read-only and as of the fork: a parent record put
-- after the fork (a higher seq) is not visible. Every write still goes to the
-- child's own graph (M.sid). The chain is kept in the child's own graph meta
-- (key "parent_graph", JSON [{sid, seq}...], nearest parent first), so it
-- survives a resume.
M.PARENT_KEY = "parent_graph"

-- Record that `csess` was forked from `psess`. Called by fork.adopt once the
-- child's tier is set. Nothing to do when either side is not on a graph tier,
-- or when they are on different backends (one cannot read the other).
function M.on_fork(psess, csess)
  if not (psess and csess and M.enabled(psess) and M.enabled(csess)) then return false end
  local pbe, be = M.backend(psess), M.backend(csess)
  if pbe ~= be then return false end
  local psid = M.sid(psess)
  local chain = { { sid = psid, seq = tonumber(pbe.meta(psid, "seq") or "0") or 0 } }
  for _, a in ipairs(M.parents(psess)) do chain[#chain + 1] = { sid = a.sid, seq = a.seq } end
  be.meta(M.sid(csess), M.PARENT_KEY, json.encode(chain))
  M.rt(csess).parents = chain
  return true
end

-- The graphs this conversation was forked from, nearest first: { {sid, seq} }.
function M.parents(sess)
  local rt = M.rt(sess)
  if rt.parents == nil then
    local raw = M.backend(sess).meta(M.sid(sess), M.PARENT_KEY)
    local ok, t = pcall(json.decode, raw or "")
    rt.parents = (ok and type(t) == "table") and t or {}
  end
  return rt.parents
end

-- Where reads look, in order: { { sid, max_seq? } }. The first is the
-- conversation's own graph (no limit); the rest are read-only parents.
function M.sources(sess)
  local out = { { sid = M.sid(sess) } }
  for _, p in ipairs(M.parents(sess)) do out[#out + 1] = { sid = p.sid, max_seq = tonumber(p.seq), parent = true } end
  return out
end

-- Is record (or search hit) `r` visible from source `src`?
function M.visible(r, src)
  return r ~= nil and (src.max_seq == nil or (tonumber(r.seq) or 0) <= src.max_seq)
end

-- The record `id` as this conversation sees it: its own first, then its
-- parents' as of the fork. -> record, source | nil
function M.locate(sess, id)
  local be = M.backend(sess)
  for _, src in ipairs(M.sources(sess)) do
    local r = be.get(src.sid, id)
    if M.visible(r, src) then return r, src end
  end
  return nil
end

-- ---- telemetry ----------------------------------------------------------------
-- Counters on sess.usage.graph (beside usage.compactions), a `graph:<what>`
-- event, and a `graph` record row (bog.store.records) for the bench export.
function M.count(sess, what, data)
  data = data or {}
  sess.usage = sess.usage or { input = 0, output = 0, cached = 0, cache_write = 0, turns = 0 }
  local g = sess.usage.graph or { expands_model = 0, expands_harness = 0, recalls = 0, notes = 0,
                                  compactions = 0, outline_bytes = {} }
  sess.usage.graph = g
  if what == "expand" then
    if data.by == "harness" then g.expands_harness = g.expands_harness + 1 else g.expands_model = g.expands_model + 1 end
  elseif what == "recall" then g.recalls = g.recalls + 1
  elseif what == "note" then g.notes = g.notes + 1
  elseif what == "compacted" then
    g.compactions = g.compactions + 1
    g.outline_bytes[#g.outline_bytes + 1] = data.outline_bytes
  end
  data.session = sess.id
  events.emit("graph:" .. what, data)
  local tel = rawget(_G, "bog") and bog.telemetry
  if tel and tel.graph then
    local d = { event = what }
    for k, v in pairs(data) do d[k] = v end
    pcall(tel.graph, { run_id = sess.id, agent_id = sess.id, parent_id = sess.parent_id }, d)
  end
end

-- ---- compaction -------------------------------------------------------------------

-- compact(sess, msgs, start, task, opts) -> first message, stats
-- Ingests msgs[1..start-1] (skipping an earlier outline) and renders the new
-- outline. The caller (api.compact) keeps msgs[start..] verbatim after it.
function M.compact(sess, msgs, start, task, opts)
  opts = opts or {}
  local be = M.backend(sess)
  local sid = M.sid(sess)
  local ingest = require("ctxgraph.ingest")
  local outline = require("ctxgraph.outline")
  local from = 1
  if msgs[1] and msgs[1].role == "user" and outline.is_outline(msgs[1].content) then from = 2 end
  local root
  do
    local ok, r = pcall(function() return bog.tools.project_root() end)
    root = ok and r or (sys and sys.cwd and sys.cwd()) or nil
  end
  local rt = M.rt(sess)
  local got = ingest.run(be, sid, msgs, from, start - 1, { root = root, digests = rt.digests, now = opts.now })
  local k = ingest.counter(be, sid, "compactions", 1)
  local cid = string.format("s/%s/compaction/%d", sid, k)
  local links = {}
  for _, id in ipairs(got.span_ids) do links[#links + 1] = { type = "collapsed", dst = id } end
  local steps = got.steps
  local crec = { id = cid, type = "compaction", title = "compaction " .. k, links = links,
    seq = tonumber(be.meta(sid, "seq") or "0") + 1, created = opts.now,
    frontmatter = { n = k, first_step = steps[1] and steps[1].n or nil, last_step = steps[#steps] and steps[#steps].n or nil,
                    steps = #steps, spans = #got.span_ids } }
  crec.stub = string.format("compaction %d: %d steps into %d spans", k, #steps, #got.span_ids)
  crec.digest = require("ctxgraph.extract").sha(cid .. "\0" .. crec.stub)
  crec.tokens = 0
  be.meta(sid, "seq", tostring(crec.seq))
  got.records[#got.records + 1] = crec
  be.put_nodes(sid, got.records)
  be.put_edges(sid, got.edges)

  local cap = math.max(1000, math.min(M.OUTLINE_MAX_TOKENS, math.floor((opts.threshold or 100000) * M.OUTLINE_SHARE)))
  local inherit = {}
  for i, src in ipairs(M.sources(sess)) do if i > 1 then inherit[#inherit + 1] = src end end
  local text, ost = outline.render(be, sid, task, { cap_tokens = cap, inherit = inherit })
  if start <= #msgs then text = text .. "\n\n" .. outline.CONTINUES end
  -- the outline changed: everything is collapsed again
  rt.expanded, rt.digests = {}, {}
  rt.index = nil
  local stats = { compaction = cid, steps = #steps, spans = #got.span_ids, records = #got.records,
                  outline_bytes = #text, outline_lines = ost.lines, dropped = ost.dropped }
  M.count(sess, "compacted", { compaction = cid, steps = stats.steps, spans = stats.spans,
    records = stats.records, outline_bytes = stats.outline_bytes, outline_lines = stats.outline_lines,
    dropped = stats.dropped })
  return text, stats
end

return M
