-- tests/ctxgraph_live.lua -- the live tail is searchable.
--
-- Steps are ingested as their tool round completes, not only at compaction,
-- so graph_recall finds a file read two steps ago before anything has been
-- compacted. The outline does not change between compactions (that is
-- ctxgraph_compact's cache-prefix check), each round costs one batched
-- put_nodes through the port, and the compaction that follows reuses the live
-- records instead of ingesting the same steps again. Records still in the kept
-- tail are not listed in the outline or auto-expanded: they are not collapsed.
-- Run: boggart --eval tests/ctxgraph_live.lua
bog.store.open()
dofile("tests/ctxgraph_fresh.lua")({ 701, 702, 703, 704 })
local json = require("json")
local cg = require("ctxgraph")
local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end
local function eq(a, b, msg) ck(a == b, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b))) end

local s = { id = 701, model = "mock", context_limit = 200000, memory = "local", messages = {} }
local be = cg.backend(s)

-- count port calls per round (meta split into reads and writes: on a remote
-- backend each is a round trip)
local calls, per_round = {}, {}
local meta_writes = {}   -- { sid, key, bytes } of every meta write
for _, op in ipairs({ "put_nodes", "put_edges", "get", "meta", "search", "scan" }) do
  local real = be[op]
  be[op] = function(...)
    calls[op] = (calls[op] or 0) + 1
    if op == "meta" then
      local sid, key, value = ...
      local rw = value ~= nil and "meta_w" or "meta_r"
      calls[rw] = (calls[rw] or 0) + 1
      if value ~= nil then meta_writes[#meta_writes + 1] = { sid = sid, key = key, bytes = #tostring(value) } end
    end
    return real(...)
  end
end

local script = {
  { "read", { path = "src/secret_config.py" }, "src/secret_config.py lines 1-2 of 2\n1\tTOKEN = 'zygomorphic'" },
  { "bash", { command = "ls src" }, "[exit=0]\nsecret_config.py\nmain.py" },
  { "graph_recall", { query = "secret_config" } },
  { "graph_recall", { query = "zygomorphic" } },
  { "read", { path = "src/tail_only.py" }, "src/tail_only.py lines 1-1 of 1\n1\tpass" },
}
local recall_out, rounds, comp_at_recall = {}, 0, nil
local function model(body)
  rounds = rounds + 1
  -- what the previous round cost through the port
  per_round[#per_round + 1] = { put_nodes = calls.put_nodes or 0, put_edges = calls.put_edges or 0,
                                get = calls.get or 0, meta = calls.meta or 0,
                                meta_r = calls.meta_r or 0, meta_w = calls.meta_w or 0 }
  calls = {}
  local last = body.messages[#body.messages]
  if rounds > 1 and script[rounds - 1][1] == "graph_recall" then
    for _, b in ipairs(last.content) do if b.type == "tool_result" then recall_out[#recall_out + 1] = b.content end end
    comp_at_recall = s.usage and s.usage.graph and s.usage.graph.compactions or 0
  end
  local st = script[rounds]
  if not st then
    return { role = "assistant", content = { { type = "text", text = "done" } }, usage = { input_tokens = 10, output_tokens = 1 } }, "end_turn"
  end
  return { role = "assistant", content = { { type = "tool_use", id = "u" .. rounds, name = st[1], input = st[2] } },
           usage = { input_tokens = 10, output_tokens = 1 } }, "tool_use"
end
local saved = bog.session
bog.session = s
local _, stop = bog.api.run_on(s, "Find where the token is configured.", nil, {
  stream = model, system = function() return "SYSTEM" end,
  tools = function() return bog.tools.offered(s) end,
  run_tool = function(name, input)
    if name == "graph_recall" then return bog.tools.run(name, input) end
    for _, st in ipairs(script) do if st[1] == name and json.encode(st[2]) == json.encode(input) then return st[3] end end
    return "[exit=0]"
  end })
bog.session = saved
eq(stop, "end_turn", "the turn finished")
eq(comp_at_recall, 0, "no compaction had happened when recall ran")
ck(recall_out[1] and recall_out[1]:find("file/src/secret_config.py", 1, true),
  "recall finds the file read two steps ago, before any compaction: " .. tostring(recall_out[1]))
ck(recall_out[2] and recall_out[2]:find("s/701/step/", 1, true),
  "recall finds a step by text in its output: " .. tostring(recall_out[2]))
-- per_round[k + 1] holds what tool round k cost
for k = 1, #script do
  local c = per_round[k + 1] or {}
  eq(c.put_nodes, 1, "round " .. k .. ": one batched put_nodes")
  eq(c.put_edges, 0, "round " .. k .. ": no separate put_edges")
end
-- graph meta: the first round reads the graph's state once per process (a
-- graph with no state key yet costs one more read, the probe for an older
-- layout); after that a round reads nothing and writes the state at most once
for k = 1, #script do
  local c = per_round[k + 1] or {}
  ck((c.meta_r or 0) <= (k == 1 and 2 or 0), string.format("round %d: %s meta read(s) (want <= %d)", k,
    tostring(c.meta_r), k == 1 and 2 or 0))
  ck((c.meta_w or 0) <= 1, string.format("round %d: %s meta write(s) (want <= 1)", k, tostring(c.meta_w)))
end
for k = 1, #script do
  local c = per_round[k + 1] or {}
  io.write(string.format("  round %d (%s) through the port: put_nodes=%d put_edges=%d get=%d meta=%d (r=%d w=%d)\n",
    k, script[k][1], c.put_nodes or 0, c.put_edges or 0, c.get or 0, c.meta or 0, c.meta_r or 0, c.meta_w or 0))
end

-- ---- the compaction that follows -------------------------------------------------------
local function steps_by_raw()
  local n, raws, dup = 0, {}, false
  for _, r in ipairs(be.scan("701", { "step" })) do
    n = n + 1
    if raws[r.raw] then dup = true end
    raws[r.raw] = true
  end
  return n, dup
end
local live_steps = #be.scan("701", { "step" })
ck(live_steps >= #script, "the live steps are in the graph (" .. live_steps .. ")")
local fid = be.get("701", "file/src/secret_config.py")
eq(fid and fid.frontmatter.reads, 1, "the file has one read")
-- keep exactly the last tool round (the tail_only read) and the final answer
do
  local window = require("window")
  local n = #s.messages
  local keep = window.tokens_of(s.messages, n - 2, n)
  s.context_limit, s.compact_ratio = 100000, (keep * 4 + 2) / 100000
end
ck(bog.api.compact(s, { stream = function() error("no model call") end, system = function() return "" end }), "compacted")
local n_after, dup = steps_by_raw()
-- the final answer (no tool round) is the one step only compaction could add
ck(n_after <= live_steps + 1, string.format("compaction added no duplicate steps (%d live, %d after)", live_steps, n_after))
ck(not dup, "no two step records hold the same messages")
fid = be.get("701", "file/src/secret_config.py")
eq(fid and fid.frontmatter.reads, 1, "the file still has one read: the step was not folded in twice")
local nums, contiguous = {}, true
for _, r in ipairs(be.scan("701", { "step" })) do nums[#nums + 1] = r.frontmatter.n end
table.sort(nums)
for i, n in ipairs(nums) do if n ~= i then contiguous = false end end
ck(contiguous, "step numbers are 1..n with no gaps or repeats: " .. table.concat(nums, ","))
local outl = s.messages[1].content
ck(outl:find("file/src/secret_config.py", 1, true), "the collapsed file is in the outline")
local spans = be.scan("701", { "span" })
local in_spans = 0
for _, sp in ipairs(spans) do in_spans = in_spans + #be.children("701", sp.id, "contains") end
eq(in_spans, n_after - 0 - (function()
  -- steps still in the kept tail are in no span
  local live = 0
  for _, r in ipairs(be.scan("701", { "step" })) do
    if #be.referrers("701", r.id, "contains") == 0 then live = live + 1 end
  end
  return live
end)(), "every collapsed step is in exactly one span")

-- what the kept tail touched is live, not collapsed: not listed, not auto-expanded
local tail_has = json.encode({ table.unpack(s.messages, 2) }):find("tail_only.py", 1, true)
eq(#s.messages, 4, "the kept tail: the tail_only round and the answer, after the outline")
if tail_has then
  ck(not outl:find("file/src/tail_only.py", 1, true), "a file only the kept tail touched is not in the outline")
  local msg = { role = "assistant", content = { { type = "tool_use", id = "z1", name = "read", input = { path = "src/tail_only.py" } } } }
  local rmsg = { role = "user", content = { { type = "tool_result", tool_use_id = "z1", content = "ok" } } }
  eq(require("ctxgraph.tools").after_round(s, msg, rmsg), 0, "...and is not auto-expanded")
else
  ck(false, "the kept tail should hold the tail_only read (test setup)")
end

-- a second compaction collapses the old tail without duplicating it
local cm = s.messages
for i = 1, 3 do
  cm[#cm + 1] = { role = "assistant", content = { { type = "tool_use", id = "w" .. i, name = "bash", input = { command = "true " .. i } } } }
  cm[#cm + 1] = { role = "user", content = { { type = "tool_result", tool_use_id = "w" .. i, content = "[exit=0]" } } }
end
ck(bog.api.compact(s, { stream = function() error("no model call") end, system = function() return "" end }), "compacted again")
local _, dup2 = steps_by_raw()
ck(not dup2, "no duplicate steps after the second compaction")
ck(s.messages[1].content:find("file/src/tail_only.py", 1, true), "the old tail's file is listed once it is collapsed")
eq(be.get("701", "file/src/tail_only.py").frontmatter.reads, 1, "...with one read")

-- ---- servers that reuse tool-call ids ---------------------------------------------------
-- Some OpenAI-compatible servers number calls per response (call_0 every
-- time), so two rounds can be byte-identical. Each is still its own step.
do
  local r = { id = 702, model = "mock", memory = "local", messages = { { role = "user", content = "poll it" } } }
  local function poll()
    r.messages[#r.messages + 1] = { role = "assistant", content = { { type = "tool_use", id = "call_0", name = "bash", input = { command = "ls" } } } }
    r.messages[#r.messages + 1] = { role = "user", content = { { type = "tool_result", tool_use_id = "call_0", content = "[exit=0]\nx" } } }
    return cg.ingest_live(r)
  end
  eq(poll(), 2, "first round: the prompt and the call")
  eq(poll(), 1, "an identical second round is a new step")
  eq(poll(), 1, "...and a third")
  eq(#be.scan("702", { "step" }), 4, "four steps in the graph")
  r.context_limit, r.compact_ratio = 100000, 0.0001
  ck(bog.api.compact(r, { stream = function() error("no model call") end, system = function() return "" end }), "compacted")
  eq(#be.scan("702", { "step" }), 4, "the compaction reused all four")
  eq(be.get("702", "cmd/" .. require("ctxgraph.extract").sha("ls"):sub(1, 12)).frontmatter.runs, 3, "the command ran three times, counted once each")
end

-- ---- what a round writes to meta does not grow with the steps since a compaction --------
-- (the live list is a range of step numbers, not a list re-encoded every round)
do
  local r = { id = 703, model = "mock", memory = "local", messages = { { role = "user", content = "loop" } } }
  local sizes = {}
  for i = 1, 40 do
    r.messages[#r.messages + 1] = { role = "assistant", content = { { type = "tool_use", id = "l" .. i, name = "bash", input = { command = "step " .. i } } } }
    r.messages[#r.messages + 1] = { role = "user", content = { { type = "tool_result", tool_use_id = "l" .. i, content = "[exit=0]" } } }
    local from = #meta_writes
    calls = {}
    cg.ingest_live(r)
    ck((calls.meta_r or 0) == 0 or i == 1, "loop round " .. i .. ": no meta read after the first")
    eq(calls.meta_w or 0, 1, "loop round " .. i .. ": one meta write")
    local b = 0
    for j = from + 1, #meta_writes do b = b + meta_writes[j].bytes end
    sizes[i] = b
  end
  ck(sizes[40] - sizes[5] <= 8, string.format("the per-round meta write stays the same size (round 5: %d bytes, round 40: %d)",
    sizes[5], sizes[40]))

  -- a resumed conversation (a new process: nothing cached) matches its live
  -- steps instead of ingesting them again, and its compaction reuses them
  local again = { id = 703, model = "mock", memory = "local", messages = r.messages }
  eq(cg.ingest_live(again), 0, "a resume ingests no step twice")
  eq(#be.scan("703", { "step" }), 41, "41 steps in the graph")
  again.context_limit, again.compact_ratio = 100000, 0.0001
  ck(bog.api.compact(again, { stream = function() error("no model call") end, system = function() return "" end }), "the resumed conversation compacted")
  eq(#be.scan("703", { "step" }), 41, "...reusing the live steps")
  local cmd = be.get("703", "cmd/" .. require("ctxgraph.extract").sha("step 7"):sub(1, 12))
  eq(cmd and cmd.frontmatter.runs, 1, "...each folded in once")
end

-- ---- a graph written before the state key (separate meta keys) still loads ---------------
do
  local sq = require("ctxgraph.sqlite")
  local msgs = { { role = "user", content = "old graph" },
    { role = "assistant", content = { { type = "tool_use", id = "o1", name = "bash", input = { command = "old 1" } } } },
    { role = "user", content = { { type = "tool_result", tool_use_id = "o1", content = "[exit=0]" } } } }
  local ingest = require("ctxgraph.ingest")
  local steps = ingest.steps_of(msgs, 1, #msgs)
  local live = {}
  for i, st in ipairs(steps) do
    live[i] = { k = ingest.step_key(st), n = i }
    sq.put_nodes("704", { { id = "s/704/step/" .. i, type = "step", title = "step " .. i, stub = "old", seq = i,
      frontmatter = { n = i }, digest = string.rep("0", 64), links = {} } })
  end
  sq.meta("704", "seq", "2"); sq.meta("704", "steps", "2"); sq.meta("704", "live", json.encode(live))
  local o = { id = 704, model = "mock", memory = "local", messages = msgs }
  eq(cg.ingest_live(o), 0, "an old-format graph: its live steps are matched, not ingested again")
  msgs[#msgs + 1] = { role = "assistant", content = { { type = "tool_use", id = "o2", name = "bash", input = { command = "old 2" } } } }
  msgs[#msgs + 1] = { role = "user", content = { { type = "tool_result", tool_use_id = "o2", content = "[exit=0]" } } }
  eq(cg.ingest_live(o), 1, "...and the next round is step 3")
  ck(be.get("704", "s/704/step/3"), "s/704/step/3 exists")
end

if fails == 0 then io.write("ok  ctxgraph_live: the live tail is searchable, one put per round, no duplicates\n")
else io.write(string.format("FAIL ctxgraph_live: %d check(s) failed\n", fails)); os.exit(1) end
