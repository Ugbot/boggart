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

local function counter(be, sid, key, add)
  local n = tonumber(be.meta(sid, key) or "0") or 0
  if add then n = n + add; be.meta(sid, key, tostring(n)) end
  return n
end
M.counter = counter

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

local function digest_of(body, extra) return ex.sha((body or "") .. "\0" .. (extra or "")) end

-- ingest(be, sid, msgs, from, to, ctx) -> { steps, spans, records, edges, span_ids }
-- ctx = { root, digests = { [tool_use_id] = content sha256 }, now }
function M.run(be, sid, msgs, from, to, ctx)
  ctx = ctx or {}
  local steps = M.steps_of(msgs, from, to)
  local recs, edges, cache = {}, {}, {}
  local seq = counter(be, sid, "seq")
  local function nextseq() seq = seq + 1; return seq end
  local function load(id)
    if cache[id] == nil then cache[id] = be.get(sid, id) or false end
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

  local step_n = counter(be, sid, "steps")
  for _, st in ipairs(steps) do
    step_n = step_n + 1
    st.n = step_n
    st.id = string.format("s/%s/step/%d", sid, step_n)
    st.ents, st.keys, st.entities, st.claims = {}, {}, {}, {}
    st.tokens = window.tokens_of(st.messages)
    for _, c in ipairs(st.calls) do
      local got = ex.call(c, ctx.root)
      if got.failed then st.failed = true end
      if c.name == "spawn" then st.spawn = c end
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
  counter(be, sid, "steps", #steps)

  -- entities and claims, in step order so counts and versions accumulate
  for _, st in ipairs(steps) do
    local body = render(st)
    local ref = body:match("Full output saved to (%S+) %-%-")
    local okr, raw = pcall(json.encode, st.messages)
    local srec = put({ id = st.id, type = "step", title = "step " .. st.n, stub = st.stub, body = body,
      body_ref = ref, raw = okr and raw or nil, seq = nextseq(),
      frontmatter = { n = st.n, kind = st.kind, outcome = st.failed and "failed" or "ok",
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
    if st.spawn then
      local tn = counter(be, sid, "threads", 1)
      local tid = string.format("s/%s/thread/%d", sid, tn)
      local tf = { task = st.spawn.input.task, step = st.n, fork = st.spawn.input.fork and true or nil,
                   result = stubs.line(st.spawn.result, 80) }
      local tr = put({ id = tid, type = "thread", title = stubs.line(tf.task, 80), body = st.spawn.result,
        seq = nextseq(), frontmatter = tf })
      tr.stub = stubs.entity(tr)
      srec.links[#srec.links + 1] = { type = "spawned", dst = tid }
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

  -- spans
  local spans = M.spans_of(steps)
  local span_ids = {}
  local span_n = counter(be, sid, "spans")
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
  counter(be, sid, "spans", #spans)

  local list = {}
  for _, r in pairs(recs) do list[#list + 1] = r end
  table.sort(list, function(a, b) return (a.seq or 0) < (b.seq or 0) end)
  be.meta(sid, "seq", tostring(seq))
  return { steps = steps, spans = spans, records = list, edges = edges, span_ids = span_ids }
end

return M
