-- tests/loop.lua -- the loop core: a functional fold over a generator, exercised
-- with an injectable iterate() so every generator, effect, escape hatch, the
-- verify+retry, a custom reduce, and the parallel worker pool are testable with
-- no model. Run with `boggart --eval tests/loop.lua`.
local L = require("loop")
local G = require("goal")

local fails = 0
local function check(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end

-- iterate stub: (item, idx, sess) -> ok, result
local function ok_iter(seen)
  return function(item, idx, sess)
    if seen then seen[#seen + 1] = { item = item, idx = idx, sess = sess } end
    return true, "r" .. tostring(item)
  end
end
local function fail_iter() return function() return false, "boom" end end

-- ---- generators -----------------------------------------------------------
do local r = L.run{ times = 4, task = "t", iterate = ok_iter() }
   check(r.iterations == 4 and r.met == false, "count: runs N (got " .. r.iterations .. ")") end

do local seen = {}; local r = L.run{ over = { "a", "b", "c" }, task = "t", iterate = ok_iter(seen) }
   check(r.iterations == 3, "list: iterates the items")
   check(seen[1].item == "a" and seen[3].item == "c", "list: each item is passed to the effect")
   check(#r.acc == 3 and r.acc[1] == "ra", "acc: default reduce collects results") end

do local q = { "x", "y" }; local i = 0
   local r = L.run{ source = function() i = i + 1; return q[i] end, task = "t", iterate = ok_iter() }
   check(r.iterations == 2 and r.detail == "source exhausted", "source: drains until exhausted (got " .. r.iterations .. ")") end

do local i = 0
   local r = L.run{ source = function() i = i + 1; return "n" .. i end, max = 3, task = "t", iterate = ok_iter() }
   check(r.iterations == 3, "source: bounded by max (got " .. r.iterations .. ")") end

-- ---- until ----------------------------------------------------------------
do local r = L.run{ times = 5, task = "t", iterate = ok_iter(), until_ = function() return true, "pre" end }
   check(r.iterations == 0 and r.met == true, "until pre-satisfied: 0 iterations") end

do local n = 0
   local r = L.run{ times = 9, task = "t", iterate = ok_iter(), until_ = function() n = n + 1; return n > 2, "c" end }
   check(r.iterations == 2 and r.met == true, "until mid-loop: stops when it passes (got " .. r.iterations .. ")") end

-- ---- error hatches --------------------------------------------------------
do local r = L.run{ times = 5, task = "t", iterate = fail_iter() }
   check(r.iterations == 1 and r.failures == 1, "stop_on_error default: first failure ends it") end
do local r = L.run{ times = 9, task = "t", iterate = fail_iter(), max_failures = 2 }
   check(r.iterations == 3 and r.failures == 3, "max_failures=2: bails on the 3rd failure (got " .. r.iterations .. ")") end
do local r = L.run{ times = 3, task = "t", iterate = fail_iter(), stop_on_error = false }
   check(r.iterations == 3 and r.failures == 3, "stop_on_error=false: runs all despite failures") end

-- ---- model-judged sentinel (task + no until) ------------------------------
do local c = 0
   local it = function() c = c + 1; return true, c >= 3 and ("done " .. G.SENTINEL) or "work" end
   local r = L.run{ times = 6, task = "t", iterate = it }
   check(r.iterations == 3 and r.met == true, "sentinel: stops when the agent reports done (got " .. r.iterations .. ")") end

-- ---- fresh vs continuing session ------------------------------------------
do local s1 = {}; L.run{ times = 3, fresh = true,  task = "t", iterate = ok_iter(s1) }
   check(s1[1].sess ~= s1[2].sess and s1[2].sess ~= s1[3].sess, "fresh=true: a distinct sub-session each item")
   local s2 = {}; L.run{ times = 3, fresh = false, task = "t", iterate = ok_iter(s2) }
   check(s2[1].sess == s2[2].sess and s2[2].sess == s2[3].sess, "fresh=false: one shared sub-session") end

-- ---- verify + retry -------------------------------------------------------
do local tries = 0; local it = function() tries = tries + 1; return true, "r" end
   local vc = 0
   local r = L.run{ times = 1, task = "t", iterate = it, verify = function() vc = vc + 1; return vc >= 3 end, max_retries = 3 }
   check(r.iterations == 1 and r.results[1].ok == true and tries == 3,
     "verify+retry: redoes a bad item until it passes (tries=" .. tries .. ")") end
do local it = function() return true, "r" end
   local r = L.run{ times = 2, task = "t", iterate = it, verify = function() return false end, max_retries = 1, stop_on_error = false }
   check(r.iterations == 2 and r.failures == 2, "verify never passes: the item counts as a failure") end

-- ---- custom reduce + init -------------------------------------------------
do local it = function(item) return true, item end   -- item is the index for a count loop
   local r = L.run{ times = 4, task = "t", iterate = it, init = 0,
                    reduce = function(acc, result) return acc + result end }
   check(r.acc == 10, "custom reduce: folds 1+2+3+4 = 10 (got " .. tostring(r.acc) .. ")") end

-- ---- the hard ceiling -----------------------------------------------------
do local r = L.run{ source = function() return "x" end, max = 99999, task = "t", iterate = ok_iter() }
   check(r.iterations == L.HARD_MAX, "HARD_MAX ceiling caps an open source (got " .. r.iterations .. ")") end

-- ---- parallel worker pool (driven on the scheduler) -----------------------
do
  local uv = require "uv"; bog.sched = bog.sched or require "sched"
  bog.sched.actors, bog.sched.by_id = {}, {}
  local r
  local co = coroutine.create(function()
    r = L.run{ over = { 1, 2, 3, 4, 5 }, task = "t", parallel = true, slots = 2,
               iterate = function(item) return true, item end }
  end)
  bog.sched.add(-4242, co)
  local t = os.time()
  while bog.sched.count and bog.sched.count() > 0 do
    bog.sched.resume_ready(); if bog.sched.count() == 0 then break end
    if os.time() - t > 10 then break end
    uv.run("once")
  end
  check(r and r.iterations == 5 and #r.acc == 5, "parallel: all items processed across the pool (got " .. tostring(r and r.iterations) .. ")")
end

io.write(fails == 0 and "loop: all passed\n" or ("loop: " .. fails .. " FAILED\n"))
os.exit(fails == 0 and 0 or 1)
