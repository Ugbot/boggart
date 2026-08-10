-- jwriter.lua -- the journal writer thread (src/jwriter.c) and the bus's use
-- of it (src/lswarm.c).
--
-- Journal rows no longer go to SQLite inline. The Lua thread publishes them
-- into a bounded SPSC ring and a dedicated writer thread, holding its own
-- connection to the same WAL database, batches them into transactions. That
-- buys an fsync off the actor's critical path and costs eventual consistency
-- for readers -- which is the interesting thing to pin down here.
--
-- No mutexes and no atomics are involved: two counting semaphores carry the
-- memory ordering, the head index is touched only by the producer and the tail
-- only by the consumer. These tests are the check that the handoff is right.
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

bog.userdir = os.tmpname() .. "_boggart_jwriter"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()
swarm.attach(bog.db) -- also starts the writer thread against the same file
swarm.clear()

local function jcount(where, args)
  swarm.flush()
  local r = bog.db:query("SELECT COUNT(*) AS n FROM journal " .. (where or ""), args)
  return r[1].n or r[1][1]
end

-- ---- the writer is actually running ----
local p0 = select(1, swarm.jstats())
swarm.send(1, 2, "first")
local p1, w1, s1 = swarm.jstats()
ok(p1 > p0, "send published a record to the ring")
ok(swarm.flush() == nil, "flush returns cleanly")
local p2, w2 = swarm.jstats()
eq(p2, w2, "after flush, everything published has been written")
ok(w2 > 0, "the writer thread committed rows")

-- ---- eventual consistency is real, and flush closes it ----
-- Not asserting the row is *absent* before flushing -- the writer may well have
-- got there first, and a timing-dependent assertion would be a flaky test. The
-- guarantee under test is the one that matters: after flush, it is there.
swarm.send(1, 99, "durable-after-flush")
eq(jcount("WHERE to_id=99"), 1, "row is present after flush")

-- ---- ordering is preserved through the ring ----
swarm.clear()
for i = 1, 200 do swarm.send(1, 500, "seq " .. i) end
swarm.flush()
local rows = bog.db:query(
  "SELECT payload FROM journal WHERE to_id=500 AND kind='send' ORDER BY id")
eq(#rows, 200, "all 200 rows landed")
local ordered = true
for i = 1, 200 do
  if rows[i].payload ~= "seq " .. i then ordered = false; break end
end
ok(ordered, "FIFO order survives the ring and the batching")

-- ---- ids are unique and monotonic, and allocated without waiting ----
local ids, dup = {}, false
for i = 1, 100 do
  local id = swarm.send(1, 600, "x")
  if ids[id] then dup = true end
  ids[id] = true
  ok(id and id > 0, i == 1 and "send returns a journal id immediately" or true)
end
ok(not dup, "journal ids are unique")
swarm.flush()
eq(jcount("WHERE to_id=600"), 100, "every allocated id produced a row")

-- ---- a processed stamp can never overtake its own insert ----
-- Both ride the same single-producer queue, so FIFO is what guarantees this.
swarm.clear()
local jid = swarm.send(1, 700, "stamp me")
swarm.mark_processed(jid)
swarm.flush()
local r = bog.db:query("SELECT processed_at FROM journal WHERE id=?", { jid })
eq(#r, 1, "the row exists")
ok(r[1].processed_at ~= nil, "processed_at was applied to the right row")

-- ---- redeliver drains the ring itself ----
swarm.clear()
swarm.send(1, 800, "r1")
swarm.send(1, 800, "r2")
swarm.clear()                    -- drop in-memory state, keep the journal
ok(swarm.redeliver() >= 2, "redeliver flushed and found the unprocessed rows")
eq(swarm.recv(800), "r1", "redelivered in order (first)")
eq(swarm.recv(800), "r2", "redelivered in order (second)")

-- ---- store.journal_list flushes on the caller's behalf ----
swarm.clear()
swarm.send(1, 900, "visible-to-journal_list")
local listed = bog.store.journal_list(10)
local found = false
for _, row in ipairs(listed) do
  if row.payload == "visible-to-journal_list" then found = true end
end
ok(found, "store.journal_list() drains the ring before reading")

-- ---- batching, and no back-pressure at realistic rates ----
swarm.clear()
local before = select(2, swarm.jstats())
for i = 1, 2000 do swarm.send(1, 1000, "burst " .. i) end
swarm.flush()
local pushed, written, stalls = swarm.jstats()
eq(written - before, 2000 + 0, "all 2000 burst rows were written")
eq(pushed, written, "nothing left unwritten")
eq(stalls, 0, "no producer stalled on a full ring at 2000 messages")
eq(jcount("WHERE to_id=1000"), 2000, "2000 rows on disk")

-- ---- publish fan-out also journals per subscriber ----
swarm.clear()
swarm.subscribe(11, "t"); swarm.subscribe(12, "t")
eq(swarm.publish(1, "t", "fan"), 2, "published to both subscribers")
swarm.flush()
eq(jcount("WHERE topic='t' AND kind='publish'"), 2, "one journal row per subscriber")

-- ---- WAL is still the mode the writer is using ----
eq(bog.store.journal_mode, "wal", "database is in WAL mode")

if bog.db then bog.db:close() end
sys.rmtree(bog.userdir)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
return failed == 0 and 0 or 1
