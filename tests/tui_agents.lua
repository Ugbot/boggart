-- tests/tui_agents.lua -- the agents-pane renderer, exercised with no terminal.
--
-- tui/agents.lua is pure (snapshot -> styled runs), so every branch is checkable
-- here: run with `boggart --eval tests/tui_agents.lua`. No tty, no model call.
-- The assertions probe the run SHAPE directly -- field colours, header count,
-- width clamping, the "+n more" overflow, the empty case -- and confirm that
-- concatenating a row's run texts reproduces that row's plain text.
local A = require("tui.agents")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end

-- Palette echoed from the module so the assertions name real hexes.
local TEXT, DIM, GOOD, AMBER, FILE = "97979c", "525257", "7fb77e", "ffa94d", "93ddfa"

-- ---- run/line helpers ------------------------------------------------------
-- A line's plain text is its run texts concatenated (Contract B).
local function linetext(line)
  local t = {}
  for _, r in ipairs(line) do t[#t + 1] = r.text end
  return table.concat(t)
end
-- Display width of a line == codepoints of its plain text.
local function linewidth(line)
  local s = linetext(line)
  return (utf8 and utf8.len(s)) or #s
end
-- The first run on `line` whose text contains `sub`.
local function run_with(line, sub)
  for _, r in ipairs(line) do if r.text:find(sub, 1, true) then return r end end
  return nil
end
-- The first run whose text is EXACTLY `t` (a label like "runner" contains the
-- status "run", so field probes that must not collide match exactly).
local function run_eq(line, t)
  for _, r in ipairs(line) do if r.text == t then return r end end
  return nil
end

-- ---- header counts running agents ------------------------------------------
do
  local list = {
    { id = 1, label = "alpha", status = "run" },
    { id = 2, label = "beta",  status = "wait" },
    { id = 3, label = "gamma", status = "run" },
    { id = 4, label = "delta", status = "done" },
  }
  local lines = A.runs(list, { width = 60, height = 10 })
  local head = lines[1]
  ok(linetext(head):find("AGENTS", 1, true) ~= nil, "header: says AGENTS")
  ok(linetext(head):find("2 running", 1, true) ~= nil, "header: counts the 2 running agents")
  -- Header is bold + accent, and (optionally) banded -- assert the emphasis.
  ok(run_with(head, "AGENTS").attr and run_with(head, "AGENTS").attr.bold,
    "header: bold")
  ok(run_with(head, "AGENTS").fg == "e1e1e6", "header: accent colour")
end

-- ---- status token gets the right colour ------------------------------------
do
  local list = {
    { id = 7,  label = "runner",  status = "run",  elapsed = 83, note = "compiling" },
    { id = 8,  label = "waiter",  status = "wait", elapsed = 5 },
    { id = 9,  label = "doner",   status = "done", elapsed = 600 },
    { id = 10, label = "idler",   status = "idle" },
  }
  local lines = A.runs(list, { width = 80, height = 10 })
  -- lines[1] is the header; agents follow in list order.
  ok(run_eq(lines[2], "run").fg == GOOD,   "status: run  -> good/green")
  ok(run_eq(lines[3], "wait").fg == AMBER, "status: wait -> amber")
  ok(run_eq(lines[4], "done").fg == DIM,   "status: done -> dim")
  ok(run_eq(lines[5], "idle").fg == DIM,   "status: idle -> dim")

  -- Fields: label is the text colour; elapsed 83s renders "1:23", dim.
  ok(run_with(lines[2], "runner").fg == TEXT, "label: uses the text colour")
  ok(linetext(lines[2]):find("1:23", 1, true) ~= nil, "elapsed: 83s -> 1:23")
  ok(run_with(lines[2], "1:23").fg == DIM, "elapsed: dim")
  ok(run_with(lines[3], "0:05") ~= nil, "elapsed: 5s -> 0:05 (zero-padded)")
  ok(run_with(lines[4], "10:00") ~= nil, "elapsed: 600s -> 10:00")

  -- A note that looks like a path gets the file colour; plain notes stay dim.
  local plines = A.runs({ { id = 1, label = "p", status = "run", note = "src/foo.lua" } },
    { width = 80, height = 10 })
  ok(run_with(plines[2], "src/foo.lua").fg == FILE, "note: a path gets the file colour")
  local nlines = A.runs({ { id = 1, label = "p", status = "run", note = "thinking" } },
    { width = 80, height = 10 })
  ok(run_with(nlines[2], "thinking").fg == DIM, "note: plain prose stays dim")

  -- nil elapsed contributes no time field.
  ok(linetext(lines[5]):find(":", 1, true) == nil, "elapsed: nil -> no time shown")
end

-- ---- long label / note is truncated to width -------------------------------
do
  local width = 24
  local list = {
    { id = 1, label = string.rep("x", 100), status = "run", note = string.rep("y", 100) },
  }
  local lines = A.runs(list, { width = width, height = 10 })
  for i, line in ipairs(lines) do
    ok(linewidth(line) <= width, "truncate: line " .. i .. " within width (" .. linewidth(line) .. " <= " .. width .. ")")
  end
  ok(linetext(lines[2]):find("...", 1, true) ~= nil, "truncate: cut row ends with an elision")
end

-- ---- more agents than height -> a "+N more" row ----------------------------
do
  local list = {}
  for i = 1, 10 do list[i] = { id = i, label = "agent" .. i, status = "idle" } end
  local height = 4           -- header + 2 agents + "+N more" = 4 rows
  local lines = A.runs(list, { width = 40, height = height })
  ok(#lines == height, "overflow: rows are capped to height (" .. #lines .. ")")
  local last = lines[#lines]
  -- 10 agents, 2 shown individually -> 8 folded into the overflow row.
  ok(linetext(last):find("+8 more", 1, true) ~= nil, "overflow: last row is '+8 more'")
  ok(run_with(last, "more").fg == DIM, "overflow: '+N more' is dim")
end

-- ---- the empty list is handled ---------------------------------------------
do
  local lines = A.runs({}, { width = 40, height = 10 })
  ok(#lines == 1, "empty: a single row")
  ok(linetext(lines[1]) == "no agents", "empty: says 'no agents'")
  ok(lines[1][1].fg == DIM, "empty: dim")
  -- Defensive: nil list behaves like an empty one.
  ok(#A.runs(nil, { width = 40, height = 10 }) == 1, "empty: nil list is also handled")
end

-- ---- run-text concatenation reproduces each row's plain text ---------------
do
  local list = {
    { id = 42, label = "worker", status = "run", elapsed = 90, note = "note here" },
    { id = 43, label = "peer",   status = "wait" },
  }
  local lines = A.runs(list, { width = 80, height = 10 })
  -- The documented format, rebuilt independently, must equal the row's runs.
  local want = "#42 worker  run  1:30  note here"
  ok(linetext(lines[2]) == want, "concat: row plain text matches the field format")
  -- And every visible cell lives in exactly one run: no gaps, no overlap.
  local total = 0
  for _, r in ipairs(lines[2]) do total = total + ((utf8 and utf8.len(r.text)) or #r.text) end
  ok(total == linewidth(lines[2]), "concat: run widths sum to the line width")
end

-- ---- report ----------------------------------------------------------------
io.write(string.format("\ntui_agents: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
