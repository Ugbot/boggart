-- tests/ctxgraph_ingest.lua -- graph memory ingest: steps, entities, claims,
-- spans and stubs from a scripted 40-step transcript (tests/ctxgraph_fixture.lua).
--
-- Locks in: node and edge counts by type, where spans break and why, that a
-- file edited three ways has its versions, that a repeated failing command is
-- one command entity and one error entity with counts, harness claims start
-- reproduced, and that stubs and the outline are byte-identical across runs
-- and across backends (SQLite and an in-memory fake).
-- Run: boggart --eval tests/ctxgraph_ingest.lua
bog.store.open()
local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end
local function eq(a, b, msg) ck(a == b, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b))) end

local ingest = require("ctxgraph.ingest")
local outline = require("ctxgraph.outline")
local fake = dofile("tests/ctxgraph_fakebackend.lua")
local msgs = dofile("tests/ctxgraph_fixture.lua")()

local function run(be, sid)
  local got = ingest.run(be, sid, msgs, 1, #msgs, { root = "/work" })
  be.put_nodes(sid, got.records)
  be.put_edges(sid, got.edges)
  return got
end

local sq = require("ctxgraph.sqlite")
local got = run(sq, "41")

-- ---- counts ----------------------------------------------------------------------
eq(#got.steps, 41, "steps: the request plus 40 replies")
local by = {}
for _, r in ipairs(got.records) do by[r.type] = (by[r.type] or 0) + 1 end
local want = { step = 41, reasoning = 2, span = 12, thread = 1, file = 17, version = 11, package = 2,
               command = 6, test = 1, error = 3, claim = 11 }
for t, n in pairs(want) do eq(by[t], n, "records of type " .. t) end
eq(#got.records, 107, "records in all")
eq(#got.edges, 75, "edges put separately (step -> entity / version / claim)")
local all_ok = true
for _, r in ipairs(got.records) do
  local ok, why = require("ctxgraph.backend").valid_record(r)
  if not ok then all_ok = false; io.write("    bad record ", r.id, ": ", why, "\n") end
end
ck(all_ok, "every record is LOKF-shaped at the port")

-- ---- spans ------------------------------------------------------------------------
local cuts = {}
for _, sp in ipairs(got.spans) do
  cuts[#cuts + 1] = string.format("%d-%d:%s", sp.steps[1].n, sp.steps[#sp.steps].n, sp.closed_by)
end
eq(table.concat(cuts, " "),
  "1-3:shift 4-6:shift 7-11:retry_end 12-15:shift 16-19:shift 20-23:shift 24-25:spawn "
  .. "26-29:retry_end 30-34:shift 35-37:shift 38-40:shift 41-41:compaction", "span boundaries")
for _, sp in ipairs(got.spans) do ck(#sp.steps <= ingest.SPAN_MAX_STEPS, "span within the size cap") end

-- ---- entities ------------------------------------------------------------------------
local parser = sq.get("41", "file/src/parser.py")
eq(parser.frontmatter.versions, 4, "parser.py: four versions (write, edit, edit, edit)")
local vs = sq.versions("41", "file/src/parser.py")
eq(#vs, 4, "versions() returns them")
eq(vs[1].id, "file/src/parser.py@" .. require("ctxgraph.extract").sha("def parse(s):\n    return None\n"):sub(1, 12),
  "a written version is keyed by its content digest")
eq(vs[2].id, "file/src/parser.py@v2", "an edit with no digest known is keyed by its number")
local cmd = sq.scan("41", { "command" })
local pytest
for _, c in ipairs(cmd) do if c.frontmatter.command == "python -m pytest tests/test_parser.py" then pytest = c end end
eq(pytest and pytest.frontmatter.runs, 7, "the repeated test command is one entity, run 7 times")
local errs = sq.scan("41", { "error" })
local assert_err
for _, e in ipairs(errs) do if e.frontmatter.line:find("AssertionError", 1, true) then assert_err = e end end
eq(assert_err and assert_err.frontmatter.count, 3, "the repeated error is one entity, seen 3 times")
eq(sq.get("41", "pkg/pip/numpy").frontmatter.state, "installed", "numpy installed")
eq(sq.get("41", "pkg/pip/grammarkit").frontmatter.state, "install_failed", "grammarkit failed")
eq(sq.get("41", "test/pytest_tests/test_parser.py").frontmatter.last, "passed", "the test's latest result")
for _, c in ipairs(sq.scan("41", { "claim" })) do eq(c.state, "reproduced", "harness claim " .. c.id .. " is reproduced") end
eq(#sq.children("41", "s/41/step/6", "has_reasoning"), 1, "reasoning is its own record under its step")
eq(#sq.children("41", "s/41/step/26", "spawned"), 1, "the spawn step links its thread")

-- ---- byte-stable stubs ------------------------------------------------------------------
local function stubs_of(be, sid)
  local out = {}
  for _, r in ipairs(be.scan(sid)) do out[#out + 1] = r.id .. "\t" .. (r.stub or "") end
  return table.concat(out, "\n")
end
local f1, f2 = fake(), fake()
run(f1, "41"); run(f2, "41")
local s_sql, s_f1, s_f2 = stubs_of(sq, "41"), stubs_of(f1, "41"), stubs_of(f2, "41")
ck(#s_sql > 1000, "stubs were made")
ck(s_f1 == s_f2, "stubs are byte-identical across two runs")
ck(s_sql == s_f1, "...and across backends (sqlite vs the in-memory fake)")
local o_sql = outline.render(sq, "41", "TASK")
local o_fake = outline.render(f1, "41", "TASK")
ck(o_sql == o_fake, "the outline is byte-identical across backends")
ck(o_sql:find("- s/41/span/12  ", 1, true) and o_sql:find("- file/src/parser.py  src/parser.py v4", 1, true),
  "the outline names spans and entities by id")
ck(not o_sql:find("exits 0", 1, true), "exit-status claims stay out of the outline")
ck(o_sql:find("`python -m pytest tests/test_parser.py` x7", 1, true), "a repeated command is listed with its count")

if fails == 0 then io.write("ok  ctxgraph_ingest: 41 steps -> 107 records, 12 spans, stable stubs\n")
else io.write(string.format("FAIL ctxgraph_ingest: %d check(s) failed\n", fails)); os.exit(1) end
