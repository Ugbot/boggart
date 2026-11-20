-- tests/ctxgraph_threads.lua -- a thread record holds what its child returned.
--
-- spawn answers with the child's id ({"spawned":N}); the child's answer comes
-- back later, in an await's result ("### agent N (...)" sections after the
-- verdict). The thread record is updated when that answer is seen: its stub
-- says what came back, `expand` shows it, and it works when the spawn and the
-- await fall in different compactions. A failed child is marked as failed.
-- Run: boggart --eval tests/ctxgraph_threads.lua
bog.store.open()
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

if fails == 0 then io.write("ok  ctxgraph_threads: a thread record holds what its child returned\n")
else io.write(string.format("FAIL ctxgraph_threads: %d check(s) failed\n", fails)); os.exit(1) end
