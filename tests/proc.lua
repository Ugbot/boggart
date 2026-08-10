-- proc.lua -- subprocesses on the libuv loop (lua/proc.lua), and the scheduler
-- integration that stops one agent's shell command freezing the rest.
--
-- The headline test is the last one: with the old blocking sys.exec, a peer
-- actor got exactly zero resumes while another actor sat in a shell command.
local proc = require("proc")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

bog.userdir = os.tmpname() .. "_boggart_proc"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()

-- ---- basics ----
local r = proc.run("echo hello", 10)
eq(r.code, 0, "exit code 0")
ok(r.out:find("hello", 1, true) ~= nil, "stdout captured")
ok(not r.timed_out, "not marked timed out")
ok(not r.truncated, "not marked truncated")

eq(proc.run("exit 3", 10).code, 3, "non-zero exit code propagates")

-- stderr folds into the same buffer, as sys.exec did
local e = proc.run("echo to-stderr 1>&2", 10)
ok(e.out:find("to-stderr", 1, true) ~= nil, "stderr is captured too")
eq(e.code, 0, "stderr does not imply failure")

-- interleaved streams both arrive
local both = proc.run("echo one; echo two 1>&2; echo three", 10)
for _, want in ipairs({ "one", "two", "three" }) do
  ok(both.out:find(want, 1, true) ~= nil, "interleaved output contains " .. want)
end

-- ---- larger output arrives intact (multiple read callbacks) ----
local big = proc.run("for i in $(seq 1 2000); do echo line-$i; done", 30)
eq(big.code, 0, "big output command succeeded")
local n = select(2, big.out:gsub("\n", ""))
eq(n, 2000, "all 2000 lines captured across read callbacks")
ok(big.out:find("line-2000", 1, true) ~= nil, "last line present")

-- ---- a signal death reports 128 + signum, matching the old contract ----
local killed = proc.run("kill -TERM $$", 10)
ok(killed.code >= 128, "signal death reported as 128+signum (" .. tostring(killed.code) .. ")")

-- ---- timeout kills the child and says so ----
local t0 = os.time()
local slow = proc.run("sleep 10", 1)
local took = os.time() - t0
ok(slow.timed_out, "timeout flagged")
ok(took < 6, "timeout actually fired early (took " .. took .. "s)")

-- a timeout must take the whole process tree, not just the direct child:
-- the shell's own child (`sleep`) has to die too, or we leak processes.
local marker = bog.userdir .. "/orphan_marker"
proc.run(string.format("(sleep 3; echo alive > %q) & sleep 10", marker), 1)
sys.exec("sleep 4", 10) -- outlive the orphan's write, if it survived
eq(sys.stat(marker), nil, "timeout killed the grandchild too (no orphan)")

-- ---- a failed spawn is reported, not raised ----
local bad = proc.run("this-command-definitely-does-not-exist-xyz", 10)
ok(bad.code ~= 0, "unknown command yields non-zero exit")

-- ---- handle-level API ----
local h = proc.start("sleep 0.3; echo late", 10)
local polls, deadline = 0, os.time() + 15
-- Bound by wall clock, not by iteration count: poll() never blocks, so a
-- fixed iteration cap can easily expire before a 0.3s child has finished.
while h:poll() == "running" and os.time() < deadline do polls = polls + 1 end
ok(polls > 0, "poll() reported running before completion")
eq(h:poll(), "done", "poll() eventually reports done")
local hr = h:result()
eq(hr.code, 0, "handle result exit code")
ok(hr.out:find("late", 1, true) ~= nil, "handle result output")

-- ---- the point of the exercise: no scheduler stall -------------------------
-- One actor sits in a shell command; a peer actor is counted only while that
-- command is in flight. Under the old blocking sys.exec this is exactly 0.
do
  local sched = require("sched")
  local function trial(runner)
    local ticks, inflight = 0, false
    sched.actors, sched.by_id = {}, {}
    sched.add(1, coroutine.create(function() inflight = true; runner(); inflight = false end))
    sched.add(2, coroutine.create(function()
      local t0 = os.time()
      while os.time() - t0 < 3 do
        if inflight then ticks = ticks + 1 end
        coroutine.yield()
      end
    end))
    sched.run()
    return ticks
  end

  local blocking = trial(function() sys.exec("sleep 1", 30) end)
  local yielding = trial(function() proc.run("sleep 1", 30) end)
  eq(blocking, 0, "sys.exec starves every other actor (the bug)")
  ok(yielding > 500, "proc.run keeps peers running (" .. yielding .. " resumes)")
  ok(yielding > blocking * 100 or blocking == 0, "non-blocking path is decisively better")
end

if bog.db then bog.db:close() end
sys.rmtree(bog.userdir)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
return failed == 0 and 0 or 1
