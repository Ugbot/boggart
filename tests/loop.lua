-- tests/loop.lua -- the loop supervisor (the `loop` tool's engine), exercised
-- with an injectable iterate() so every escape hatch is testable with no model
-- and no tty. Run with `boggart --eval tests/loop.lua`.
local L = require("loop")
local G = require("goal")

local fails = 0
local function check(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end

-- iterate() stubs. Signature: (prompt, sess) -> ok:bool, text:string
local function ok_iter(sessions)
  return function(_, sess) if sessions then sessions[#sessions + 1] = sess end; return true, "did it" end
end
local function fail_iter() return function() return false, "boom" end end
local function done_on(n) local c = 0
  return function() c = c + 1; return true, c >= n and ("done " .. G.SENTINEL) or "working" end
end

-- ---- times cap: no `until`, never done -> runs exactly N -------------------
do
  local r = L.run{ task = "x", times = 4, iterate = ok_iter() }
  check(r.iterations == 4 and r.met == false, "times cap: runs exactly N (got " .. r.iterations .. ")")
  check(r.times == 4, "reports the cap")
end

-- ---- until already satisfied -> zero iterations ---------------------------
do
  local r = L.run{ task = "x", times = 5, until_ = function() return true, "pre" end, iterate = ok_iter() }
  check(r.iterations == 0 and r.met == true, "until pre-satisfied: 0 iterations, met")
end

-- ---- until triggers after two iterations ----------------------------------
do
  local n = 0
  local r = L.run{ task = "x", times = 9, iterate = ok_iter(),
                   until_ = function() n = n + 1; return n > 2, "cond" end }
  -- checked once before, then after each iteration: false, run, false, run, true
  check(r.iterations == 2 and r.met == true, "until mid-loop: stops when it passes (got " .. r.iterations .. ")")
end

-- ---- stop_on_error (default): stops at the first failure ------------------
do
  local r = L.run{ task = "x", times = 5, iterate = fail_iter() }
  check(r.iterations == 1 and r.failures == 1 and r.met == false, "stop_on_error default: first failure ends it")
end

-- ---- max_failures = K: tolerate K, bail on the (K+1)th --------------------
do
  local r = L.run{ task = "x", times = 9, iterate = fail_iter(), max_failures = 2 }
  check(r.iterations == 3 and r.failures == 3, "max_failures=2: bails after the 3rd failure (got " .. r.iterations .. ")")
end

-- ---- stop_on_error = false: run all N despite failures --------------------
do
  local r = L.run{ task = "x", times = 3, iterate = fail_iter(), stop_on_error = false }
  check(r.iterations == 3 and r.failures == 3, "stop_on_error=false: runs all N despite failures")
end

-- ---- model-judged: the agent ends the loop with a done sentinel -----------
do
  local r = L.run{ task = "x", times = 6, iterate = done_on(3) }
  check(r.iterations == 3 and r.met == true, "sentinel: stops when the agent reports done (got " .. r.iterations .. ")")
end

-- ---- fresh vs continuing session ------------------------------------------
do
  local s1 = {}; L.run{ task = "x", times = 3, fresh = true,  iterate = ok_iter(s1) }
  check(#s1 == 3 and s1[1] ~= s1[2] and s1[2] ~= s1[3], "fresh=true: a distinct sub-session each iteration")
  local s2 = {}; L.run{ task = "x", times = 3, fresh = false, iterate = ok_iter(s2) }
  check(#s2 == 3 and s2[1] == s2[2] and s2[2] == s2[3], "fresh=false: one shared sub-session across iterations")
end

-- ---- the hard ceiling no `times` can exceed -------------------------------
do
  local r = L.run{ task = "x", times = 99999, iterate = fail_iter(), stop_on_error = false }
  check(r.iterations == L.HARD_MAX, "times is capped at HARD_MAX (got " .. r.iterations .. ")")
end

io.write(fails == 0 and "loop: all passed\n" or ("loop: " .. fails .. " FAILED\n"))
os.exit(fails == 0 and 0 or 1)
