-- looplag.lua -- event-loop lag metrics (lua/looplag.lua, BOG-22): libuv idle
-- time, the lag probe, and blocks named by what held the loop.
local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local uv = require("uv")
local ll = require("looplag")
ll._reset()
ok(ll.start(), "metrics start")
ok(ll.start(), "start is idempotent")
local function spin(ms) local t = uv.hrtime(); while (uv.hrtime() - t) / 1e6 < ms do end end

-- a scheduled agent that holds the loop is named
local sched = require("sched")
sched.add("blocker-7", coroutine.create(function() spin(120); return end))
sched.run({ should_stop = function() return not sched.alive("blocker-7") end })
local b = ll.recent(5)
local found
for _, x in ipairs(b) do if x.what == "agent blocker-7" then found = x end end
ok(found and found.ms >= 110, "a 120 ms agent step is recorded with the agent's name -- got " .. tostring(found and found.ms))

-- perf.time names arbitrary sites; fast runs are not noted
local before = #ll.recent(64)
ll.time("fast thing", function() return 1 end)
ok(#ll.recent(64) == before, "a fast run is not noted")
local r = ll.time("slow paint", function(x) spin(60); return x * 2 end, 21)
ok(r == 42, "time() returns the function's results")
ok(ll.recent(1)[1].what == "slow paint", "a slow site is noted by name")

-- the probe sees lag when the loop is held, and idle time is measured
local t0 = uv.hrtime()
local timer = uv.new_timer()
uv.timer_start(timer, 10, 0, function() spin(300) end)       -- hold the loop for 300 ms
local done = false
local t2 = uv.new_timer()
uv.timer_start(t2, 800, 0, function() done = true end)
while not done do uv.run("once") end
uv.close(timer); uv.close(t2)
local s = ll.stats()
ok(s.max_lag_ms >= 200, "the lag probe saw the 300 ms hold -- got " .. string.format("%.0f", s.max_lag_ms))
ok(s.busy_pct >= 0 and s.busy_pct <= 100, "busy share is a percentage")
ok(s.rss and s.rss > 0, "resident memory from libuv")
local rep = ll.report()
ok(rep:find("event loop:", 1, true) and rep:find("agent blocker-7", 1, true), "the report names the blockers")
ok(rep:find("resident", 1, true) ~= nil, "and shows memory")

io.write(string.format("looplag: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
