-- swarm.lua -- offline test of the swarm actor layer: async transport +
-- scheduler concurrency, spawn/await, pub/sub + inbox, the SQLite journal, and
-- resume/redeliver. No network: the async HTTP is stubbed, and (for the
-- orchestration parts) the LLM turn (api.run_on) is stubbed so we exercise the
-- scheduler/bus/journal rather than the model.
local json = require("json")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

-- throwaway store
bog.userdir = os.tmpname() .. "_boggart_swarm_test"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()
swarm.attach(bog.db)

-- load the swarm actor layer (eval mode doesn't run swarm dispatch)
bog.sched = require("sched")
bog.skills = require("skills")
bog.agents = require("agents")
bog.thread = require("thread")
bog.tools_swarm = require("tools_swarm")
bog.tools_swarm.register()

-- make auth headers resolve offline
local real_getenv = os.getenv
-- Credentials live in C now (src/lauth.c), so stubbing Lua's os.getenv no
-- longer satisfies them -- which is the point of moving them there. Set one
-- through the real mechanism; HOME is a temp dir, so this is isolated.
auth.set("api_key", "test-key")

-- ---- stub async HTTP -------------------------------------------------------
local canned = {}     -- queue of SSE bodies for http.begin
local take_order = {} -- records the tag of each take(), to prove interleaving
local begincount = 0

local function sse(text)
  local ev = {}
  local function d(o) ev[#ev + 1] = "data: " .. json.encode(o) .. "\n" end
  d{ type = "message_start", message = {} }
  d{ type = "content_block_start", index = 0, content_block = { type = "text", text = "" } }
  for i = 1, #text, 7 do d{ type = "content_block_delta", index = 0, delta = { type = "text_delta", text = text:sub(i, i + 6) } } end
  d{ type = "content_block_stop", index = 0 }
  d{ type = "message_delta", delta = { stop_reason = "end_turn" } }
  d{ type = "message_stop" }
  return table.concat(ev) .. "\n"
end

http = {
  request = http.request, -- keep the real blocking one available
  pump = function() end,  -- no-op (no real transfers; avoids the 50ms wait)
  begin = function(opts)
    begincount = begincount + 1
    local tag = "req" .. begincount
    local req = { data = table.remove(canned, 1) or sse("(empty)"), pos = 0, tag = tag }
    function req:take()
      if self.pos >= #self.data then return "" end
      local chunk = self.data:sub(self.pos + 1, self.pos + 15)
      self.pos = self.pos + 15
      take_order[#take_order + 1] = self.tag
      return chunk
    end
    function req:status()
      if self.pos >= #self.data then return "done", 200 end
      return "running"
    end
    function req:close() end
    return req
  end,
}

-- ===== Part A: async transport + scheduler concurrency ======================
do
  canned = { sse("alpha done"), sse("beta done") }
  take_order = {}
  local A, B
  bog.sched.add(101, coroutine.create(function()
    A = bog.api.msg_text((bog.api.stream_async({ model = "m", messages = {}, stream = true }, function() end)))
  end))
  bog.sched.add(102, coroutine.create(function()
    B = bog.api.msg_text((bog.api.stream_async({ model = "m", messages = {}, stream = true }, function() end)))
  end))
  bog.sched.run()
  eq(A, "alpha done", "async stream A decoded")
  eq(B, "beta done", "async stream B decoded")
  -- interleave: some req2 take happened before the last req1 take
  local first2, last1
  for i, t in ipairs(take_order) do
    if t == "req2" and not first2 then first2 = i end
    if t == "req1" then last1 = i end
  end
  ok(first2 and last1 and first2 < last1, "two async requests ran concurrently (interleaved)")
end

-- ===== stub the LLM turn for orchestration tests ============================
-- Simulate an agent turn: yield a few times (so children interleave under the
-- scheduler) then emit a deterministic result. No HTTP, no tools.
local turn_order = {}
bog.api.run_on = function(sess, task, on_text, opts)
  sess.messages[#sess.messages + 1] = { role = "user", content = task }
  for _ = 1, 3 do
    turn_order[#turn_order + 1] = sess.id
    coroutine.yield("io", {}) -- simulate async work; scheduler interleaves peers
  end
  local out = "result of: " .. tostring(task)
  if on_text then on_text(out) end
  sess.messages[#sess.messages + 1] = { role = "assistant", content = { { type = "text", text = out } } }
  return { role = "assistant", content = { { type = "text", text = out } } }, "end_turn"
end

-- ===== Part B: spawn + await + journal ======================================
local coord
do
  coord = bog.thread.new_agent{ agent = "coordinator", title = "coordinator" }
  turn_order = {}
  local result
  bog.sched.add(coord.id, coroutine.create(function()
    local id1 = bog.thread.spawn{ task = "alpha", agent = "researcher", parent_id = coord.id }
    local id2 = bog.thread.spawn{ task = "beta", agent = "researcher", parent_id = coord.id }
    result = bog.tools.run("await", { ids = { id1, id2 } })
  end))
  bog.sched.run()
  ok(result and result:find("result of: alpha"), "await collected child 1 result")
  ok(result and result:find("result of: beta"), "await collected child 2 result")

  -- the two children ran concurrently: the second child's first step precedes
  -- the first child's last step (turn_order holds each child's session id per step)
  local firstid = turn_order[1]
  local other_first, first_last
  for i, id in ipairs(turn_order) do
    if id ~= firstid and not other_first then other_first = i end
    if id == firstid then first_last = i end
  end
  ok(other_first and first_last and other_first < first_last, "two child agents ran concurrently (interleaved)")

  -- journal: two child->coordinator 'send' rows, both marked processed by await
  -- Journal writes are async (src/jwriter.c batches them on a writer thread),
  -- so a direct SQL read has to drain the ring first. bog.store.journal_list()
  -- and swarm.redeliver() do this for you; raw queries like this one must not
  -- forget to.
  swarm.flush()
  local rows = bog.db:query("SELECT from_id,to_id,processed_at FROM journal WHERE kind='send' AND to_id=?", { coord.id })
  eq(#rows, 2, "journal recorded 2 result sends to coordinator")
  ok(rows[1].processed_at ~= nil and rows[1].processed_at ~= json.null, "await marked messages processed")
end

-- ===== Part C: publish / subscribe / inbox ==================================
do
  local Bid = 777
  swarm.subscribe(Bid, "news")
  local n = swarm.publish(0, "news", json.encode{ kind = "msg", from = 0, text = "hello subscribers" })
  eq(n, 1, "publish reached 1 subscriber")
  local got
  bog.sched.add(Bid, coroutine.create(function() got = bog.tools.run("inbox", {}) end))
  bog.sched.run()
  ok(got and got:find("hello subscribers"), "inbox tool drained the published message")
  eq(bog.tools.run and (function() -- inbox now empty
    local g2
    bog.sched.add(Bid, coroutine.create(function() g2 = bog.tools.run("inbox", {}) end))
    bog.sched.run()
    return g2
  end)(), "(inbox empty)", "inbox empties after draining")
end

-- ===== Part D: resume / redeliver ===========================================
do
  swarm.send(0, 888, json.encode{ kind = "msg", from = 0, text = "durable" })
  ok(swarm.pending(888) >= 1, "message queued")
  swarm.clear() -- drop in-memory bus (simulate restart), journal survives
  eq(swarm.pending(888), 0, "in-memory bus cleared")
  local red = swarm.redeliver()
  ok(red >= 1, "redeliver re-enqueued undelivered journal rows")
  ok(swarm.pending(888) >= 1, "resumed message is back in the mailbox")
  -- a processed message is NOT redelivered
  local m, jid = swarm.recv(888)
  swarm.mark_processed(jid)
  swarm.clear()
  swarm.redeliver()
  eq(swarm.pending(888), 0, "processed message is not redelivered")
end

os.getenv = real_getenv
if bog.db then bog.db:close() end
sys.exec("rm -rf " .. string.format("%q", bog.userdir), 10)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
return failed == 0 and 0 or 1
