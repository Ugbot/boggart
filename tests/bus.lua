-- bus.lua -- the swarm message bus (src/lswarm.c) after its move onto libuv
-- intrusive queues (struct uv__queue) + a uv_mutex_t.
--
-- Targets the two things an intrusive-queue refactor is most likely to break:
-- FIFO ordering (insert_tail / head-out) and O(1) removal from the middle of a
-- list (unsubscribe, mailbox teardown). tests/swarm.lua covers the actor layer
-- above this; here we poke the C directly.
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

bog.userdir = os.tmpname() .. "_boggart_bus_test"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()
swarm.attach(bog.db)
swarm.clear()

-- ---- FIFO ordering ----
-- The classic intrusive-queue bug is inserting at head and reading at head,
-- which silently turns the mailbox into a LIFO stack.
for i = 1, 10 do swarm.send(1, 42, "m" .. i) end
eq(swarm.pending(42), 10, "ten messages queued")
local order_ok = true
for i = 1, 10 do
  local payload = swarm.recv(42)
  if payload ~= "m" .. i then order_ok = false end
end
ok(order_ok, "mailbox is FIFO, not LIFO")
eq(swarm.pending(42), 0, "mailbox drained")
eq(swarm.recv(42), nil, "recv on an empty mailbox returns nil")

-- ---- mailboxes are independent ----
swarm.send(1, 100, "for-100")
swarm.send(1, 200, "for-200")
eq(swarm.pending(100), 1, "mailbox 100 has its own message")
eq(swarm.pending(200), 1, "mailbox 200 has its own message")
eq(swarm.recv(100), "for-100", "mailbox 100 payload")
eq(swarm.recv(200), "for-200", "mailbox 200 payload")

-- ---- journal ids ride with the message ----
local jid = swarm.send(1, 7, "durable")
local payload, got_jid = swarm.recv(7)
eq(payload, "durable", "payload survives the queue")
eq(got_jid, jid, "journal id travels with the message")
ok(jid >= 0, "send returned a real journal row id")

-- ---- pub/sub fan-out ----
swarm.subscribe(11, "news")
swarm.subscribe(12, "news")
swarm.subscribe(13, "news")
eq(swarm.publish(1, "news", "hello"), 3, "publish reaches all three subscribers")
eq(swarm.pending(11), 1, "subscriber 11 got it")
eq(swarm.pending(12), 1, "subscriber 12 got it")
eq(swarm.pending(13), 1, "subscriber 13 got it")
eq(swarm.recv(11), "hello", "subscriber 11 payload")
swarm.recv(12); swarm.recv(13)

-- duplicate subscribe must be a no-op, not a second delivery
swarm.subscribe(11, "news")
eq(swarm.publish(1, "news", "again"), 3, "duplicate subscribe does not double-deliver")
eq(swarm.pending(11), 1, "subscriber 11 received exactly once")
swarm.recv(11); swarm.recv(12); swarm.recv(13)

-- ---- unsubscribe: removal from head, middle and tail of the queue ----
-- uv__queue_remove is O(1) and unlinks in place; removing the *middle* entry
-- is the case a hand-rolled singly-linked list gets wrong.
swarm.unsubscribe(12, "news") -- middle
eq(swarm.publish(1, "news", "x"), 2, "middle subscriber removed")
ok(swarm.pending(12) == 0, "removed subscriber receives nothing")
swarm.recv(11); swarm.recv(13)

swarm.unsubscribe(11, "news")
eq(swarm.publish(1, "news", "y"), 1, "second removal leaves one")
swarm.recv(13)
swarm.unsubscribe(13, "news")
eq(swarm.publish(1, "news", "z"), 0, "last subscriber removed; fan-out is zero")

-- unsubscribing something never subscribed must not corrupt the list
swarm.unsubscribe(999, "news")
swarm.subscribe(14, "news")
eq(swarm.publish(1, "news", "after"), 1, "topic still usable after a bogus unsubscribe")
swarm.recv(14)

-- ---- clear() tears down both queues without leaking or crashing ----
for i = 1, 5 do swarm.send(1, 300 + i, "junk") end
swarm.subscribe(20, "t1"); swarm.subscribe(21, "t2")
swarm.clear()
eq(swarm.pending(301), 0, "clear drained mailboxes")
eq(swarm.publish(1, "t1", "gone"), 0, "clear dropped subscriptions")

-- the bus must still work after a clear
swarm.send(1, 400, "post-clear")
eq(swarm.recv(400), "post-clear", "bus usable after clear")

-- ---- redeliver re-enqueues unprocessed journal rows, preserving order ----
swarm.clear()
local j1 = swarm.send(1, 500, "r1")
local j2 = swarm.send(1, 500, "r2")
swarm.clear()                       -- drop in-memory state, keep the journal
eq(swarm.pending(500), 0, "cleared before redeliver")
ok(swarm.redeliver() >= 2, "redeliver re-enqueued the unprocessed rows")
eq(swarm.recv(500), "r1", "redelivered in journal order (first)")
eq(swarm.recv(500), "r2", "redelivered in journal order (second)")

-- a row stamped processed must NOT come back
swarm.clear()
swarm.mark_processed(j1)
swarm.mark_processed(j2)
swarm.redeliver()
eq(swarm.pending(500), 0, "processed rows are not redelivered")

if bog.db then bog.db:close() end
sys.rmtree(bog.userdir)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
return failed == 0 and 0 or 1
