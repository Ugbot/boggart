-- tests/ctxgraph_tools.lua -- the graph-memory tools and the harness's own
-- expansion: expand / graph_recall / note round trips against a compacted
-- conversation, and auto-expand firing on a path, a package and a repeated
-- error, within its cap of two records and its token budget, once each.
-- Run: boggart --eval tests/ctxgraph_tools.lua
bog.store.open()
dofile("tests/ctxgraph_fresh.lua")({ 401, 402 })
local util = require("util")
local gtools = require("ctxgraph.tools")
local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end
local function eq(a, b, msg) ck(a == b, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b))) end

local msgs = dofile("tests/ctxgraph_fixture.lua")()
-- a step whose output was too big to keep inline: shape_result saved it
local big = {}
for i = 1, 2000 do big[i] = "build log line " .. i end
local shaped = util.shape_result(table.concat(big, "\n"), { max_bytes = 6000, head_lines = 100 })
msgs[#msgs + 1] = { role = "assistant", content = { { type = "tool_use", id = "big", name = "bash", input = { command = "make all" } } } }
msgs[#msgs + 1] = { role = "user", content = { { type = "tool_result", tool_use_id = "big", content = "[exit=0]\n" .. shaped } } }
msgs[#msgs + 1] = { role = "assistant", content = { { type = "tool_use", id = "last", name = "bash", input = { command = "true" } } } }
msgs[#msgs + 1] = { role = "user", content = { { type = "tool_result", tool_use_id = "last", content = "[exit=0]" } } }

local sess = { id = 401, model = "mock", memory = "local", messages = msgs, context_limit = 8000, compact_ratio = 0.01 }
bog.session = sess
ck(bog.api.compact(sess, { stream = function() error("no model call expected") end, system = function() return "" end }),
  "compacted")
local outline_text = sess.messages[1].content
eq(#sess.messages, 3, "only the last call and its result are kept")

local function run(name, input) return bog.tools.run(name, input) end

-- ---- expand ------------------------------------------------------------------------
local out = run("expand", { id = "file/src/parser.py" })
ck(out:find("versions:", 1, true) and out:find("file/src/parser.py@v4", 1, true), "expand a file: its versions")
ck(out:find("s/401/step/8", 1, true), "...and the steps that touched it")
out = run("expand", { id = "s/401/span/3" })
ck(out:find("s/401/step/9", 1, true) and out:find("pytest", 1, true), "expand a span: its steps")
out = run("expand", { id = "s/401/step/42" })
ck(out:find("make all", 1, true) and out:find("[full output", 1, true) and out:find("build log line 150\n", 1, true),
  "expand a step: its messages and the saved full output")
ck(not out:find("build log line 1500", 1, true), "the read-back is bounded like tool output")
out = run("expand", { id = "s/401/step/6" })
ck(out:find("s/401/step/6/reasoning", 1, true) and not out:find("needed for the grammar", 1, true),
  "a step's reasoning stays collapsed")
out = run("expand", { id = "s/401/step/6/reasoning" })
ck(out:find("needed for the grammar", 1, true), "...until it is expanded itself")
ck(run("expand", { id = "nope" }):find("^Tool error:"), "an unknown id is an error")
eq(sess.messages[1].content, outline_text, "expanding never touches the outline")

-- ---- graph_recall -----------------------------------------------------------------
out = run("graph_recall", { query = "grammarkit" })
ck(out:find("pkg/pip/grammarkit", 1, true), "recall finds the package by name")
out = run("graph_recall", { query = "NameError arith" })
ck(out:find("error/", 1, true), "recall finds the error text")
ck(run("graph_recall", { query = "zebra quokka" }):find("^No records match"), "recall with no hits says so")

-- ---- note ---------------------------------------------------------------------------
out = run("note", { text = "the tests need PYTHONPATH=src", about = "src/parser.py" })
local cid = out:match("Noted (claim/%x+)")
ck(cid, "note records a claim: " .. out)
local be = require("ctxgraph").backend(sess)
local c = cid and be.get("401", cid)
eq(c and c.state, "unverified", "a model's note is unverified")
local about
for _, l in ipairs(c and c.links or {}) do if l.type == "about" then about = l.dst end end
eq(about, "file/src/parser.py", "...about the file it names")
ck(run("note", { text = "the tests need PYTHONPATH=src", about = "src/parser.py" }):find("^Already noted"),
  "claims only add: the same note twice is one claim")
eq(sess.messages[1].content, outline_text, "a note does not change the outline before the next compaction")

-- ---- auto-expand --------------------------------------------------------------------
local function round(calls, result_text)
  local msg = { role = "assistant", content = {} }
  local rmsg = { role = "user", content = {} }
  for i, c in ipairs(calls) do
    msg.content[i] = { type = "tool_use", id = "r" .. i, name = c[1], input = c[2] }
    rmsg.content[i] = { type = "tool_result", tool_use_id = "r" .. i, content = result_text or "[exit=0]" }
  end
  return msg, rmsg
end
local function harness_blocks(rmsg)
  local n, bytes = 0, 0
  for _, b in ipairs(rmsg.content) do
    if b.type == "text" and b.text:find("^%[harness: auto%-expanded") then n = n + 1; bytes = bytes + #b.text end
  end
  return n, bytes
end
local g0 = sess.usage.graph.expands_harness
-- names a file, a package and repeats a known error: three candidates, cap two
local msg, rmsg = round({ { "read", { path = "src/arith.py" } },
                          { "bash", { command = "pip install grammarkit && python -m pytest tests/test_parser.py" } } },
  "[exit=1]\nE   AssertionError: expected 3, got None")
eq(gtools.after_round(sess, msg, rmsg), 2, "auto-expand: at most two records per step")
local n, bytes = harness_blocks(rmsg)
eq(n, 2, "two marked harness blocks on the round's results")
ck(bytes <= require("ctxgraph").AUTOEXPAND_TOKENS * 4, "within the token budget (" .. bytes .. " bytes)")
ck(rmsg.content[3].text:find("error/", 1, true), "the repeated error comes first")
ck(rmsg.content[4].text:find("file/src/arith.py", 1, true), "then the file")
eq(sess.usage.graph.expands_harness - g0, 2, "telemetry: harness expansions counted")
msg, rmsg = round({ { "read", { path = "src/arith.py" } } })
eq(gtools.after_round(sess, msg, rmsg), 0, "a record already expanded is not expanded again")
msg, rmsg = round({ { "bash", { command = "pip install grammarkit" } } })
eq(gtools.after_round(sess, msg, rmsg), 1, "the package left over from the cap comes next time")
msg, rmsg = round({ { "read", { path = "src/lexer.py" } } })
sess.graph_autoexpand = false
eq(gtools.after_round(sess, msg, rmsg), 0, "auto-expand can be switched off")
sess.graph_autoexpand = nil
msg, rmsg = round({ { "read", { path = "src/parser.pyc" } } })
eq(gtools.after_round(sess, msg, rmsg), 0, "a path that only contains a known path is not a match")
eq(sess.messages[1].content, outline_text, "auto-expand never touches the outline")

-- ---- off the graph tier ------------------------------------------------------------
bog.session = { id = 402, model = "mock", messages = {} }
ck(run("expand", { id = "x" }):find("graph memory is off", 1, true), "the tools refuse on the summary tier")

if fails == 0 then io.write("ok  ctxgraph_tools: expand, graph_recall, note and auto-expand\n")
else io.write(string.format("FAIL ctxgraph_tools: %d check(s) failed\n", fails)); os.exit(1) end
