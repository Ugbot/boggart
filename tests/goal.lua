-- tests/goal.lua -- the goal supervisor, exercised with a mock turn runner.
--
-- goal.run takes an injectable `runner`, so the loop, the budget cap and every
-- deterministic check are testable with no model and no tty. Run with
-- `boggart --eval tests/goal.lua`.
local G = require("goal")

local fails = 0
local function check(ok, msg)
  if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end
end

-- A runner that emits the sentinel (via the stream sink) on its Nth call.
local function sentinel_on(n)
  local c = 0
  return function(_, sink)
    c = c + 1
    sink(c >= n and ("all done " .. G.SENTINEL .. "\n") or "still working\n")
  end
end

-- A runner that never signals completion.
local function never()
  return function(_, sink) sink("chipping away\n") end
end

-- ---- model-judged: stops the turn the sentinel appears --------------------
do
  local r = G.run{ task = "do the thing", runner = sentinel_on(3), max_turns = 8 }
  check(r.met == true, "model-judged: goal met when sentinel appears")
  check(r.turns == 3, "model-judged: stopped on the sentinel turn (got " .. r.turns .. ")")
end

-- ---- budget cap: never signals -> stops at max_turns, met=false ------------
do
  local r = G.run{ task = "impossible", runner = never(), max_turns = 4 }
  check(r.met == false, "budget: unmet goal reports met=false")
  check(r.turns == 4, "budget: ran exactly max_turns (got " .. r.turns .. ")")
  check(r.budget == 4, "budget: reports its cap")
end

-- A goal is never unbounded: an absurd request is still clamped.
do
  local r = G.run{ task = "x", runner = never(), max_turns = 1 }
  check(r.turns == 1, "budget: max_turns=1 runs once")
end

-- ---- function check: stops when the predicate flips ------------------------
do
  local calls = 0
  local r = G.run{
    task = "count to two",
    runner = function() calls = calls + 1 end,   -- a turn that does "work"
    done = function() return calls >= 2, "calls=" .. calls end,
    max_turns = 9,
  }
  check(r.met == true, "function check: met when predicate passes")
  check(r.turns == 2, "function check: stopped as soon as it passed (got " .. r.turns .. ")")
end

-- ---- pre-satisfied: an already-true check spends zero turns -----------------
do
  local ran = false
  local r = G.run{
    task = "already done",
    runner = function() ran = true end,
    done = function() return true, "already true" end,
  }
  check(r.met == true and r.turns == 0, "pre-satisfied: met with zero turns")
  check(ran == false, "pre-satisfied: the runner was never called")
end

-- ---- exists check: a turn that creates the file satisfies it ---------------
do
  local path = (os.getenv("HOME") or ".") .. "/goal-exists-probe"
  os.remove(path)
  local turn = 0
  local r = G.run{
    task = "produce the artifact",
    done = { exists = path },
    max_turns = 5,
    runner = function()
      turn = turn + 1
      if turn == 2 then local f = io.open(path, "w"); if f then f:write("x"); f:close() end end
    end,
  }
  check(r.met == true, "exists check: met once the file appears")
  check(r.turns == 2, "exists check: stopped the turn the file was created (got " .. r.turns .. ")")
  os.remove(path)
end

-- ---- shell check: exit 0 means done ----------------------------------------
do
  -- Already-true: `true` exits 0, so zero turns.
  local r0 = G.run{ task = "noop", done = { shell = "true" }, runner = never() }
  check(r0.met == true and r0.turns == 0, "shell check: an already-passing command spends no turns")

  -- Becomes true when a turn creates the sentinel file the command tests for.
  local path = (os.getenv("HOME") or ".") .. "/goal-shell-probe"
  os.remove(path)
  local turn = 0
  local r = G.run{
    task = "make the check pass",
    done = { shell = "test -f " .. path },
    max_turns = 5,
    runner = function()
      turn = turn + 1
      if turn == 1 then local f = io.open(path, "w"); if f then f:close() end end
    end,
  }
  check(r.met == true and r.turns == 1, "shell check: met after the turn that satisfies it")
  os.remove(path)

  -- A command that never passes hits the budget with useful detail.
  local rf = G.run{ task = "cannot", done = { shell = "false" }, runner = never(), max_turns = 2 }
  check(rf.met == false and rf.turns == 2, "shell check: a failing command runs to the cap")
  check(type(rf.detail) == "string" and rf.detail:find("exited"), "shell check: detail explains the failure")
end

-- ---- guardrail: a task is required -----------------------------------------
do
  local ok = pcall(G.run, { runner = never() })
  check(ok == false, "guardrail: run without a task errors")
end

-- ---- ReAct: same supervisor, Thought → Action → Observation prompts --------
do
  local seen = {}
  local r = G.react{
    task = "ship it",
    max_turns = 2,
    done = function() return false, "still blocked: no tests" end,
    runner = function(text) seen[#seen + 1] = text end,
  }
  check(r.met == false and r.turns == 2, "react: unmet check runs to the budget")
  check(type(seen[1]) == "string" and seen[1]:find("ReAct", 1, true),
    "react: first prompt names the loop")
  check(seen[1]:find("Thought", 1, true) and seen[1]:find("Action", 1, true),
    "react: first prompt asks for Thought then Action")
  check(type(seen[2]) == "string" and seen[2]:find("Observation", 1, true),
    "react: continuation labels the check as Observation")
  check(seen[2]:find("still blocked", 1, true),
    "react: observation carries the check detail")
end

do
  local seen
  G.run{ task = "x", max_turns = 1, runner = function(text) seen = text end }
  check(type(seen) == "string" and not seen:find("ReAct", 1, true),
    "until: default prompts are not ReAct-shaped")
end

if fails == 0 then
  io.write("ok  goal: all assertions passed\n")
else
  io.write(string.format("FAILED: %d assertion(s)\n", fails))
  os.exit(1)
end
