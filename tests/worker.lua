-- worker.lua -- real OS worker threads (src/lworker.c).
--
-- Each worker is a genuine thread with its own uv_loop_t and its own
-- boggart-shaped lua_State (counting allocator, boggart_open_libs, boot in
-- "worker" mode). Nothing Lua crosses the boundary: source crosses as text,
-- data as strings and numbers over two semaphore-guarded SPSC rings in the
-- jwriter.c idiom. These tests are the check that the handoff, the lifetime
-- (spawn/stop/join with no leak) and the deny list are right.
--
-- Discipline: no test here may create a non-terminating worker. A worker that
-- spins is unreclaimable by design (stop is cooperative), so every worker
-- source either terminates on its own or exits on stop/recv-timeout.
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

-- ---- single worker: spawn, exchange messages both ways, join cleanly ----
local h = worker.spawn([[
  local sum = 0
  while true do
    local v = worker.recv(5000)
    if v == nil then break end
    if v == "done" then worker.post(sum); break end
    sum = sum + v
  end
  return "bye"
]])
ok(h ~= nil, "spawn returned a handle")
eq(worker.status(h), "running", "worker reports running")
for i = 1, 10 do ok(worker.post(h, i) == true, i == 1 and "post accepts a number" or true) end
worker.post(h, "done")
eq(worker.recv(h, 10000), 55, "worker computed on its own thread and posted back")
local jok, res = worker.join(h)
eq(jok, true, "join reports the source completed")
eq(res, "bye", "join returns the source's return value")
eq(worker.status(h), "joined", "status is joined after join")

-- ---- the worker really is a boggart, on its own loop, with its own memory --
local h2 = worker.spawn([[
  -- bog exists and boot ran in worker mode; uv is this state's OWN loop.
  local uv = require("uv")
  local ticked = false
  local t = uv.new_timer()
  t:start(1, 0, function() ticked = true; t:close() end)
  uv.run()
  local live, peak = sys.membytes()      -- per-worker counter, not the global
  local fine = bog ~= nil and bog.mode == "worker" and json ~= nil
    and ticked and live > 0 and peak >= live
  return fine and "boggart-ok" or "not-a-boggart"
]])
local ok2, res2 = worker.join(h2)
eq(ok2, true, "boggart-shaped worker ran")
eq(res2, "boggart-ok", "worker has bog, json, its own uv loop and its own membytes")

-- ---- opts.arg crosses as a value; tables cross as json text ----
local h3 = worker.spawn([[ return worker.arg * 2 ]], { arg = 21 })
local ok3, res3 = worker.join(h3)
eq(ok3, true, "arg worker ran")
eq(res3, 42, "opts.arg arrived as a number")

local h4 = worker.spawn([[
  local t = json.decode(worker.arg)     -- tables are serialized, never shared
  t.n = t.n + 1
  return json.encode(t)
]], { arg = json.encode({ n = 41, tag = "x" }) })
local ok4, res4 = worker.join(h4)
eq(ok4, true, "json worker ran")
local t4 = json.decode(res4)
eq(t4.n, 42, "table crossed the boundary as json and came back changed")
eq(t4.tag, "x", "the rest of the table survived the round trip")

-- ---- a Lua value cannot cross: post rejects tables with an explanation ----
local h5 = worker.spawn([[ return worker.recv(2000) or "nothing" ]])
local pok, perr = pcall(worker.post, h5, { a = 1 })
ok(not pok, "posting a table is an error, not a silent serialization")
ok(tostring(perr):find("json"), "the error says how to do it instead")
worker.post(h5, "real")
local ok5, res5 = worker.join(h5)
eq(res5, "real", "the worker still got the legitimate message")

-- ---- errors carry a traceback back across the boundary ----
local h6 = worker.spawn([[ error("kaboom in the worker") ]])
eq(select(2, worker.recv(h6, 10000)), "exit", "recv reports exit on a dead worker")
eq(worker.status(h6), "error", "status is error before join")
local ok6, res6 = worker.join(h6)
eq(ok6, false, "join reports failure")
ok(tostring(res6):find("kaboom in the worker"), "the error message crossed")
ok(tostring(res6):find("traceback"), "with a traceback")

-- ---- stop wakes a blocked recv; the worker exits cooperatively ----
local h7 = worker.spawn([[
  local v, why = worker.recv()          -- no timeout: blocks until stop
  return why or "got " .. tostring(v)
]])
eq(worker.status(h7), "running", "blocked worker is running")
worker.stop(h7)
local ok7, res7 = worker.join(h7)
eq(ok7, true, "stopped worker exited by itself")
eq(res7, "stop", "recv returned nil,'stop'")

-- ---- the deny list: main-thread-owned capabilities error with a sentence ----
-- http is NOT here: curl's multi is per-loop now (lhttp.c keys a CURLM off each
-- state's luv loop), so a worker's http rides its OWN loop -- see below.
local h8 = worker.spawn([[
  local errs = {}
  for name, fn in pairs({
    swarm = function() return swarm.send(1, 2, "x") end,
    mcp   = function() return mcp.connect("nope") end,
    spawn = function() return worker.spawn("return 1") end,
    auth  = function() return auth.set("api_key", "k") end,
  }) do
    local okc, e = pcall(fn)
    if not okc and tostring(e):find("main thread") then errs[#errs + 1] = name end
  end
  table.sort(errs)
  return table.concat(errs, ",")
]])
local ok8, res8 = worker.join(h8)
eq(ok8, true, "deny-list worker ran")
eq(res8, "auth,mcp,spawn,swarm", "swarm/mcp/nested-spawn/auth.set all denied")

-- ---- http IS available in a worker: N threads, N loops, N curl multis --------
-- http.pump(0) with no request in flight drives the worker's own loop and
-- reports 0 running -- proving http is callable (not denied) and bound to the
-- worker's loop, not the main thread's. (A live request needs the network; the
-- point here is the capability and its per-loop ownership.)
local h8b = worker.spawn([[
  local running = http.pump(0)
  return string.format("%s,%d", type(http.begin), running)
]])
local ok8b, res8b = worker.join(h8b)
eq(ok8b, true, "worker-http worker ran")
eq(res8b, "function,0", "http.begin/pump work in a worker on its own loop")

-- ---- a worker may open its OWN db connection (THREADSAFE=2 discipline) ----
local h9 = worker.spawn([[
  local d = db.open(worker.arg)
  d:exec("DROP TABLE IF EXISTS wk")     -- the suite HOME persists across runs
  d:exec("CREATE TABLE wk(x INTEGER)")
  d:exec("INSERT INTO wk VALUES(7)")
  local r = d:query("SELECT SUM(x) AS s FROM wk")
  d:close()
  return r[1].s or r[1][1]
]], { arg = bog.userdir .. "/worker_test.db" })
local ok9, res9 = worker.join(h9)
eq(ok9, true, "worker opened its own SQLite connection")
eq(res9, 7, "and used it")

-- ---- on_message: worker posts land as events on the MAIN loop ----
local uv = require("uv")
local got = {}
local h10 = worker.spawn([[
  worker.onmessage(function(v)
    if v == "quit" then worker.post("bye") else worker.post(v * 10) end
  end)
  -- source returns; the worker sits in its uv loop dispatching until stop
]], { on_message = function(v) got[#got + 1] = v end })
worker.post(h10, 1)
worker.post(h10, 2)
worker.post(h10, 3)
local deadline = uv.new_timer()
local poll = uv.new_timer()
deadline:start(5000, 0, function() uv.stop() end)
poll:start(5, 5, function() if #got >= 3 then uv.stop() end end)
uv.run()
deadline:close(); poll:close()
uv.run("nowait")
eq(#got, 3, "three messages arrived via the main loop")
eq(got[1] + got[2] + got[3], 60, "each transformed on the worker thread")
worker.stop(h10)
local ok10 = worker.join(h10)
eq(ok10, true, "onmessage worker stopped and joined")

-- ---- many workers: 50 threads, real parallel compute, all joined ----
local t0 = uv.hrtime()
local hs = {}
for i = 1, 50 do
  hs[i] = worker.spawn([[
    local n, acc = worker.arg, 0
    for k = 1, 200000 do acc = (acc + n * k) % 1000003 end
    return n * 1000000 + (acc % 7)      -- n encoded so each result is distinct
  ]], { arg = i })
end
local all, distinct = true, {}
for i = 1, 50 do
  local okn, r = worker.join(hs[i])
  if not okn or math.floor(r / 1000000) ~= i then all = false end
  distinct[r] = true
end
local n_distinct = 0
for _ in pairs(distinct) do n_distinct = n_distinct + 1 end
local ms = (uv.hrtime() - t0) / 1e6
ok(all, "all 50 workers computed the right thing")
eq(n_distinct, 50, "50 distinct results")
io.write(string.format("  (50 workers spawned, computed and joined in %.0f ms)\n", ms))

-- ---- churn: spawn-and-join 100 workers; main-state memory must not climb ----
-- ---- safepoint kill: a pure-Lua spin IS preemptible (Phase 2 keystone) -----
-- The exact case lworker.c's v1 comment called out: a worker that never calls
-- recv()/stopped(). Before this, join() on it would hang forever; now kill()
-- unwinds it at the next Lua safepoint. If the hook regressed, this test hangs
-- (and ctest times it out) rather than passing wrongly -- that is the assertion.
do
  local w = worker.spawn([[ local x = 0; while true do x = x + 1 end; return x ]])
  worker.kill(w)                       -- out-of-band, from the main thread
  local okc, res = worker.join(w)      -- returns because the safepoint fired
  ok(okc == false, "killed spin: join reports the source did not complete")
  ok(type(res) == "string" and res:find("killed", 1, true) ~= nil,
     "killed spin: the result is the safepoint-kill error (got: " .. tostring(res):sub(1, 40) .. ")")
  ok(worker.status(w) == "joined", "killed spin: the worker is joined, not wedged")
end

-- A worker that finishes on its own is unaffected by a late kill().
do
  local w = worker.spawn([[ return 21 * 2 ]])
  local okc, res = worker.join(w)
  ok(okc == true and res == 42, "kill is opt-in: a normal worker still returns its result")
  worker.kill(w)                       -- kill after join is a harmless no-op
  ok(worker.status(w) == "joined", "kill after join does not disturb a joined worker")
end

-- kill() is denied inside a worker (like stop/spawn/join): one level only.
do
  local w = worker.spawn([[ return type(worker.kill) == "function" and pcall(worker.kill) and "ran" or "denied" ]])
  local _, res = worker.join(w)
  ok(res == "denied", "worker.kill is denied inside a worker")
end

-- ---- lifecycle events on the fabric bus (observe the pool) -----------------
-- spawn/exit/kill are emitted from the main-side worker code, so they dispatch
-- synchronously to a bus subscriber on this state -- no loop pump needed.
do
  local seen = {}
  local id = bus.subscribe("worker:*", function(t, _) seen[#seen + 1] = t end)
  local function saw(x) for _, t in ipairs(seen) do if t == x then return true end end return false end

  local w = worker.spawn([[ return 1 ]])
  ok(saw("worker:spawned"), "lifecycle: worker:spawned reaches the bus at spawn")
  worker.join(w)
  ok(saw("worker:exited"), "lifecycle: worker:exited reaches the bus at join")

  seen = {}
  local k = worker.spawn([[ while true do end ]])
  worker.kill(k)
  ok(saw("worker:killed"), "lifecycle: worker:killed reaches the bus at kill")
  worker.join(k)
  bus.unsubscribe(id)
end

-- Worker states use their own allocator counters, so a leak of worker states
-- or rings would show in RSS, not here; membytes guards the main state and
-- the handle bookkeeping. The churn itself is the assertion that 100 full
-- lifecycles (state + loop + thread) come and go without wedging.
collectgarbage("collect"); collectgarbage("collect")
local live0 = sys.membytes()
for i = 1, 100 do
  local w = worker.spawn([[ return worker.arg + 1 ]], { arg = i })
  local okc, r = worker.join(w)
  if not okc or r ~= i + 1 then ok(false, "churn iteration " .. i) end
end
collectgarbage("collect"); collectgarbage("collect")
local live1 = sys.membytes()
ok(live1 < live0 + 256 * 1024,
  string.format("main state stable across 100 spawn/join cycles (%d -> %d bytes)", live0, live1))

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
return failed == 0 and 0 or 1
