-- events.lua -- the autocommand bus (lua/events.lua) and, more importantly,
-- its wiring.
--
-- Two halves, and the second is the one that would rot. Testing the bus in
-- isolation proves only that a table of callbacks works. So every event this
-- module claims to emit is driven here through the REAL code path -- the turn
-- loop with a stubbed transport, the actual write/edit tools, the actual
-- scheduler, bog.new_session -- and the last block fails if anything in
-- events.EVENTS was never seen. Delete an emit call in api.lua and this suite
-- goes red; add an event to the doc table without wiring it and it goes red
-- too.
local json = require("json")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

-- ---- isolation: throwaway userdir + store ----------------------------------
bog.userdir = os.tmpname() .. "_boggart_events"
sys.mkdir_p(bog.userdir .. "/lua/events")
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()

local events = bog.events

-- Every event seen during the whole run, by any path. Re-registered after each
-- clear() so the coverage check at the bottom sees everything -- which means a
-- "*" handler is subscribed nearly everywhere below, and emit() counts it.
local seen = {}
local COLLECTOR = 1
local function watch_all()
  events.on("*", function(name) seen[name] = (seen[name] or 0) + 1 end,
            { desc = "coverage collector" })
end
local function reset()
  events.clear()
  watch_all()
end
reset()

-- ==========================================================================
-- The bus
-- ==========================================================================

-- ---- registration and firing ----
do
  reset()
  local got = {}
  local h = events.on("t:one", function(name, data) got[#got + 1] = name .. "=" .. tostring(data.v) end)
  eq(type(h), "table", "on() returns a handle")
  eq(events.emit("t:one", { v = 42 }), 1 + COLLECTOR, "emit reports how many handlers ran")
  eq(#got, 1, "the handler fired")
  eq(got[1], "t:one=42", "the handler receives (event_name, data)")

  eq(events.emit("t:other", {}), COLLECTOR, "an unrelated event does not fire it")
  eq(#got, 1, "...and really did not")
end

-- ---- nothing subscribed costs nothing --------------------------------------
do
  reset()
  events.clear() -- not even the collector
  eq(events.any("nobody:listening"), false, "any() is false with no handlers")
  eq(events.emit("nobody:listening", { x = 1 }), 0, "emit is a no-op with no handlers")

  -- The cheapness claim, pinned loosely enough not to flake: the no-handler
  -- path is one comparison and a return, so 200k of them are milliseconds.
  local t0 = os.clock()
  for i = 1, 200000 do events.emit("nobody:listening") end
  local dt = os.clock() - t0
  ok(dt < 2.0, string.format("200k unsubscribed emits are ~free (%.3fs)", dt))
  watch_all()
end

-- ---- wildcards ----
do
  reset()
  local hits = {}
  local function counter(tag) return function(name) hits[tag] = (hits[tag] or 0) + 1 end end
  events.on("tool:*", counter("tool"))
  events.on("*", counter("all"))
  events.on("tool:before", counter("exact"))
  events.on("a.b", counter("dot"))

  events.emit("tool:before", {})
  events.emit("tool:after", {})
  events.emit("file:write", {})
  events.emit("axb", {})

  eq(hits.tool, 2, "'tool:*' matched both tool events")
  eq(hits.exact, 1, "an exact pattern matched only its own event")
  eq(hits.all, 4, "'*' matched everything")
  eq(hits.dot, nil, "patterns are globs, not Lua patterns: '.' is a literal")
  events.emit("a.b", {})
  eq(hits.dot, 1, "...and matches the literal dot")
end

-- ---- ordering ----
do
  reset()
  local order = {}
  events.on("*", function() order[#order + 1] = "first" end)
  events.on("o:x", function() order[#order + 1] = "second" end)
  events.on("o:*", function() order[#order + 1] = "third" end)
  events.emit("o:x", {})
  eq(table.concat(order, ","), "first,second,third",
     "handlers fire in registration order, wildcards included")
end

-- ---- once ----
do
  reset()
  local n = 0
  events.on("once:me", function() n = n + 1 end, { once = true })
  events.emit("once:me", {})
  events.emit("once:me", {})
  events.emit("once:me", {})
  eq(n, 1, "once=true fires exactly once")
  local found = false
  for _, h in ipairs(events.list()) do if h.pattern == "once:me" then found = true end end
  eq(found, false, "...and unsubscribes itself")
end

-- ---- off ----
do
  reset()
  local n = 0
  local h1 = events.on("off:me", function() n = n + 1 end)
  local h2 = events.on("off:me", function() n = n + 100 end)
  events.emit("off:me", {})
  eq(n, 101, "both handlers ran")
  eq(events.off(h1), true, "off(handle) reports success")
  events.emit("off:me", {})
  eq(n, 201, "the removed handler no longer runs")
  eq(events.off(h2.id), true, "off() also accepts a bare id")
  events.emit("off:me", {})
  eq(n, 201, "both are gone")
  eq(events.off(h1), false, "off() on an already-removed handle is false, not an error")

  -- off() means off from that instant, including for a dispatch already in
  -- flight. The alternative (finish the emit with the list as it stood) would
  -- mean a view that unsubscribes because it is being torn down still gets
  -- called once more, which is exactly the case off() exists to prevent.
  reset()
  local seq = {}
  local a, b
  a = events.on("off:live", function() seq[#seq + 1] = "a"; events.off(b) end)
  b = events.on("off:live", function() seq[#seq + 1] = "b" end)
  events.emit("off:live", {})
  events.emit("off:live", {})
  eq(table.concat(seq, ","), "a,a",
     "a handler removed mid-dispatch does not run, not even for the emit in flight")
end

-- ---- list() ----
do
  reset()
  events.on("l:x", function() end, { desc = "described" })
  local rows = events.list()
  local row
  for _, r in ipairs(rows) do if r.pattern == "l:x" then row = r end end
  ok(row ~= nil, "list() reports the registration")
  eq(row.desc, "described", "list() carries the description")
  eq(row.calls, 0, "list() counts calls")
  events.emit("l:x", {})
  for _, r in ipairs(events.list()) do if r.pattern == "l:x" then row = r end end
  eq(row.calls, 1, "...and the count moves")
end

-- ==========================================================================
-- Isolation: a bad handler is the handler's problem
-- ==========================================================================

-- ---- throwing ----
do
  reset()
  local ran = {}
  local quiet = 0
  local real_sink = events.sink
  events.sink = function() quiet = quiet + 1 end -- swallow the error report

  events.on("boom:*", function() ran[#ran + 1] = "before" end)
  events.on("boom:*", function() error("deliberate handler failure") end)
  events.on("boom:*", function() ran[#ran + 1] = "after" end)

  local emitted = events.emit("boom:now", {})
  eq(emitted, 3 + COLLECTOR, "the emitter counted all three handlers")
  eq(table.concat(ran, ","), "before,after",
     "a handler that throws stops neither the handlers behind it nor the emitter")
  ok(quiet > 0, "the failure was reported through notify, not raised")

  -- ...and the emitter's own code carries on normally
  local after_emit = false
  events.emit("boom:now", {})
  after_emit = true
  ok(after_emit, "the code that emitted continues past the failure")

  -- a persistently broken handler is eventually unsubscribed rather than
  -- allowed to produce one traceback per streamed token
  reset()
  events.sink = function() end
  local calls = 0
  events.on("boom:always", function() calls = calls + 1; error("nope") end)
  for _ = 1, 12 do events.emit("boom:always", {}) end
  ok(calls >= 3 and calls <= 6,
     "a handler that keeps throwing is unsubscribed (" .. calls .. " calls)")
  events.sink = real_sink
end

-- ---- yielding: the hazard that matters under the scheduler ----
do
  reset()
  local quiet = 0
  local real_sink = events.sink
  events.sink = function() quiet = quiet + 1 end

  local tail = false
  events.on("y:test", function() coroutine.yield("proc", "fake handle") end)
  events.on("y:test", function() tail = true end)

  -- Emitting from inside a coroutine is the swarm case: an agent's turn is a
  -- coroutine, and sched.lua reads its yields. If a handler's yield escaped, it
  -- would surface here as a suspended coroutine with the scheduler being told
  -- the *agent* is waiting on a process that does not exist.
  local co = coroutine.create(function()
    events.emit("y:test", {})
    return "reached the end"
  end)
  local okr, val = coroutine.resume(co)
  eq(okr, true, "the emitting coroutine did not fail")
  eq(coroutine.status(co), "dead", "a yielding handler does not suspend the emitter's coroutine")
  eq(val, "reached the end", "the emitter ran to completion")
  eq(tail, true, "the handler after the yielding one still ran")
  ok(quiet > 0, "the dropped handler was reported")
  events.sink = real_sink
end

-- ---- runaway recursion is bounded ----
do
  reset()
  local n = 0
  events.on("r:loop", function() n = n + 1; events.emit("r:loop", {}) end)
  events.emit("r:loop", {})
  ok(n >= 2 and n <= 16, "a handler that re-emits its own event is depth-capped (" .. n .. ")")
end

-- ==========================================================================
-- notify -- one function, both worlds
-- ==========================================================================
do
  reset()
  local got = {}
  events.on("notify", function(_, d) got[#got + 1] = d.level .. ":" .. d.msg end)
  local sunk = {}
  local real_sink = events.sink
  events.sink = function(msg, level) sunk[#sunk + 1] = level .. "|" .. msg end

  events.notify("plain message")
  events.notify("careful", "warn")
  events.notify("broken", "error")
  events.notify("nonsense level", "banana")

  eq(#got, 4, "notify emits a subscribable event")
  eq(got[1], "info:plain message", "the default level is info")
  eq(got[2], "warn:careful", "the level rides on the payload")
  eq(got[4], "info:nonsense level", "an unknown level degrades to info")
  eq(#sunk, 4, "and it also reaches the sink, so a headless run still sees it")
  ok(sunk[3]:find("^error|broken"), "the sink is told the level")

  -- a sink that throws must not take the caller down: notify is called from
  -- the failure path of a failed handler
  events.sink = function() error("sink is broken") end
  local sok = pcall(events.notify, "into a broken sink")
  eq(sok, true, "a broken sink does not propagate")
  events.sink = real_sink
end

-- ==========================================================================
-- Registration from user Lua: ~/.boggart/lua/events/*.lua
-- ==========================================================================
do
  reset()
  bog.util.write_file(bog.userdir .. "/lua/events/greeting.lua", [[
local events = ...
events.on("user:hello", function(_, d) bog.__events_test_saw = d.who end,
          { desc = "from an overlay file" })
]])
  -- A runtime registration must survive the reload; a file registration must be
  -- re-read. Both are asserted below.
  local runtime_calls = 0
  events.on("user:hello", function() runtime_calls = runtime_calls + 1 end)

  ok(bog.reload(), "harness reloads with an overlay event file present")
  events = bog.events

  local from_file = false
  for _, h in ipairs(events.list()) do
    if h.desc == "from an overlay file" then
      from_file = true
      ok(h.source:sub(1, 5) == "user:", "an overlay handler is tagged as coming from a file")
    end
  end
  ok(from_file, "a file dropped in ~/.boggart/lua/events/ registered its handler")

  events.emit("user:hello", { who = "world" })
  eq(bog.__events_test_saw, "world", "the overlay handler actually fires")
  eq(runtime_calls, 1, "a handler registered at runtime survives a harness reload")

  -- reloading again must not double-register the file
  ok(bog.reload(), "second reload")
  events = bog.events
  local n = 0
  for _, h in ipairs(events.list()) do if h.desc == "from an overlay file" then n = n + 1 end end
  eq(n, 1, "reloading re-reads the file rather than stacking duplicates")
  os.remove(bog.userdir .. "/lua/events/greeting.lua")
end

-- ==========================================================================
-- The agent's own route: the on_event tool
-- ==========================================================================
do
  reset()
  local out = bog.tools.run("on_event", {
    event = "agent:*",
    desc = "written by the model",
    lua = "events.notify('handled ' .. event .. ' for ' .. tostring(data.what))",
  })
  ok(out:find("^Registered handler"), "on_event registers a handler: " .. out:sub(1, 40))
  ok(out:find("session%-only"), "...and says out loud that it will not persist")

  local sunk = {}
  local real_sink = events.sink
  events.sink = function(msg) sunk[#sunk + 1] = msg end
  events.emit("agent:thing", { what = "x" })
  eq(#sunk, 1, "the model-written handler ran")
  ok(sunk[1]:find("handled agent:thing for x", 1, true) ~= nil, "...with the event and payload")
  events.sink = real_sink

  local listing = bog.tools.run("on_event", { op = "list" })
  ok(listing:find("written by the model", 1, true) ~= nil, "op=list shows it")

  -- Handler bodies get the tool capability environment, not _G. The handler
  -- reports back through the kv tool because that is all it has -- which is
  -- itself the point: no io, no require, no bog.
  bog.tools.run("on_event", { event = "agent:env",
    lua = "tools.call('kv', { op = 'set', key = 'ev_env', value = "
       .. "tostring(io) .. '|' .. tostring(require) .. '|' .. tostring(sys.home ~= nil) })" })
  events.emit("agent:env", {})
  eq(bog.store.kv_get("ev_env"), "nil|nil|true",
     "a model-written handler cannot reach io or require, exactly like a tool body")

  local id
  for _, h in ipairs(events.list()) do if h.desc == "written by the model" then id = h.id end end
  ok(bog.tools.run("on_event", { op = "off", id = id }):find("^Removed"), "op=off removes it")
  ok(bog.tools.run("on_event", { event = "x", lua = "this is not lua" })
     :find("^Tool error"), "a body that will not compile is a validation error")

  -- nothing was written to disk: session-only means session-only
  local files = sys.listdir(bog.userdir .. "/lua/events") or {}
  eq(#files, 0, "on_event persisted nothing to ~/.boggart/lua/events/")
end

-- ==========================================================================
-- The wiring: every event, driven through the real code path
-- ==========================================================================

-- ---- offline transport, as tests/integration.lua does ----------------------
auth.set("api_key", "sk-ant-offline-test-key")
local real_getenv = os.getenv
os.getenv = function(name) -- luacheck: ignore
  if name == "ANTHROPIC_API_KEY" then return "sk-ant-offline-test-key" end
  return real_getenv(name)
end

local function ev(etype, tbl)
  return "event: " .. etype .. "\ndata: " .. json.encode(tbl) .. "\n\n"
end
local function message_start()
  return ev("message_start", { type = "message_start", message = {
    id = "msg_test", type = "message", role = "assistant", content = {},
    model = bog.session.model, usage = { input_tokens = 10, output_tokens = 1 } } })
end
local function text_block(index, pieces)
  local out = { ev("content_block_start", { type = "content_block_start", index = index,
    content_block = { type = "text", text = "" } }) }
  for _, p in ipairs(pieces) do
    out[#out + 1] = ev("content_block_delta", { type = "content_block_delta", index = index,
      delta = { type = "text_delta", text = p } })
  end
  out[#out + 1] = ev("content_block_stop", { type = "content_block_stop", index = index })
  return table.concat(out)
end
local function tool_block(index, id, name, input)
  return ev("content_block_start", { type = "content_block_start", index = index,
      content_block = { type = "tool_use", id = id, name = name, input = {} } })
    .. ev("content_block_delta", { type = "content_block_delta", index = index,
      delta = { type = "input_json_delta", partial_json = json.encode(input) } })
    .. ev("content_block_stop", { type = "content_block_stop", index = index })
end
local function finish(stop)
  return ev("message_delta", { type = "message_delta", delta = { stop_reason = stop },
    usage = { output_tokens = 42 } }) .. ev("message_stop", { type = "message_stop" })
end
local function plain(pieces, stop)
  return message_start() .. text_block(0, pieces) .. finish(stop or "end_turn")
end

-- One transport now (async), so the stub is http.begin: it hands the whole
-- canned SSE back on the first req:take() and reports "done". next_status drives
-- the error path -- a non-200 with an error body in the stream, exactly what the
-- real transport sees. Turns run as scheduler coroutines via drive().
local sched = require("sched")
bog.sched = sched
local queue, next_status = {}, nil
http.pump = function() return 0 end
http.begin = function(opts)
  assert(opts.url and opts.method == "POST", "stub: unexpected request shape")
  local body, st
  if next_status then
    st, next_status = next_status, nil
    body = '{"error":{"message":"max_tokens: 999999 exceeds the limit"}}'
  else
    body, st = table.remove(queue, 1), 200
    if not body then error("stub: empty response queue (runaway loop?)") end
  end
  local req = { chunks = { body }, idx = 0, st = st }
  function req:take() self.idx = self.idx + 1; return self.chunks[self.idx] or "" end
  function req:status()
    if self.idx >= #self.chunks then return "done", self.st end
    return "running"
  end
  function req:close() end
  return req
end

-- Drive one turn (or compaction) to completion under the scheduler -- the same
-- coroutine-on-the-loop shape production uses. Errors are re-raised so the
-- error-path test still sees the throw.
local function drive(fn)
  local err
  local co = coroutine.create(function()
    local okc, e = pcall(fn)
    if not okc then err = e end
  end)
  sched.actors, sched.by_id = {}, {}
  sched.add(bog.session.id or 9000, co)
  sched.run()
  if err then error(err, 0) end
end

-- ---- session lifecycle -----------------------------------------------------
do
  reset()
  local created, saved, resumed = nil, nil, nil
  events.on("session:created", function(_, d) created = d end)
  events.on("session:saved", function(_, d) saved = d end)
  events.on("session:resumed", function(_, d) resumed = d end)

  bog.new_session()
  ok(created ~= nil and created.id == bog.session.id, "bog.new_session emits session:created")

  bog.session.messages = { { role = "user", content = "hello" } }
  bog.session.title = "events test"
  bog.save_session()
  ok(saved ~= nil and saved.id == bog.session.id, "bog.save_session emits session:saved")
  eq(saved and saved.count, 1, "...with the message count, not the messages")

  local id = bog.session.id
  bog.session.messages = {}
  eq(bog.resume_session(id), true, "the session resumes")
  ok(resumed ~= nil and resumed.id == id, "bog.resume_session emits session:resumed")
  eq(resumed and resumed.count, 1, "...with what it restored")
end

-- ---- turn lifecycle --------------------------------------------------------
do
  reset()
  local start, chunks, ended = nil, {}, nil
  events.on("turn:start", function(_, d) start = d end)
  events.on("turn:text", function(_, d) chunks[#chunks + 1] = d.text end)
  events.on("turn:end", function(_, d) ended = d end)

  bog.session.messages = {}
  queue = { plain({ "Hello", " there" }) }
  local streamed = {}
  drive(function() bog.api.run_turn("say hi", function(t) streamed[#streamed + 1] = t end) end)

  ok(start ~= nil, "the turn loop emits turn:start")
  eq(start and start.preview, "say hi", "turn:start carries a preview of the user text")
  eq(start and start.chars, 6, "...and the true length")
  eq(table.concat(chunks), "Hello there", "turn:text delivers every streamed delta")
  eq(table.concat(streamed), "Hello there", "the caller's own on_text still works alongside it")
  ok(ended ~= nil, "the turn loop emits turn:end")
  eq(ended and ended.stop, "end_turn", "turn:end reports the stop reason")

  -- a long prompt is previewed, not shipped whole
  bog.session.messages = {}
  queue = { plain({ "ok" }) }
  local long = string.rep("x", 5000)
  drive(function() bog.api.run_turn(long, nil) end)
  eq(#start.preview, 200, "turn:start truncates the preview")
  eq(start.chars, 5000, "...and says how much it truncated")
end

-- ---- turn:error ------------------------------------------------------------
do
  reset()
  local err = nil
  events.on("turn:error", function(_, d) err = d end)
  bog.session.messages = {}
  next_status = 400 -- a request error: not retried, raised at once
  local threw = not pcall(drive, function() bog.api.run_turn("this will fail", nil) end)
  ok(threw, "the turn still raises for its caller")
  ok(err ~= nil, "a failing turn emits turn:error")
  eq(err and err.kind, bog.api.ERR.bad_request, "turn:error carries the typed kind")
  ok(err and err.message:find("400", 1, true) ~= nil, "...and the human message")
end

-- ---- tools + file changes --------------------------------------------------
do
  reset()
  local before, after, wrote, edited = nil, nil, nil, nil
  events.on("tool:before", function(_, d) before = d end)
  events.on("tool:after", function(_, d) after = d end)
  events.on("file:write", function(_, d) wrote = d end)
  events.on("file:edit", function(_, d) edited = d end)

  -- through the real turn loop, as the model would reach it
  local target = bog.userdir .. "/written.txt"
  bog.session.messages = {}
  queue = {
    message_start() .. tool_block(0, "toolu_1", "write", { path = target, content = "one\ntwo\n" })
      .. finish("tool_use"),
    plain({ "done" }),
  }
  drive(function() bog.api.run_turn("write a file", nil) end)

  eq(before and before.name, "write", "tools.run emits tool:before")
  eq(before and before.input.path, target, "tool:before carries the arguments")
  eq(after and after.name, "write", "tools.run emits tool:after")
  eq(after and after.error, false, "tool:after says whether the tool failed")
  ok(after and after.bytes > 0, "tool:after carries the result size, not the result")
  eq(wrote and wrote.path, target, "the write tool emits file:write")
  eq(wrote and wrote.bytes, 8, "file:write carries the size")
  eq(wrote and wrote.lines, 3, "...and the line count")

  bog.tools.run("edit", { path = target, old = "two", new = "three" })
  eq(edited and edited.path, target, "the edit tool emits file:edit")
  eq(edited and edited.bytes, 10, "file:edit carries the resulting file size")

  -- a failing tool still pairs before/after, and says it failed
  before, after = nil, nil
  bog.tools.run("read", { path = bog.userdir .. "/does-not-exist" })
  eq(before and before.name, "read", "a failing tool still emits tool:before")
  eq(after and after.error, true, "...and tool:after reports the failure")

  -- an unknown tool never ran, so it announces nothing
  before, after = nil, nil
  bog.tools.run("no_such_tool_at_all", {})
  eq(before, nil, "an unknown tool emits no tool:before")
  eq(after, nil, "...and no tool:after")
end

-- ---- tool:refused ----------------------------------------------------------
do
  reset()
  local refused, ran = nil, false
  events.on("tool:refused", function(_, d) refused = d end)
  events.on("tool:before", function() ran = true end)

  bog.session.messages = {}
  queue = {
    message_start() .. tool_block(0, "toolu_2", "bash", { command = "rm -rf /" })
      .. finish("tool_use"),
    plain({ "understood" }),
  }
  -- Exactly what the studio's approval gate and thread.lua's per-agent
  -- allowlist return: a permission_error result, with the tool never called.
  drive(function()
    bog.api.run_on(bog.session, "delete everything", nil, {
      on_tool = function() end,
      run_tool = function(name)
        return "Tool error: [permission_error] the user rejected this " .. name .. " call."
      end,
    })
  end)
  ok(refused ~= nil, "a refused call emits tool:refused")
  eq(refused and refused.name, "bash", "tool:refused names the tool")
  ok(refused and refused.reason:find("rejected", 1, true) ~= nil, "...and why")
  eq(ran, false, "a refused tool never reached tools.run, so it emitted no tool:before")
end

-- ---- context:compacted -----------------------------------------------------
do
  reset()
  local comp = nil
  events.on("context:compacted", function(_, d) comp = d end)
  bog.session.messages = {
    { role = "user", content = string.rep("a lot of earlier conversation. ", 40) },
    { role = "assistant", content = { { type = "text", text = "acknowledged" } } },
    { role = "user", content = "and the latest question" },
  }
  queue = { plain({ "Summary of what happened." }) }
  local compacted; drive(function() compacted = bog.api.compact(bog.session, {}) end)
  eq(compacted, true, "compaction ran")
  ok(comp ~= nil, "api.compact emits context:compacted")
  ok(comp and comp.before > comp.after, "context:compacted reports sizes, not text")
  eq(comp and comp.session, bog.session.id, "...against the session it compacted")
end

-- ---- swarm actors ----------------------------------------------------------
do
  reset()
  local sched = require("sched")
  sched.actors, sched.by_id = {}, {}
  local started, stopped = {}, {}
  events.on("swarm:actor_started", function(_, d) started[#started + 1] = d.id end)
  events.on("swarm:actor_stopped", function(_, d) stopped[#stopped + 1] = d.id .. ":" .. d.reason end)

  sched.add(101, coroutine.create(function() return true end))
  sched.add(102, coroutine.create(function() error("agent blew up") end))
  sched.add(103, coroutine.create(function() coroutine.yield("recv") end))
  eq(#started, 3, "every actor added to the scheduler emits swarm:actor_started")

  sched.kill(103)
  sched.run()
  table.sort(stopped)
  eq(table.concat(stopped, ","), "101:done,102:crashed,103:killed",
     "swarm:actor_stopped distinguishes finishing, crashing and being killed")
  sched.actors, sched.by_id = {}, {}
end

-- ==========================================================================
-- Install lifecycle: a store created, and a damaged one recovered
-- ==========================================================================
-- Through store.open() itself, not a hand-rolled emit -- the events exist so a
-- GUI can react to "your history just went away", and that only means anything
-- if the real repair path is what fires them. The recovery prints a loud
-- notice to stderr here; that is the behaviour under test, not noise.
do
  reset()
  local keep_dir, keep_db = bog.userdir, bog.db
  local dir = os.tmpname() .. "_boggart_events_install"
  bog.userdir, bog.db = dir, nil
  bog.store.open()
  ok(seen["store:created"], "creating the store on a new machine emits store:created")
  bog.db:close(); bog.db = nil

  bog.util.write_file(dir .. "/boggart.db", "NOT A DATABASE")
  bog.store.open()
  ok(seen["store:recovered"], "a damaged store is recreated and emits store:recovered")
  bog.db:close()

  sys.rmtree(dir)
  bog.userdir, bog.db = keep_dir, keep_db
end

-- ==========================================================================
-- Coverage: everything events.EVENTS documents was emitted for real above
-- ==========================================================================
do
  local missing = {}
  local names = {}
  for name in pairs(events.EVENTS) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    if not seen[name] then missing[#missing + 1] = name end
  end
  ok(#missing == 0, "every documented event is emitted by a real code path"
    .. (#missing > 0 and (" -- never saw: " .. table.concat(missing, ", ")) or ""))
  eq(#names, 18, "the documented event list is the one this suite drove")
end

-- ---- the fabric bridge (events -> src/lbus.c `bus`) ------------------------
-- Every emit is mirrored onto the C bus as JSON bytes, but only when something
-- is subscribed there; events.any() counts a bus subscriber as a listener.
do
  local json = require("json")
  events.clear()
  ok(events.any("turn:end") == false, "bridge: any() false with neither handler nor bus sub")

  local got
  local id = bus.subscribe("turn:end", function(topic, payload) got = { topic, payload } end)
  ok(events.any("turn:end") == true, "bridge: any() true once a bus subscriber matches (no Lua handler)")

  events.emit("turn:end", { session = 7, stop = "end_turn" })
  ok(got ~= nil, "bridge: emit with only a bus subscriber still mirrors onto the fabric")
  eq(got[1], "turn:end", "bridge: the topic is carried through")
  local dec = json.decode(got[2])
  ok(dec.session == 7 and dec.stop == "end_turn", "bridge: the payload round-trips as JSON")

  -- A Lua handler and a bus subscriber both fire on one emit.
  local lua_fired = 0
  events.on("turn:end", function() lua_fired = lua_fired + 1 end)
  got = nil
  events.emit("turn:end", { session = 8 })
  eq(lua_fired, 1, "bridge: the in-process handler still fires")
  ok(got ~= nil, "bridge: the bus mirror fires alongside the handler")

  bus.unsubscribe(id)
  events.clear()
  ok(events.any("turn:end") == false, "bridge: any() false again after both are gone")
end

-- ---- cleanup ---------------------------------------------------------------
os.getenv = real_getenv -- luacheck: ignore
events.clear()
auth.clear()
if bog.db then bog.db:close() end
sys.rmtree(bog.userdir)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
return failed == 0 and 0 or 1
