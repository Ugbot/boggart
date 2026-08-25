-- fabric.lua -- the messaging fabric core (src/lbus.c): the pub/sub bus and the
-- named work queues exposed as the global `bus`. Phase 1 of
-- docs/actors-and-bus.md. Run with `boggart --eval tests/fabric.lua`.
--
-- No threads here (Phase 1 is single-state): publish dispatches synchronously to
-- Lua subscribers on this state. We test topic matching, glob patterns, the
-- deferred-unsubscribe-during-dispatch guarantee, and the push/pull FIFO.
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

ok(type(bus) == "table" and type(bus.publish) == "function", "bus global is present")

-- ---- exact-topic delivery --------------------------------------------------
do
  local got = {}
  local id = bus.subscribe("tool:before", function(topic, data) got[#got + 1] = { topic, data } end)
  local n = bus.publish("tool:before", "payload-1")
  eq(n, 1, "publish reports one delivery")
  eq(#got, 1, "exact topic: handler fired once")
  eq(got[1][1], "tool:before", "handler receives the topic")
  eq(got[1][2], "payload-1", "handler receives the payload bytes")
  bus.publish("tool:after", "x")
  eq(#got, 1, "a non-matching topic does not fire the handler")
  bus.unsubscribe(id)
  bus.publish("tool:before", "payload-2")
  eq(#got, 1, "after unsubscribe the handler is silent")
end

-- ---- glob patterns ---------------------------------------------------------
do
  local star, seg = 0, 0
  local a = bus.subscribe("*", function() star = star + 1 end)
  local b = bus.subscribe("agent/*/turn", function() seg = seg + 1 end)
  bus.publish("agent/42/turn", "")
  bus.publish("agent/7/turn", "")
  bus.publish("agent/42/tool", "")   -- matches * but not the segment pattern
  eq(star, 3, "'*' matches every topic")
  eq(seg, 2, "'agent/*/turn' matches the two turn topics only")
  bus.unsubscribe(a); bus.unsubscribe(b)
end

-- ---- has() -----------------------------------------------------------------
do
  ok(bus.has("nobody:listening") == false, "has() is false with no matching subscriber")
  local id = bus.subscribe("swarm:*", function() end)
  ok(bus.has("swarm:actor_done") == true, "has() is true once a pattern matches the topic")
  ok(bus.has("turn:end") == false, "has() stays false for an unrelated topic")
  bus.unsubscribe(id)
  ok(bus.has("swarm:actor_done") == false, "has() false again after unsubscribe")
end

-- ---- multiple subscribers + delivery count ---------------------------------
do
  local c = 0
  local ids = {}
  for i = 1, 3 do ids[i] = bus.subscribe("multi", function() c = c + 1 end) end
  local n = bus.publish("multi", "")
  eq(n, 3, "publish reports all three deliveries")
  eq(c, 3, "every subscriber to a topic fires")
  for _, id in ipairs(ids) do bus.unsubscribe(id) end
end

-- ---- unsubscribe DURING dispatch is honoured, but not mid-fan-out ----------
-- A handler that unsubscribes a *sibling* during dispatch: the sibling was
-- already snapshotted for THIS publish, so it still fires this round, and is
-- gone next round. This is the events.lua guarantee, in C.
do
  local sib_fires = 0
  local sib = bus.subscribe("d", function() sib_fires = sib_fires + 1 end)
  local killer = bus.subscribe("d", function() bus.unsubscribe(sib) end)
  bus.publish("d", "")          -- both snapshotted; sib fires; then sib removed
  bus.publish("d", "")          -- sib is gone now
  eq(sib_fires, 1, "sibling unsubscribed mid-dispatch fires this round, not next")
  bus.unsubscribe(killer)
end

-- ---- a throwing subscriber does not take the publisher down ----------------
do
  local after = 0
  local bad = bus.subscribe("t", function() error("boom") end)
  local good = bus.subscribe("t", function() after = after + 1 end)
  local n = bus.publish("t", "")   -- must not raise
  eq(after, 1, "a good subscriber still fires after a throwing one")
  eq(n, 2, "delivery count includes the throwing subscriber")
  bus.unsubscribe(bad); bus.unsubscribe(good)
end

-- ---- work queues: push / pull / qlen (FIFO) --------------------------------
do
  eq(bus.qlen("jobs"), 0, "an unknown queue has depth 0")
  eq(bus.pull("jobs"), nil, "pull on an empty queue returns nil")
  bus.push("jobs", "a"); bus.push("jobs", "b"); bus.push("jobs", "c")
  eq(bus.qlen("jobs"), 3, "three items queued")
  eq(bus.pull("jobs"), "a", "FIFO: first pulled is the first pushed")
  eq(bus.pull("jobs"), "b", "FIFO: second")
  eq(bus.qlen("jobs"), 1, "depth drops as items are pulled")
  eq(bus.pull("jobs"), "c", "FIFO: third")
  eq(bus.pull("jobs"), nil, "drained queue pulls nil")
  eq(bus.qlen("jobs"), 0, "drained queue has depth 0")
end

-- ---- queues are independent by name ----------------------------------------
do
  bus.push("q1", "one"); bus.push("q2", "two")
  eq(bus.pull("q1"), "one", "named queues do not cross-contaminate (q1)")
  eq(bus.pull("q2"), "two", "named queues do not cross-contaminate (q2)")
end

-- ---- binary payloads survive (embedded NUL) --------------------------------
do
  local blob = "a\0b\0c"
  local got
  local id = bus.subscribe("bin", function(_, data) got = data end)
  bus.publish("bin", blob)
  eq(got, blob, "pub/sub preserves bytes including embedded NUL")
  bus.unsubscribe(id)
  bus.push("binq", blob)
  eq(bus.pull("binq"), blob, "queues preserve bytes including embedded NUL")
end

-- ---- cross-thread publish: a worker thread -> the main state ---------------
-- The MPMC/IPC heart of the fabric: a publish off the main thread cannot touch
-- the main state, so it enqueues bytes and the main loop's drain dispatches them
-- here. Proves topic+payload cross the thread boundary intact.
do
  local uv = require("uv")
  bus.attach_main()
  local got = {}
  local id = bus.subscribe("wk:*", function(topic, payload) got[#got + 1] = { topic, payload } end)
  local w = worker.spawn([[
    bus.publish("wk:hello", "from-worker")
    bus.publish("wk:arg", worker.arg)
    return 1
  ]], { arg = "seven" })
  local okc = worker.join(w)
  ok(okc, "cross-thread: the worker ran and joined")
  -- The drain async is unref'd (it must not hold the loop open), so uv_run only
  -- services it while the loop is otherwise alive -- which in production is the
  -- running scheduler. Here, a ref'd keepalive timer stands in for that.
  local ka = uv.new_timer(); ka:start(1000, 1000, function() end)
  local t = os.time()
  while #got < 2 and os.time() - t < 5 do uv.run("nowait") end
  ka:close()
  eq(#got, 2, "cross-thread: both worker publishes reached the main subscriber")
  ok(got[1] and got[1][1] == "wk:hello" and got[1][2] == "from-worker",
     "cross-thread: topic + payload carried across the thread boundary")
  ok(got[2] and got[2][1] == "wk:arg" and got[2][2] == "seven",
     "cross-thread: second publish delivered in order (FIFO)")
  bus.unsubscribe(id)
end

-- ---- stats -----------------------------------------------------------------
do
  local s = bus.stats()
  ok(type(s) == "table", "stats() returns a table")
  ok(s.published > 0 and s.delivered > 0, "stats counts publishes and deliveries")
  ok(type(s.dropped) == "number" and type(s.pending) == "number", "stats surfaces dropped + pending")
  eq(s.subscribers, 0, "no subscribers leaked (all test subs cleaned up)")
end

io.write(failed == 0 and ("fabric: all " .. passed .. " passed\n")
                      or ("fabric: " .. failed .. " FAILED, " .. passed .. " passed\n"))
os.exit(failed == 0 and 0 or 1)
