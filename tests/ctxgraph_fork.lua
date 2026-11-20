-- tests/ctxgraph_fork.lua -- graph memory across spawn{ fork = true }.
--
-- A forked child starts from a copy of its parent's conversation, outline
-- included, so the ids in that outline name records in the PARENT's graph.
-- The child reads through to the parent's graph (as it was at the fork) for
-- ids it does not hold itself, and never writes into it: its notes and its own
-- compactions go to its own graph. Its own compaction keeps the inherited
-- outline lines, and nothing the parent records after the fork shows through.
-- Run: boggart --eval tests/ctxgraph_fork.lua
bog.store.open()
dofile("tests/ctxgraph_fresh.lua")({ 501, 502, 503 })
local fork = require("fork")
local cg = require("ctxgraph")
local gtools = require("ctxgraph.tools")
local outline = require("ctxgraph.outline")
local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end
local function eq(a, b, msg) ck(a == b, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b))) end
local no_model = { stream = function() error("no model call expected") end, system = function() return "" end }

-- ---- a parent compacted into a graph -------------------------------------------------
local msgs = dofile("tests/ctxgraph_fixture.lua")()
msgs[#msgs + 1] = { role = "assistant", content = { { type = "tool_use", id = "last", name = "bash", input = { command = "true" } } } }
msgs[#msgs + 1] = { role = "user", content = { { type = "tool_result", tool_use_id = "last", content = "[exit=0]" } } }
local parent = { id = 501, model = "mock", memory = "local", messages = msgs, context_limit = 8000, compact_ratio = 0.01 }
ck(bog.api.compact(parent, no_model), "the parent compacted")
ck(outline.is_outline(parent.messages[1].content), "the parent's first message is an outline")
local be = cg.backend(parent)
local function count(sid) return #be.scan(sid) end
local parent_n = count("501")
ck(parent_n > 50, "the parent's graph has records (" .. parent_n .. ")")

-- the parent's next round is ingested live (lua/ctxgraph.lua ingest_live): in
-- its graph, searchable, but not collapsed
local pm = parent.messages
pm[#pm + 1] = { role = "assistant", content = { { type = "tool_use", id = "pl", name = "read", input = { path = "src/parent_live.py" } } } }
pm[#pm + 1] = { role = "user", content = { { type = "tool_result", tool_use_id = "pl", content = "src/parent_live.py lines 1-1 of 1\n1\tx" } } }
eq(cg.ingest_live(parent), 2, "the parent's live tail is ingested (the kept round and the new one)")
parent_n = count("501")

-- ---- the fork --------------------------------------------------------------------------
local prec = { id = 501, session = parent, skills = {}, allow = nil }
local crec = { id = 502, session = { id = 502, model = "mock", messages = {} } }
fork.adopt(crec, prec, {}, 100000)
local child = crec.session
eq(child.memory, "local", "the child inherits the memory tier")
eq(child.messages[1].content, parent.messages[1].content, "the child starts with the parent's outline")
ck(child.messages[1].content:find("- s/501/span/3  ", 1, true), "...whose ids name the parent's records")

-- expand a parent stub from inside the child
local out = gtools.expand(child, { id = "s/501/span/3" })
ck(not out:find("^Tool error"), "the child expands a parent span: " .. out:sub(1, 120))
ck(out:find("s/501/step/9", 1, true) and out:find("pytest", 1, true), "...and gets the parent's content")
out = gtools.expand(child, { id = "file/src/parser.py" })
ck(out:find("versions:", 1, true) and out:find("file/src/parser.py@v4", 1, true), "a parent entity expands in the child")
out = gtools.expand(child, { id = "s/501/step/6" })
ck(out:find("s/501/step/6/reasoning", 1, true), "a parent step expands in the child")
-- and through the registered tool, the way a model calls it
local saved = bog.session
bog.session = child
out = bog.tools.run("expand", { id = "s/501/span/1" })
ck(not out:find("^Tool error"), "expand through the tool registry, in the child: " .. out:sub(1, 120))
out = bog.tools.run("graph_recall", { query = "grammarkit" })
ck(out:find("pkg/pip/grammarkit", 1, true), "graph_recall in the child finds the parent's records: " .. out:sub(1, 120))

out = bog.tools.run("graph_recall", { query = "parent_live" })
ck(out:find("file/src/parent_live.py", 1, true), "...including the parent's live records as of the fork: " .. out:sub(1, 120))
do
  local msg = { role = "assistant", content = { { type = "tool_use", id = "q1", name = "read", input = { path = "src/parent_live.py" } } } }
  local rmsg = { role = "user", content = { { type = "tool_result", tool_use_id = "q1", content = "ok" } } }
  eq(gtools.after_round(child, msg, rmsg), 0, "a parent record that was live at the fork is not auto-expanded in the child")
end

-- ---- the child's writes stay in the child's graph ---------------------------------------
out = bog.tools.run("note", { text = "the child's own finding", about = "src/parser.py" })
local cid = out:match("Noted (claim/%x+)")
ck(cid, "the child records a note: " .. out)
ck(cid and be.get("502", cid), "the note is in the child's graph")
ck(cid and not be.get("501", cid), "...and not in the parent's")
eq(count("501"), parent_n, "the parent's graph is unchanged by the child's note")
bog.session = saved

-- ---- the child's first live round ingests only its own round --------------------------
-- The copied transcript's steps are the parent's live steps, readable through
-- the parent's graph; the child's graph does not take them again.
local cm = child.messages
cm[#cm + 1] = { role = "assistant", content = { { type = "tool_use", id = "c0", name = "read", input = { path = "src/child0.py" } } } }
cm[#cm + 1] = { role = "user", content = { { type = "tool_result", tool_use_id = "c0", content = "src/child0.py lines 1-1 of 1\n1\tx" } } }
eq(cg.ingest_live(child), 1, "the child's first live ingest is its own round only")
eq(#be.scan("502", { "step" }), 1, "...one step in the child's graph")
eq(be.get("502", "s/502/step/1") and be.get("502", "s/502/step/1").frontmatter.tools, "read", "...the child's read")
-- a resumed child (nothing cached) matches the copied steps the same way
eq(cg.ingest_live({ id = 502, model = "mock", memory = "local", messages = cm }), 0, "a resumed child ingests nothing again")

-- the child works, then compacts on its own
for i = 1, 6 do
  local id = "c" .. i
  cm[#cm + 1] = { role = "assistant", content = { { type = "tool_use", id = id, name = "read", input = { path = "src/child" .. i .. ".py" } } } }
  cm[#cm + 1] = { role = "user", content = { { type = "tool_result", tool_use_id = id, content = "src/child" .. i .. ".py lines 1-3 of 3\n1\tx" } } }
end
child.context_limit, child.compact_ratio = 8000, 0.01
ck(bog.api.compact(child, no_model), "the child compacted")
eq(count("501"), parent_n, "the parent's graph is unchanged by the child's compaction")
ck(#be.scan("502", { "compaction" }) == 1, "the child's compaction is recorded in the child's graph")
local cout = child.messages[1].content
ck(cout:find("- s/501/span/3  ", 1, true), "the child's new outline keeps the inherited parent lines")
ck(cout:find("file/src/child1.py", 1, true), "...and lists the child's own records")
local seen, dup = {}, false
for id in cout:gmatch("\n%- (%S+)  ") do
  if seen[id] then dup = true end
  seen[id] = true
end
ck(not dup, "no id is listed twice in the child's outline")
do
  local praw, copied = {}, 0
  for _, r in ipairs(be.scan("501", { "step" })) do praw[r.raw or ""] = true end
  for _, r in ipairs(be.scan("502", { "step" })) do if praw[r.raw or ""] then copied = copied + 1 end end
  eq(copied, 0, "the compaction did not copy the parent's steps into the child's graph")
  ck(#be.scan("502", { "step" }) >= 6, "...and holds the child's own steps (" .. #be.scan("502", { "step" }) .. ")")
end
ck(cout:find("- file/src/parent_live.py  ", 1, true),
  "a parent record live at the fork is listed once the child's compaction has collapsed it")
out = gtools.expand(child, { id = "s/501/span/3" })
ck(out:find("s/501/step/9", 1, true), "a parent stub still expands after the child's own compaction")

-- ---- what the parent records after the fork stays out of the child's view --------------
parent.memory = "local"
local pn = gtools.note(parent, { text = "zanzibar is a parent-only fact" })
ck(pn:find("^Noted"), "the parent notes something after the fork")
ck(gtools.recall(parent, { query = "zanzibar" }):find("claim/", 1, true), "the parent recalls it")
ck(gtools.recall(child, { query = "zanzibar" }):find("^No records match"), "the child does not see it")

-- ---- a fresh child of an unforked session has no parent view --------------------------
local lone = { id = 503, model = "mock", memory = "local", messages = {} }
ck(gtools.expand(lone, { id = "s/501/span/3" }):find("^Tool error"), "an unrelated session cannot read the parent's graph")

if fails == 0 then io.write("ok  ctxgraph_fork: a fork reads its parent's graph and writes only its own\n")
else io.write(string.format("FAIL ctxgraph_fork: %d check(s) failed\n", fails)); os.exit(1) end
