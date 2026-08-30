-- tests/codesearch.lua -- the native bm25 code index (store) and the code_search
-- tool's native tier. Run: `./boggart --eval tests/codesearch.lua`. cwd is the
-- repo root under --eval, which the index walk relies on. No MCP server, no
-- model: the tool falls to its native bm25 backend, which is what this pins.
local fails = 0
local function check(ok, msg)
  if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end
end
local function top_paths(rows, k)
  local s = {}
  for i = 1, math.min(k or #rows, #rows) do s[rows[i].path] = i end
  return s
end

-- ---- the store index -------------------------------------------------------
local r = bog.store.code_reindex({ rebuild = true })
check(type(r) == "table" and r.indexed > 0, "code_reindex indexes files (" .. tostring(r and r.indexed) .. ")")
check(bog.store.code_index_count() == r.indexed, "code_index_count matches what was indexed")

-- Ranked, not just matched: the voice source should top a voice query.
local hits = bog.store.code_search("whisper transcription voice", 8)
check(#hits > 0, "code_search returns hits for a real query")
check(hits[1] and hits[1].path == "src/lvoice.c",
  "the most relevant file ranks first (got " .. tostring(hits[1] and hits[1].path) .. ")")
check(top_paths(hits, 8)["tests/voice.lua"] ~= nil, "the voice test is among the top hits")
-- Scores are bigger-is-better and descending (bm25 negated in the store).
local ordered = true
for i = 2, #hits do if hits[i].score > hits[i - 1].score + 1e-9 then ordered = false end end
check(ordered, "results are ordered best-first")
check(type(hits[1].snippet) == "string" and hits[1].snippet ~= "", "hits carry a snippet")

-- A second query lands in the right place too. (Top-3 membership rather than
-- #1: this test file itself mentions these words, so it competes on bm25.)
local t = bog.store.code_search("register_fallback adapt tool_not_found", 5)
check(top_paths(t, 3)["lua/tools.lua"] ~= nil,
  "'register_fallback' ranks lua/tools.lua in the top 3")

-- Incremental: nothing changed, so a plain reindex re-indexes nothing.
local r2 = bog.store.code_reindex({})
check(r2.indexed == 0, "an incremental reindex with no edits re-indexes nothing (" .. r2.indexed .. ")")
check(r2.skipped > 0, "...and skips the unchanged files")

-- A word-less query is empty, not an error.
check(#bog.store.code_search("", 5) == 0, "an empty query returns no rows")

-- ---- the tool (native tier) ------------------------------------------------
-- No llm-station here, so code_search falls to the native bm25 index. (The grep
-- tier needs the scheduler/bash and is exercised live, not here.)
local out = bog.tools.run("code_search", { query = "whisper voice", limit = 5 })
check(type(out) == "string" and out:find("lvoice", 1, true) ~= nil,
  "the code_search tool returns native bm25 results naming the right file")
check(out:find("native bm25", 1, true) ~= nil, "the tool labels its backend")
-- Contract: an empty query is a validation error, not a crash.
local bad = bog.tools.run("code_search", {})
check(bad:find("^Tool error: %[validation_error%]") ~= nil, "code_search requires a query")
-- The chain is introspectable.
check(type(bog.tools.registry["code_search"].fallback_chain) == "table",
  "code_search advertises its fallback chain")

-- ---- report ----------------------------------------------------------------
if fails == 0 then
  io.write("ok  codesearch: all assertions passed\n")
else
  io.write(string.format("FAILED: %d assertion(s)\n", fails))
  os.exit(1)
end
