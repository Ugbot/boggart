-- ctxgraph/ingest.lua -- transcript messages -> graph records.
--
-- Called once per compaction with the messages being collapsed. It groups
-- them into steps (one model reply plus the results of its tool calls, never
-- split), cuts the steps into spans, derives entities and harness claims by
-- rule, and hands everything to the backend in one put_nodes and one
-- put_edges call. Backend-independent: it only uses the port.
local json = require("json")
local ex = require("ctxgraph.extract")
local stubs = require("ctxgraph.stubs")
local window = require("window")

local M = {}

-- Span limits (assumption 10).
M.SPAN_MAX_STEPS = 12
M.SPAN_MAX_TOKENS = 8000
M.SHIFT_WINDOW = 3          -- steps compared for an entity-set shift
M.SHIFT_OVERLAP = 0.25      -- below this share of shared entities, a new span
M.HARNESS_PREFIX = "[harness: "

local function text_of_blocks(content, want)
  local out = {}
  for _, b in ipairs(content) do
    if b.type == "text" and (want == nil or want(b.text or "")) then out[#out + 1] = b.text or "" end
  end
  return table.concat(out, "\n")
end

local function result_text(b)
  local c = b.content
  if type(c) == "string" then return c end
  if type(c) == "table" then return text_of_blocks(c) end
  return ""
end

local function is_harness(t) return t:sub(1, #M.HARNESS_PREFIX) == M.HARNESS_PREFIX end

-- Group messages[from..to] into steps.
function M.steps_of(msgs, from, to)
  local steps, i = {}, from
  while i <= to do
    local m = msgs[i]
    if m.role == "assistant" then
      local st = { kind = "model", calls = {}, messages = { m }, text = "", reasoning = nil }
      local content = type(m.content) == "table" and m.content or { { type = "text", text = tostring(m.content or "") } }
      local by_id, think = {}, {}
      st.text = text_of_blocks(content)
      for _, b in ipairs(content) do
        if b.type == "tool_use" then
          local c = { id = b.id, name = b.name, input = b.input or {}, result = "", is_error = false }
          st.calls[#st.calls + 1] = c
          by_id[b.id] = c
        elseif b.type == "thinking" or b.type == "reasoning" then
          think[#think + 1] = b.thinking or b.text or ""
        end
      end
      if #think > 0 then st.reasoning = table.concat(think, "\n") end
      local nxt = msgs[i + 1]
      if #st.calls > 0 and i + 1 <= to and nxt and nxt.role == "user" and type(nxt.content) == "table" then
        st.messages[2] = nxt
        for _, b in ipairs(nxt.content) do
          if b.type == "tool_result" and by_id[b.tool_use_id] then
            local c = by_id[b.tool_use_id]
            c.result = result_text(b)
            c.is_error = b.is_error and true or (c.result:sub(1, 11) == "Tool error:")
          end
        end
        st.harness = text_of_blocks(nxt.content, is_harness)
        st.steer = text_of_blocks(nxt.content, function(t) return not is_harness(t) end)
        i = i + 2
      else
        i = i + 1
      end
      steps[#steps + 1] = st
    else
      local t = type(m.content) == "string" and m.content
        or (type(m.content) == "table" and text_of_blocks(m.content) or "")
      steps[#steps + 1] = { kind = "prompt", calls = {}, messages = { m }, text = t }
      i = i + 1
    end
  end
  return steps
end

-- The readable body of a step: everything it said and got back, in order.
local function render(st)
  local out = {}
  if st.kind == "prompt" then return "user:\n" .. st.text end
  if st.text ~= "" then out[#out + 1] = st.text end
  for _, c in ipairs(st.calls) do
    local ok, inp = pcall(json.encode, c.input)
    out[#out + 1] = string.format("> %s %s", c.name, ok and inp or "{}")
    out[#out + 1] = c.result
  end
  if st.steer and st.steer ~= "" then out[#out + 1] = "user (mid-turn):\n" .. st.steer end
  return table.concat(out, "\n")
end


local function overlap(a, set)
  if #a == 0 then return 1 end
  local hit = 0
  for _, id in ipairs(a) do if set[id] then hit = hit + 1 end end
  return hit / #a
end

-- Cut steps into spans (assumption 10). Each step carries .ents (file /
-- package / test ids) and .keys (command and error ids, for retry runs).
function M.spans_of(steps)
  local spans, cur = {}, nil
  local function close(why)
    if cur then cur.closed_by = why; spans[#spans + 1] = cur end
    cur = nil
  end
  for _, st in ipairs(steps) do
    local why
    if cur then
      local n = #cur.steps
      if st.kind == "prompt" then why = "request"
      elseif st.spawn then why = "spawn"
      elseif n >= M.SPAN_MAX_STEPS or cur.tokens + st.tokens > M.SPAN_MAX_TOKENS then why = "size"
      else
        -- the end of a retry run: the last two steps repeat a command or an
        -- error, and this one does not
        if n >= 2 then
          local a, b = cur.steps[n - 1].keys, cur.steps[n].keys
          local shared = {}
          for k in pairs(a) do if b[k] then shared[#shared + 1] = k end end
          if #shared > 0 then
            local cont = false
            for _, k in ipairs(shared) do if st.keys[k] then cont = true end end
            if not cont then why = "retry_end" end
          end
        end
        if not why and n >= M.SHIFT_WINDOW and #st.ents > 0 then
          local win, any = {}, false
          for j = n - M.SHIFT_WINDOW + 1, n do
            for _, id in ipairs(cur.steps[j].ents) do win[id] = true; any = true end
          end
          if any and overlap(st.ents, win) < M.SHIFT_OVERLAP then why = "shift" end
        end
      end
      if why then close(why) end
    end
    cur = cur or { steps = {}, tokens = 0 }
    cur.steps[#cur.steps + 1] = st
    cur.tokens = cur.tokens + st.tokens
  end
  close("compaction")
  return spans
end

-- The agent id a spawn's result names ({"spawned":N}, lua/tools_swarm.lua).
function M.spawned_id(result)
  return tonumber(tostring(result or ""):match('^%s*{%s*"spawned"%s*:%s*(%d+)%s*}'))
end

-- The children's answers in an await's result: after the verdict, one
-- "### agent N (name)[ [error]]" section per child. -> { {agent, ok, text} }
function M.returns_of(result)
  local text = tostring(result or "")
  local heads = {}
  for at, id, rest, body_at in text:gmatch("()\n\n### agent (%d+) %(([^\n]*)\n()") do
    heads[#heads + 1] = { at = at, agent = tonumber(id), ok = not rest:find("%) %[error%]$"), body_at = body_at }
  end
  local out = {}
  for i, h in ipairs(heads) do
    local stop = heads[i + 1] and heads[i + 1].at - 1 or #text
    out[#out + 1] = { agent = h.agent, ok = h.ok, text = text:sub(h.body_at, stop) }
  end
  return out
end

local function digest_of(body, extra) return ex.sha((body or "") .. "\0" .. (extra or "")) end

-- ---- the graph's state ------------------------------------------------------------
-- A graph's counters (seq, steps, spans, threads, compactions), its live steps
-- and, for a fork, the graphs it reads through to are one small JSON value
-- under the meta key "graph". Core reads it once per process (the caller
-- caches the table) and writes it at most once per tool round and once per
-- compaction, so a remote backend sees one meta round trip per round, not one
-- per counter. Its size does not grow with the conversation: the live steps
-- are kept as ranges of step numbers.
--
--   { v = 1, seq, steps, spans, threads, compactions,
--     live = { {lo, hi}... },          -- live (not yet collapsed) step numbers
--     parents = { {sid, seq, live = { {lo, hi}... }}... },   -- a fork's chain
--     forks = { seq... } }             -- this graph's seq at each fork of it
--
-- Graphs written before this key existed kept each counter, the live list
-- (JSON [{k, n}]) and the fork chain under their own keys; load_state reads
-- those once when "graph" is missing, and the next save writes "graph". The
-- old keys are left as they are and never read again.
M.STATE_KEY = "graph"
local COUNTERS = { "seq", "steps", "spans", "threads", "compactions" }

-- Ranges of integers, ascending and disjoint: { {lo, hi}... }.
local function ranges_add(rs, n)
  local last = rs[#rs]
  if last and n == last[2] + 1 then last[2] = n
  elseif last and n <= last[2] then
    -- out of order: rebuild (never expected; kept correct anyway)
    local set = {}
    for _, r in ipairs(rs) do for i = r[1], r[2] do set[i] = true end end
    set[n] = true
    local nums = {}
    for i in pairs(set) do nums[#nums + 1] = i end
    table.sort(nums)
    for i = #rs, 1, -1 do rs[i] = nil end
    for _, i in ipairs(nums) do
      local l = rs[#rs]
      if l and i == l[2] + 1 then l[2] = i else rs[#rs + 1] = { i, i } end
    end
  else rs[#rs + 1] = { n, n } end
end

local function ranges_numbers(rs)
  local out = {}
  for _, r in ipairs(rs or {}) do
    if type(r) == "table" then
      for i = tonumber(r[1]) or 1, tonumber(r[2]) or 0 do out[#out + 1] = i end
    elseif tonumber(r) then
      out[#out + 1] = tonumber(r)   -- an older chain: plain step numbers
    end
  end
  return out
end
M.ranges_numbers = ranges_numbers

function M.ranges_of(nums)
  local sorted = {}
  for _, n in ipairs(nums) do sorted[#sorted + 1] = tonumber(n) end
  table.sort(sorted)
  local rs = {}
  for _, n in ipairs(sorted) do ranges_add(rs, n) end
  return rs
end

-- load_state(be, sid) -> state. One meta read for a graph that has the
-- state key; a graph without one costs one more (the "seq" probe), and an
-- older-layout graph a few more, once.
function M.load_state(be, sid)
  local raw = be.meta(sid, M.STATE_KEY)
  local ok, t = pcall(json.decode, raw or "")
  local st
  if ok and type(t) == "table" then
    st = t
    st._saved = raw
  else
    st = { _keys = {} }
    if be.meta(sid, "seq") ~= nil then
      for _, k in ipairs(COUNTERS) do st[k] = be.meta(sid, k) end
      local okl, l = pcall(json.decode, be.meta(sid, "live") or "")
      st.live = {}
      for _, e in ipairs((okl and type(l) == "table") and l or {}) do
        local n = tonumber(e.n)
        if n then ranges_add(st.live, n); st._keys[n] = e.k end
      end
      local okp, p = pcall(json.decode, be.meta(sid, "parent_graph") or "")
      if okp and type(p) == "table" and #p > 0 then st.parents = p end
    end
  end
  for _, k in ipairs(COUNTERS) do st[k] = tonumber(st[k]) or 0 end
  st.live = st.live or {}
  st._keys = st._keys or {}
  return st
end

-- save_state(be, sid, state): one meta write, skipped when nothing changed.
function M.save_state(be, sid, st)
  local out = { v = 1, live = st.live, parents = st.parents, forks = st.forks }
  for _, k in ipairs(COUNTERS) do out[k] = st[k] end
  local enc = json.encode(out)
  if enc ~= st._saved then
    be.meta(sid, M.STATE_KEY, enc)
    st._saved = enc
  end
end

-- ---- a fork's view of records changed in place --------------------------------------
-- Entities (and a thread when its answer arrives) are replaced in place and
-- keep their seq, so "seq <= the fork's seq" alone would show a fork the
-- parent's later changes. Once a graph has been forked (state.forks holds the
-- seq at each fork), a record changed in place carries, in frontmatter:
--   useq   the seq of the batch that last changed it (after every fork so far)
--   asof   JSON [{v, title, stub, fm, body}...], oldest first: earlier states
--          some fork saw, each valid from seq v (its useq, else its seq)
-- A reader with a fork's max_seq takes the latest state with v <= max_seq
-- (lua/ctxgraph/outline.lua as_of). A state is kept only while a fork falls
-- inside its validity, so a graph never forked carries neither field.
function M.snapshot(r)
  local f = r.frontmatter or {}
  local fm = {}
  for k, v in pairs(f) do if k ~= "asof" and k ~= "useq" then fm[k] = v end end
  return { v = tonumber(f.useq) or tonumber(r.seq) or 0, title = r.title, stub = r.stub, body = r.body, fm = fm }
end

-- ---- live steps ------------------------------------------------------------------
-- Steps are ingested as their tool round completes (ctx.live), not only at a
-- compaction, so the live tail is searchable. Those steps are "live": in the
-- graph but not collapsed; the state's `live` ranges hold their numbers. A
-- later ingest of the same messages (the compaction that collapses them, or a
-- live ingest after a resume) matches its steps against the live steps in
-- order, by step key, and reuses their records instead of ingesting them
-- twice. A compaction drops the steps it collapses from the live ranges; what
-- is left is the kept tail. A step's key is in its record's frontmatter
-- (`key`) and cached in the state table (`_keys`, not saved), so matching
-- costs a get per live step only after a resume.

-- A step's identity across ingests: its opening message, which is never
-- changed once the next request has been sent.
function M.step_key(st)
  local ok, enc = pcall(json.encode, st.messages[1])
  return ex.sha(ok and enc or tostring(st.text)):sub(1, 32)
end

-- A step record's key: its frontmatter, or (a record written before steps
-- carried it) recomputed from the messages it holds.
function M.key_of_record(r)
  local f = r and r.frontmatter or {}
  if f.key then return f.key end
  local ok, ms = pcall(json.decode, r and r.raw or "")
  if ok and type(ms) == "table" and ms[1] then return M.step_key({ messages = ms }) end
  return nil
end

local function entries(be, sid, ranges, keys, src)
  local out = {}
  for _, n in ipairs(ranges_numbers(ranges)) do
    local k = keys[n]
    if k == nil then
      k = M.key_of_record(be.get(sid, string.format("s/%s/step/%d", sid, n))) or false
      keys[n] = k
    end
    out[#out + 1] = { k = k or nil, n = n, src = src }
  end
  return out
end

-- The live steps in conversation order: { {k = step key, n = step number} }.
function M.live_entries(be, sid, st)
  return entries(be, sid, st.live, st._keys)
end

-- A fork's transcript starts with a copy of its parent's, so its first steps
-- are the parent's live steps at the fork (and, deeper, the grandparent's):
-- { {k, n, src = index in st.parents} }, farthest ancestor first. Their keys
-- are cached in st._pkeys[sid] (seeded at the fork; after a resume, a get each).
function M.inherited_entries(be, st)
  local out = {}
  local ps = st.parents or {}
  st._pkeys = st._pkeys or {}
  for i = #ps, 1, -1 do
    local p = ps[i]
    local keys = st._pkeys[p.sid] or {}
    st._pkeys[p.sid] = keys
    for _, e in ipairs(entries(be, p.sid, p.live, keys, i)) do out[#out + 1] = e end
  end
  return out
end

-- The step numbers of the live (not yet collapsed) steps, as a set.
function M.live_set(st)
  local set = {}
  for _, n in ipairs(ranges_numbers(st.live)) do set[n] = true end
  return set
end

-- The step a record belongs to, for deciding whether it is collapsed: an
-- entity by the step that first touched it; a model's note has none.
local function step_of(r)
  local f = r.frontmatter or {}
  if r.type == "step" then return tonumber(f.n) end
  if r.type == "reasoning" or r.type == "thread" or r.type == "version" or r.type == "claim" then return tonumber(f.step) end
  if r.type == "file" or r.type == "package" or r.type == "command" or r.type == "test" or r.type == "error" then
    return tonumber(f.first_step)
  end
  return nil
end

-- Is record `r` collapsed, given the live set? Spans and compactions always
-- are; anything that belongs to a live step is not yet.
function M.collapsed(r, live)
  local n = step_of(r)
  return not (n and live and live[n])
end

-- ingest(be, sid, msgs, from, to, ctx) -> { steps, spans, records, edges, span_ids }
-- ctx = { root, digests = { [tool_use_id] = content sha256 }, now, live, match, state }
-- ctx.live: a live ingest (after a tool round): steps only, no spans, and the
-- new steps are added to the live steps; with ctx.match (no cursor: a resume)
-- its steps are matched against the live steps first. Otherwise a compaction: the steps are
-- collapsed into spans and leave the live steps. Live steps are reused, never
-- ingested again. Edges from records in the batch are carried as their links,
-- so a batch is normally one put_nodes; `edges` holds only those whose source
-- is not in it (normally none).
-- ctx.state: the graph's state (load_state), updated in place; the caller
-- saves it (save_state). Without it the state is loaded and saved here.
function M.run(be, sid, msgs, from, to, ctx)
  ctx = ctx or {}
  local gs = ctx.state or M.load_state(be, sid)
  local steps = M.steps_of(msgs, from, to)
  -- A live ingest from a known cursor covers only messages never ingested,
  -- so it does not match: two rounds can be byte-identical (servers that
  -- number calls per response reuse call_0) and must stay two steps.
  local match = not ctx.live or ctx.match
  -- Candidates, in conversation order: a fork's inherited steps (its parents'
  -- live steps at the fork, copied at the head of its transcript), then its
  -- own live steps. An inherited step stays the parent's: it is neither
  -- ingested nor spanned here (the read view reaches it in the parent's graph).
  local live = match and M.live_entries(be, sid, gs) or {}
  local cands = match and M.inherited_entries(be, gs) or {}
  local base = #cands
  for _, e in ipairs(live) do cands[#cands + 1] = e end
  local matched, last_matched = {}, 0
  do
    local p = 1
    for _, st in ipairs(steps) do
      st.key = M.step_key(st)
      for j = p, #cands do
        if cands[j].k == st.key then
          if cands[j].src then st.inherited = cands[j] else st.done = tonumber(cands[j].n) end
          matched[j] = true
          last_matched, p = j, j + 1
          break
        end
      end
    end
    local own = {}
    for _, st in ipairs(steps) do if not st.inherited then own[#own + 1] = st end end
    steps = own
  end
  local recs, edges, cache = {}, {}, {}
  local seq0 = gs.seq
  local seq = seq0
  local function nextseq() seq = seq + 1; return seq end
  -- what a record was before this batch changes it, kept for a fork's view
  -- (M.snapshot), only when this graph has been forked
  local prior = {}
  local forked = gs.forks and #gs.forks > 0
  local function load(id)
    if cache[id] == nil then
      local r = be.get(sid, id)
      cache[id] = r or false
      if r and forked then prior[id] = M.snapshot(r) end
    end
    return cache[id] or nil
  end
  local function put(r)
    r.links = r.links or {}
    r.frontmatter = r.frontmatter or {}
    r.created = r.created or ctx.now
    r.digest = r.digest or digest_of(r.body, r.id .. "\0" .. (r.title or ""))
    r.tokens = r.tokens or ((#(r.body or "") + 3) // 4)
    cache[r.id] = r
    recs[r.id] = r
    return r
  end
  local function edge(src, t, dst) edges[#edges + 1] = { src = src, type = t, dst = dst } end

  local step_n = gs.steps
  local fresh = {}
  for _, st in ipairs(steps) do
    if st.done then
      st.n = st.done
    else
      step_n = step_n + 1
      st.n = step_n
      fresh[#fresh + 1] = st
    end
    st.id = string.format("s/%s/step/%d", sid, st.n)
    st.ents, st.keys, st.entities, st.claims = {}, {}, {}, {}
    st.tokens = window.tokens_of(st.messages)
    for _, c in ipairs(st.calls) do
      local got = ex.call(c, ctx.root)
      if got.failed then st.failed = true end
      if c.name == "spawn" then
        st.spawn = st.spawn or c
        st.spawns = st.spawns or {}
        st.spawns[#st.spawns + 1] = c
      end
      for _, e in ipairs(got.entities) do
        e.call = c
        st.entities[#st.entities + 1] = e
        if e.type == "file" or e.type == "package" or e.type == "test" then st.ents[#st.ents + 1] = e.id end
        if e.type == "command" or e.type == "error" then st.keys[e.id] = e.title end
      end
      for _, cl in ipairs(got.claims) do st.claims[#st.claims + 1] = cl end
    end
    st.stub = stubs.step(st, ex)
  end
  gs.steps = step_n

  -- entities and claims, in step order so counts and versions accumulate
  -- (only for steps not already in the graph)
  for _, st in ipairs(fresh) do
    local body = render(st)
    local ref = body:match("Full output saved to (%S+) %-%-")
    local okr, raw = pcall(json.encode, st.messages)
    local srec = put({ id = st.id, type = "step", title = "step " .. st.n, stub = st.stub, body = body,
      body_ref = ref, raw = okr and raw or nil, seq = nextseq(),
      frontmatter = { n = st.n, kind = st.kind, key = st.key, outcome = st.failed and "failed" or "ok",
                      tools = #st.calls > 0 and (function()
                        local ns = {}
                        for _, c in ipairs(st.calls) do ns[#ns + 1] = c.name end
                        return table.concat(ns, ",") end)() or nil } })
    if st.reasoning and st.reasoning ~= "" then
      local rid = st.id .. "/reasoning"
      put({ id = rid, type = "reasoning", title = "reasoning of step " .. st.n,
        stub = "reasoning of step " .. st.n .. string.format(" (~%d tokens)", (#st.reasoning + 3) // 4),
        body = st.reasoning, seq = nextseq(), frontmatter = { step = st.n } })
      srec.links[#srec.links + 1] = { type = "has_reasoning", dst = rid }
    end
    for _, sp in ipairs(st.spawns or {}) do
      gs.threads = gs.threads + 1
      local tn = gs.threads
      local tid = string.format("s/%s/thread/%d", sid, tn)
      local agent = M.spawned_id(sp.result)
      local tf = { task = sp.input.task, step = st.n, fork = sp.input.fork and true or nil,
                   result = stubs.line(sp.result, 80), agent = agent }
      local tr = put({ id = tid, type = "thread", title = stubs.line(tf.task, 80), body = sp.result,
        seq = nextseq(), frontmatter = tf })
      tr.stub = stubs.entity(tr)
      srec.links[#srec.links + 1] = { type = "spawned", dst = tid }
      if agent then be.meta(sid, "thread_agent/" .. agent, tid) end
    end
    -- what a child returned: fold it into its thread (spawned in this batch
    -- or collapsed at an earlier compaction)
    for _, c in ipairs(st.calls) do
      if c.name == "await" and not c.is_error then
        for _, ret in ipairs(M.returns_of(c.result)) do
          local tid = be.meta(sid, "thread_agent/" .. ret.agent)
          local tr = tid and load(tid)
          if tr then
            local f = tr.frontmatter or {}
            tr.frontmatter = f
            f.returned = stubs.line(ret.text, 100)
            f.returned_ok = ret.ok
            f.returned_step = st.n
            tr.body = (f.spawn_result or tr.body or "") .. string.format("\n\n[agent %d returned at step %d%s]\n",
              ret.agent, st.n, ret.ok and "" or ", failed") .. ret.text
            f.spawn_result = f.spawn_result or f.result
            tr.stub = stubs.entity(tr)
            tr.digest = digest_of(tr.body, tr.id .. "\0" .. (tr.title or ""))
            tr.tokens = (#tr.body + 3) // 4
            put(tr)
            edge(st.id, "collects", tid)
          end
        end
      end
    end
    for _, e in ipairs(st.entities) do
      local r = load(e.id)
      local f = r and r.frontmatter or {}
      local fresh = not r
      if fresh then r = { id = e.id, type = e.type, title = e.title } end
      r.frontmatter = f
      f.first_step = f.first_step or st.n
      f.last_step = st.n
      if e.type == "file" then
        f.path = e.attrs.path
        if e.attrs.lines then f.lines = e.attrs.lines end
        if e.attrs.changed then
          local c = e.call
          local cd = ctx.digests and ctx.digests[c.id]
          if not cd and c.name == "write" and type(c.input.content) == "string" then cd = ex.sha(c.input.content) end
          local vid = e.id .. "@" .. (cd and cd:sub(1, 12) or ("v" .. ((f.versions or 0) + 1)))
          local existing = load(vid)
          if not existing then
            f.versions = (f.versions or 0) + 1
            put({ id = vid, type = "version", title = f.path .. " v" .. f.versions, seq = nextseq(),
              links = { { type = "version_of", dst = e.id } },
              frontmatter = { path = f.path, v = f.versions, op = c.name, step = st.n,
                              content_digest = cd, lines = e.attrs.lines } })
            recs[vid].stub = stubs.entity(recs[vid])
          end
          f.current = vid
          f.last_op, f.last_change = c.name, st.n
          edge(st.id, "produced", vid)
        else
          f.reads = (f.reads or 0) + 1
        end
      elseif e.type == "package" then
        f.manager, f.name = e.attrs.manager, e.attrs.name
        f.version = e.attrs.version or f.version
        f.state = f.state or "requested"
      elseif e.type == "command" then
        f.command = e.attrs.command
        f.runs = (f.runs or 0) + 1
        f.last_exit = e.attrs.exit
      elseif e.type == "test" then
        f.runner = e.attrs.runner
        f.runs = (f.runs or 0) + 1
      elseif e.type == "error" then
        f.line = e.attrs.line
        f.count = (f.count or 0) + 1
      end
      r.seq = r.seq or nextseq()
      r.body = nil
      put(r)
      edge(st.id, e.edge, e.id)
    end
    for _, cl in ipairs(st.claims) do
      local cid = "claim/" .. ex.sha(cl.subject .. "\0" .. cl.predicate .. "\0" .. sid):sub(1, 16)
      if load(cid) then
        edge(st.id, "observes", cid)
      else
        local cr = put({ id = cid, type = "claim", title = cl.title, state = "reproduced", seq = nextseq(),
          links = { { type = "about", dst = cl.subject }, { type = "source", dst = st.id } },
          frontmatter = { subject = cl.subject, predicate = cl.predicate, origin = sid, step = st.n, by = "harness" } })
        cr.stub = stubs.claim(cr)
      end
      -- what an entity's stub reports follows its latest observed claim
      local subj = load(cl.subject)
      if subj then
        if cl.predicate == "installed" or cl.predicate == "install_failed" then subj.frontmatter.state = cl.predicate
        elseif cl.predicate == "passed" or cl.predicate == "failed" then subj.frontmatter.last = cl.predicate end
      end
    end
  end
  -- entity stubs last, once every observation in this batch is folded in
  for _, r in pairs(recs) do
    if r.type == "file" or r.type == "package" or r.type == "command" or r.type == "test" or r.type == "error" then
      r.stub = stubs.entity(r)
      r.digest = digest_of(nil, r.id .. "\0" .. json.encode(r.frontmatter))
    end
  end

  -- the live steps: a live ingest adds its new steps; a compaction drops
  -- what it collapses (and anything listed before it, which is stale)
  if ctx.live then
    for _, st in ipairs(fresh) do ranges_add(gs.live, st.n); gs._keys[st.n] = st.key end
  else
    local keep = {}
    for j = math.max(last_matched, base) + 1, #cands do if not matched[j] then keep[#keep + 1] = cands[j].n end end
    gs.live = M.ranges_of(keep)
    -- inherited steps this compaction passed are collapsed in this view now
    if base > 0 then
      local kept = {}
      for j = last_matched + 1, base do
        if not matched[j] then
          local i = cands[j].src
          kept[i] = kept[i] or {}
          kept[i][#kept[i] + 1] = cands[j].n
        end
      end
      for i, p in ipairs(gs.parents) do p.live = M.ranges_of(kept[i] or {}) end
    end
  end

  local function finish(spans, span_ids)
    -- records changed in place after a fork keep the state each fork saw
    if forked then
      local last_fork = 0
      for _, f in ipairs(gs.forks) do last_fork = math.max(last_fork, tonumber(f) or 0) end
      for id, r in pairs(recs) do
        local p = prior[id]
        if p then
          local ok, hist = pcall(json.decode, r.frontmatter.asof or "")
          hist = (ok and type(hist) == "table") and hist or {}
          if last_fork >= p.v then hist[#hist + 1] = p end
          r.frontmatter.asof = #hist > 0 and json.encode(hist) or nil
          r.frontmatter.useq = seq0 + 1
        end
      end
    end
    -- carry edges as links of their source record when it is in the batch
    local rest = {}
    for _, e in ipairs(edges) do
      local r = recs[e.src]
      if r then r.links[#r.links + 1] = { type = e.type, dst = e.dst } else rest[#rest + 1] = e end
    end
    local list = {}
    for _, r in pairs(recs) do list[#list + 1] = r end
    table.sort(list, function(a, b) return (a.seq or 0) < (b.seq or 0) end)
    gs.seq = seq
    if not ctx.state then M.save_state(be, sid, gs) end
    return { steps = steps, fresh = fresh, spans = spans, records = list, edges = rest, span_ids = span_ids }
  end
  if ctx.live then return finish({}, {}) end

  -- spans
  local spans = M.spans_of(steps)
  local span_ids = {}
  local span_n = gs.spans
  for _, sp in ipairs(spans) do
    span_n = span_n + 1
    local touched, seen, cmds = {}, {}, {}
    for _, st in ipairs(sp.steps) do
      for _, e in ipairs(st.entities) do
        if (e.type == "file" or e.type == "package" or e.type == "test") and not seen[e.id] then
          seen[e.id] = true; touched[#touched + 1] = e.title
        end
        if e.type == "command" then
          local c = cmds[e.id] or { title = e.title, count = 0, at = #st.entities }
          c.count = c.count + 1
          cmds[e.id] = c
        end
      end
    end
    local best
    for id, c in pairs(cmds) do
      if c.count >= 2 and (not best or c.count > best.count or (c.count == best.count and id < best.id)) then
        best = { id = id, title = c.title, count = c.count }
      end
    end
    sp.retry, sp.touched = best, touched
    local id = string.format("s/%s/span/%d", sid, span_n)
    local lines, links = {}, {}
    for _, st in ipairs(sp.steps) do
      lines[#lines + 1] = st.id .. "  " .. st.stub
      links[#links + 1] = { type = "contains", dst = st.id }
    end
    local stub = stubs.span(sp)
    put({ id = id, type = "span", title = stubs.line(stub, 100), stub = stub, body = table.concat(lines, "\n"),
      seq = nextseq(), links = links, tokens = sp.tokens,
      frontmatter = { first_step = sp.steps[1].n, last_step = sp.steps[#sp.steps].n, steps = #sp.steps,
                      tokens = sp.tokens, closed_by = sp.closed_by } })
    span_ids[#span_ids + 1] = id
  end
  gs.spans = span_n
  return finish(spans, span_ids)
end

return M
