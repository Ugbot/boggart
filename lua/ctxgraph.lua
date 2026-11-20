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

-- The built-in tiers. Any other value names a graph backend: one registered
-- with register_backend, or a module ctxgraph.backends.<name> on the Lua path.
M.TIERS = { summary = true, ["local"] = true }
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
  elseif not M.BUILTIN_BACKENDS[v] and v:match("^[%w_%-]+$") and M.get_backend(v) then
    out = { memory = v, mode = "graph", backend = v }
  else
    return nil, string.format("%s: memory tier '%s' is not built in (summary, local) and no backend "
      .. "named '%s' is installed (an extension registers one; see lua/ctxgraph/backend.lua)",
      from, tostring(value), tostring(value)), "not_installed"
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

-- The graph's state (counters, live steps, fork chain; lua/ctxgraph/ingest.lua
-- load_state), read through the port once per session per process and kept
-- here; save_state writes it back with one meta call, only when it changed.
function M.gstate(sess)
  local rt = M.rt(sess)
  if not rt.state then rt.state = require("ctxgraph.ingest").load_state(M.backend(sess), M.sid(sess)) end
  return rt.state
end

function M.save_state(sess)
  require("ctxgraph.ingest").save_state(M.backend(sess), M.sid(sess), M.gstate(sess))
end

-- ---- the read view: this conversation's graph, then the ones it forked from ------
--
-- A forked child (spawn{ fork = true }, lua/fork.lua) starts from a copy of its
-- parent's transcript, outline included, so the ids in that outline name
-- records in the PARENT's graph. The child reads through to the parent's graph
-- for ids it does not hold, read-only and as of the fork: a parent record put
-- after the fork (a higher seq) is not visible. Every write still goes to the
-- child's own graph (M.sid). The chain is kept in the child's own graph state
-- (`parents`, [{sid, seq, live}...], nearest parent first; lua/ctxgraph/
-- ingest.lua load_state), so it survives a resume.

-- Record that `csess` was forked from `psess`. Called by fork.adopt once the
-- child's tier is set. Nothing to do when either side is not on a graph tier,
-- or when they are on different backends (one cannot read the other).
function M.on_fork(psess, csess)
  if not (psess and csess and M.enabled(psess) and M.enabled(csess)) then return false end
  local pbe, be = M.backend(psess), M.backend(csess)
  if pbe ~= be then return false end
  local psid = M.sid(psess)
  -- the parent's live steps (lua/ctxgraph/ingest.lua) are not collapsed: the
  -- child has them in full in its copied transcript
  local pst = M.gstate(psess)
  local chain = { { sid = psid, seq = pst.seq, live = pst.live } }
  for _, a in ipairs(M.parents(psess)) do chain[#chain + 1] = { sid = a.sid, seq = a.seq, live = a.live } end
  -- the parent keeps the state of records it changes in place after this
  -- seq, so the child's view of them stays as of now (ingest.lua M.snapshot)
  pst.forks = pst.forks or {}
  if pst.forks[#pst.forks] ~= pst.seq then pst.forks[#pst.forks + 1] = pst.seq end
  M.save_state(psess)
  local cst = M.gstate(csess)
  cst.parents = json.decode(json.encode(chain))   -- a copy: the parent's ranges keep moving
  -- the child's transcript starts with the parent's live steps: their keys,
  -- so the child's first ingest matches them without a get each
  cst._pkeys = { [psid] = {} }
  for n, k in pairs(pst._keys or {}) do cst._pkeys[psid][n] = k end
  for sid, keys in pairs(pst._pkeys or {}) do
    cst._pkeys[sid] = {}
    for n, k in pairs(keys) do cst._pkeys[sid][n] = k end
  end
  M.save_state(csess)
  return true
end

-- The graphs this conversation was forked from, nearest first:
-- { {sid, seq, live = {{lo, hi}...}} } (live: the parent's live step numbers
-- at the fork, as ranges; an older chain holds plain numbers).
function M.parents(sess)
  return M.gstate(sess).parents or {}
end

-- Where reads look, in order: { { sid, max_seq?, live } }. The first is the
-- conversation's own graph (no limit); the rest are read-only parents. `live`
-- is the set of step numbers not yet collapsed in that graph (as of the fork,
-- for a parent): their records are searchable but not outline lines.
function M.sources(sess)
  local ingest = require("ctxgraph.ingest")
  local out = { { sid = M.sid(sess), live = ingest.live_set(M.gstate(sess)) } }
  for _, p in ipairs(M.parents(sess)) do
    local live = {}
    for _, n in ipairs(ingest.ranges_numbers(p.live)) do live[n] = true end
    out[#out + 1] = { sid = p.sid, max_seq = tonumber(p.seq), parent = true, live = live }
  end
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
    if M.visible(r, src) then return require("ctxgraph.outline").as_of(r, src.max_seq), src end
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
  local gs = M.gstate(sess)
  local got = ingest.run(be, sid, msgs, from, start - 1, { root = root, digests = rt.digests, now = opts.now,
                                                          state = gs, returns = rt.returns })
  -- the live-ingest cursor follows the kept tail to its new place (after the
  -- outline): msgs[i] for i >= start becomes message i - start + 2
  if rt.cursor then rt.cursor = math.max(2, rt.cursor - start + 2) end
  if rt.last then
    if rt.last.at >= start then rt.last.at = rt.last.at - start + 2 else rt.last = nil end
  end
  gs.compactions = gs.compactions + 1
  local k = gs.compactions
  local cid = string.format("s/%s/compaction/%d", sid, k)
  local links = {}
  for _, id in ipairs(got.span_ids) do links[#links + 1] = { type = "collapsed", dst = id } end
  local steps = got.steps
  local crec = { id = cid, type = "compaction", title = "compaction " .. k, links = links,
    seq = gs.seq + 1, created = opts.now,
    frontmatter = { n = k, first_step = steps[1] and steps[1].n or nil, last_step = steps[#steps] and steps[#steps].n or nil,
                    steps = #steps, spans = #got.span_ids } }
  crec.stub = string.format("compaction %d: %d steps into %d spans", k, #steps, #got.span_ids)
  crec.digest = require("ctxgraph.extract").sha(cid .. "\0" .. crec.stub)
  crec.tokens = 0
  gs.seq = crec.seq
  got.records[#got.records + 1] = crec
  -- the state first: a crash after it leaves unused numbers, never reused ones
  M.save_state(sess)
  be.put_nodes(sid, got.records)
  if #got.edges > 0 then be.put_edges(sid, got.edges) end

  local cap = math.max(1000, math.min(M.OUTLINE_MAX_TOKENS, math.floor((opts.threshold or 100000) * M.OUTLINE_SHARE)))
  local inherit, srcs = {}, M.sources(sess)
  for i, src in ipairs(srcs) do if i > 1 then inherit[#inherit + 1] = src end end
  local text, ost = outline.render(be, sid, task, { cap_tokens = cap, inherit = inherit, live = srcs[1].live })
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

-- ---- a child's answer, however it arrives -------------------------------------------
-- A spawned child reports once, when it exits (lua/thread.lua _run). The
-- parent may read that report through `await` (ingest folds it in at that
-- step), only through `inbox`, or never. So the exit records it in the parent's
-- graph directly: record_return(parent session, child agent id, ok, text).
-- When the spawn is not in the graph yet (the child finished before the
-- parent's round was ingested), the answer waits in the session's runtime state
-- and is folded in when the spawn is ingested. -> true when the thread was
-- updated now
function M.record_return(sess, agent, ok, text)
  agent = tonumber(agent)
  if not (sess and agent and M.enabled(sess)) then return false end
  local ingest = require("ctxgraph.ingest")
  local be, sid = M.backend(sess), M.sid(sess)
  local ret = { agent = agent, ok = ok and true or false, text = tostring(text or "") }
  local tid = be.meta(sid, "thread_agent/" .. agent)
  local tr = tid and be.get(sid, tid)
  if not tr then
    local rt = M.rt(sess)
    rt.returns = rt.returns or {}
    rt.returns[agent] = ret
    return false
  end
  local gs = M.gstate(sess)
  local prior = gs.forks and #gs.forks > 0 and ingest.snapshot(tr)
  ingest.fold_return(tr, ret, nil)
  if prior then
    -- a change in place after a fork: it takes a seq of its own
    gs.seq = gs.seq + 1
    ingest.keep_for_forks(gs, prior, tr, gs.seq)
    M.save_state(sess)
  end
  be.put_nodes(sid, { tr })
  return true
end

-- ---- live ingest ------------------------------------------------------------------

-- After a tool round: ingest the messages not yet in the graph (from the
-- cursor to the end, normally the round just finished, plus a prompt before
-- it), so graph_recall and expand reach the live tail before any compaction.
-- The outline is not touched (it changes only at a compaction), and the
-- compaction that later collapses these steps reuses their records. One
-- put_nodes per call. -> number of new steps
function M.ingest_live(sess)
  if not M.enabled(sess) then return 0 end
  local msgs = sess.messages or {}
  local rt = M.rt(sess)
  local from = rt.cursor
  if not from then
    -- a fresh or resumed conversation: everything after the outline; steps
    -- already in the graph are matched and skipped (ingest's live list)
    from = (msgs[1] and msgs[1].role == "user" and require("ctxgraph.outline").is_outline(msgs[1].content)) and 2 or 1
  end
  -- the last step ingested may have gained text since (mid-turn steering or
  -- a prompt merged into its trailing tool-results message): take it again
  -- from its first message, and ingest updates its record in place
  local prev
  local last = rt.last
  if rt.cursor and last and last.at < from and M.fingerprint(msgs[from - 1]) ~= last.fp then
    -- only when those messages are still that one step (never re-ingest a
    -- step under a new number because the transcript was rearranged)
    local ingest = require("ctxgraph.ingest")
    local sts = ingest.steps_of(msgs, last.at, from - 1)
    if #sts == 1 and ingest.step_key(sts[1]) == M.gstate(sess)._keys[last.n] then
      from, prev = last.at, last
    end
  end
  if from > #msgs then return 0 end
  local be = M.backend(sess)
  local sid = M.sid(sess)
  local root
  do
    local ok, r = pcall(function() return bog.tools.project_root() end)
    root = ok and r or (sys and sys.cwd and sys.cwd()) or nil
  end
  local got = require("ctxgraph.ingest").run(be, sid, msgs, from, #msgs,
    { root = root, digests = rt.digests, live = true, match = rt.cursor == nil, state = M.gstate(sess),
      prev = prev, returns = rt.returns })
  -- the state first: a crash after it leaves unused numbers, never reused ones
  M.save_state(sess)
  if #got.records > 0 then be.put_nodes(sid, got.records) end
  if #got.edges > 0 then be.put_edges(sid, got.edges) end
  rt.cursor = #msgs + 1
  local tail = got.steps[#got.steps]
  rt.last = tail and { at = tail.at, n = tail.n, fp = M.fingerprint(msgs[#msgs]) } or rt.last
  return #got.fresh
end

-- A cheap check that a message gained content: append_user adds a text block
-- to a block list or text to a string.
function M.fingerprint(m)
  if not m then return "" end
  local c = m.content
  if type(c) == "table" then return "t" .. #c end
  return "s" .. #tostring(c or "")
end

return M
