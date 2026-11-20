-- tests/ctxgraph_threads.lua -- a thread record holds what its child returned.
--
-- spawn answers with the child's id ({"spawned":N}); the child's answer comes
-- back later, in an await's result ("### agent N (...)" sections after the
-- verdict). The thread record is updated when that answer is seen: its stub
-- says what came back, `expand` shows it, and it works when the spawn and the
-- await fall in different compactions. A failed child is marked as failed.
-- Run: boggart --eval tests/ctxgraph_threads.lua
bog.store.open()
dofile("tests/ctxgraph_fresh.lua")({ 601, 602, 603, 604, 605 })
local cg = require("ctxgraph")
local gtools = require("ctxgraph.tools")
local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end
local function eq(a, b, msg) ck(a == b, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b))) end
local no_model = { stream = function() error("no model call expected") end, system = function() return "" end }

local n = 0
local function step(msgs, name, input, result)
  n = n + 1
  local id = "t" .. n
  msgs[#msgs + 1] = { role = "assistant", content = { { type = "tool_use", id = id, name = name, input = input } } }
  msgs[#msgs + 1] = { role = "user", content = { { type = "tool_result", tool_use_id = id, content = result } } }
end
local function filler(msgs, k)
  for i = 1, k do step(msgs, "read", { path = "src/f" .. n .. ".py" }, "src/f.py lines 1-2 of 2\n1\tx") end
end
local VERDICT = "VERDICT (computed, not self-reported): %d of %d agents succeeded, %d failed. "
  .. "Report this honestly; do not call a partial fan-out a success."
local function threads(be, sid)
  local by = {}
  for _, r in ipairs(be.scan(sid, { "thread" })) do by[r.frontmatter.task] = r end
  return by
end

-- ---- spawn and await in one compaction ---------------------------------------------
local msgs = { { role = "user", content = "Review the parser." } }
step(msgs, "spawn", { task = "Review src/parser.py for unsafe eval" }, '{"spawned":42}')
step(msgs, "spawn", { task = "Count the widgets" }, '{"spawned":43}')
filler(msgs, 3)
step(msgs, "await", { ids = { 42, 43 } }, string.format(VERDICT, 1, 2, 1)
  .. "\n\n### agent 42 (critic)\nThe eval on line 2 is unsafe: use ast.literal_eval instead."
  .. "\n\n### agent 43 (agent) [error]\nbudget exhausted before counting")
filler(msgs, 2)
local sess = { id = 601, model = "mock", memory = "local", messages = msgs, context_limit = 8000, compact_ratio = 0.01 }
ck(bog.api.compact(sess, no_model), "compacted")
local be = cg.backend(sess)
local th = threads(be, "601")
local t42, t43 = th["Review src/parser.py for unsafe eval"], th["Count the widgets"]
ck(t42 and t43, "two thread records")
eq(t42 and t42.frontmatter.agent, 42, "a thread knows its child's agent id")
ck(t42 and t42.stub:find("ast.literal_eval", 1, true), "the thread's stub says what came back: " .. tostring(t42 and t42.stub))
ck(t43 and t43.stub:find("failed", 1, true), "a failed child's thread says it failed: " .. tostring(t43 and t43.stub))
eq(t42 and t42.frontmatter.returned_ok, true, "the return is marked ok")
eq(t43 and t43.frontmatter.returned_ok, false, "the failed return is marked failed")
local outl = sess.messages[1].content
ck(outl:find("Review src/parser.py for unsafe eval -> ", 1, true) and outl:find("ast.literal_eval", 1, true),
  "the outline's thread line carries the answer")
local out = gtools.expand(sess, { id = t42 and t42.id or "?" })
ck(out:find("The eval on line 2 is unsafe: use ast.literal_eval instead.", 1, true),
  "expand on the thread shows the child's whole answer: " .. out:sub(1, 200))
ck(out:find("returned", 1, true), "...marked as what it returned")

-- ---- spawn in one compaction, the answer in the next ---------------------------------
n = 100
local m2 = { { role = "user", content = "Second task." } }
step(m2, "spawn", { task = "Find the slow query" }, '{"spawned":77}')
filler(m2, 4)
local s2 = { id = 602, model = "mock", memory = "local", messages = m2, context_limit = 8000, compact_ratio = 0.01 }
ck(bog.api.compact(s2, no_model), "first compaction")
local t77 = threads(be, "602")["Find the slow query"]
ck(t77 and not t77.frontmatter.returned, "no answer yet after the first compaction")
step(s2.messages, "await", { ids = { 77 } }, string.format(VERDICT, 1, 1, 0)
  .. "\n\n### agent 77 (agent)\nThe slow query is the unindexed join in report.sql.")
filler(s2.messages, 3)
ck(bog.api.compact(s2, no_model), "second compaction")
t77 = threads(be, "602")["Find the slow query"]
ck(t77 and t77.stub:find("unindexed join", 1, true), "the thread collapsed earlier is updated with the answer: "
  .. tostring(t77 and t77.stub))
ck(s2.messages[1].content:find("unindexed join", 1, true), "the rebuilt outline shows it")
eq(#be.scan("602", { "thread" }), 1, "still one thread record")

-- ---- an answer that never comes through await -----------------------------------------
-- A child reports when it exits (lua/thread.lua _run). The parent may read the
-- report only through `inbox`, or never read it; the thread record still gets
-- the answer, because it is recorded at the child's exit.
local function thread_of(sid, task) return threads(be, sid)[task] end
local function record_return(...) return cg.record_return ~= nil and cg.record_return(...) end

-- (1) the parent reads the report through inbox
n = 200
local m3 = { { role = "user", content = "Third task." } }
step(m3, "spawn", { task = "Map the lexer states" }, '{"spawned":91}')
local s3 = { id = 603, model = "mock", memory = "local", messages = m3, context_limit = 8000, compact_ratio = 0.01 }
cg.ingest_live(s3)
ck(thread_of("603", "Map the lexer states"), "the spawn's thread is in the graph")
-- the child exits: what the actor exit does for graph memory
ck(record_return(s3, 91, true, "The lexer has four states: start, ident, number, string."),
  "the child's exit report is recorded in the parent's graph")
step(m3, "inbox", {}, "from 91: The lexer has four states: start, ident, number, string.")
cg.ingest_live(s3)
local t91 = thread_of("603", "Map the lexer states")
ck(t91 and t91.stub:find("four states", 1, true), "a report read only through inbox is in the thread: " .. tostring(t91 and t91.stub))
eq(t91 and t91.frontmatter.returned_ok, true, "...marked ok")
ck(gtools.expand(s3, { id = t91 and t91.id or "?" }):find("start, ident, number, string", 1, true), "expand shows the answer")
filler(m3, 3)
ck(bog.api.compact(s3, no_model), "compacted")
ck(s3.messages[1].content:find("four states", 1, true), "the outline's thread line carries it after a compaction")

-- (2) the parent never reads it; and the child returns before the parent's
-- spawn round is in the graph
n = 300
local m4 = { { role = "user", content = "Fourth task." } }
step(m4, "spawn", { task = "Check the build flags" }, '{"spawned":92}')
local s4 = { id = 604, model = "mock", memory = "local", messages = m4, context_limit = 8000, compact_ratio = 0.01 }
record_return(s4, 92, false, "budget exhausted before checking")
cg.ingest_live(s4)
local t92 = thread_of("604", "Check the build flags")
ck(t92 and t92.stub:find("failed", 1, true) and t92.stub:find("budget exhausted", 1, true),
  "a child that returned before its spawn was ingested, and was never awaited: " .. tostring(t92 and t92.stub))
eq(t92 and t92.frontmatter.returned_ok, false, "...marked failed")

-- (3) through the real actor exit: thread._run reports to the parent's graph
do
  bog.thread = bog.thread or require("thread")
  if swarm and swarm.attach then pcall(swarm.attach, bog.db) end
  n = 400
  local m5 = { { role = "user", content = "Fifth task." } }
  step(m5, "spawn", { task = "Summarise the README" }, '{"spawned":95}')
  local s5 = { id = 605, model = "mock", memory = "local", messages = m5, context_limit = 8000, compact_ratio = 0.01 }
  cg.ingest_live(s5)
  bog.thread.live_recs[605] = { id = 605, session = s5 }
  local child = { id = 95, parent_id = 605, spawned = true, spec_name = "agent",
    session = { id = 95, model = "mock", messages = {} },
    opts = { stream = function(_, sink)
      local said = "The README says: run make, then make test."
      if sink then sink(said) end   -- what streaming does; _run reports the streamed text
      return { role = "assistant", content = { { type = "text", text = said } },
               usage = { input_tokens = 1, output_tokens = 1 } }, "end_turn"
    end, system = function() return "" end, tools = function() return {} end } }
  bog.thread.live_recs[95] = child
  local okr, err = pcall(bog.thread._run, child, "Summarise the README")
  ck(okr, "the child ran: " .. tostring(err))
  local t95 = thread_of("605", "Summarise the README")
  ck(t95 and t95.stub:find("run make, then make test", 1, true),
    "the actor exit put the child's answer in the parent's thread: " .. tostring(t95 and t95.stub))
  bog.thread.live_recs[605] = nil
end

if fails == 0 then io.write("ok  ctxgraph_threads: a thread record holds what its child returned\n")
else io.write(string.format("FAIL ctxgraph_threads: %d check(s) failed\n", fails)); os.exit(1) end
