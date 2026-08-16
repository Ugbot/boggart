-- integration.lua -- OFFLINE integration tests for the full agent turn loop
-- in lua/api.lua. Run via `./boggart --eval tests/integration.lua`.
--
-- No network is used: the C `http.begin` binding is replaced with a Lua stub
-- that replays canned Anthropic SSE streams one chunk per req:take(), split at
-- hostile byte boundaries (including mid-`data:`-line) to prove the
-- chunk-boundary buffering in api.stream_async is correct. There is one
-- transport now (async), so each turn runs as a scheduler coroutine driven to
-- completion here by run_turn_sync -- exactly how it runs in production.
local json = require("json")
local util = require("util")

-- ---- tiny assert harness ---------------------------------------------------
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else
    failed = failed + 1
    io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n")
  end
end

-- ---- isolate state: fresh temp userdir, clean registry ----------------------
bog.userdir = os.tmpname() .. "_boggart_itest"
sys.mkdir_p(bog.userdir .. "/lua/tools")
-- re-wire so tools/memory re-scan under the fresh userdir (drops any tools
-- the real ~/.boggart may have contributed at boot)
ok(bog.reload(), "harness reload against temp userdir")

-- ---- offline auth: never consult the real env or `ant` ---------------------
-- Credentials live in C (src/lauth.c) and are not readable from Lua, so a
-- stubbed os.getenv no longer reaches them. Set one for real; HOME is a temp
-- dir here so nothing escapes the test.
auth.set("api_key", "sk-ant-offline-test-key")

-- (historical) api.auth_headers() read ANTHROPIC_API_KEY via os.getenv and shelled out to
-- `ant` when it is missing. Stub os.getenv so the test is hermetic either way.
local real_getenv = os.getenv
os.getenv = function(name) -- luacheck: ignore
  if name == "ANTHROPIC_API_KEY" then return "sk-ant-offline-test-key" end
  return real_getenv(name)
end

-- ---- SSE fixture builders ---------------------------------------------------
local function ev(etype, tbl)
  return "event: " .. etype .. "\ndata: " .. json.encode(tbl) .. "\n\n"
end

local function message_start()
  return "event: message_start\ndata: " .. json.encode({
    type = "message_start",
    message = {
      id = "msg_test", type = "message", role = "assistant", content = {},
      model = bog.session.model, usage = { input_tokens = 10, output_tokens = 1 },
    },
  }) .. "\n\n"
end

local function text_block(index, pieces)
  local out = { ev("content_block_start", {
    type = "content_block_start", index = index,
    content_block = { type = "text", text = "" },
  }) }
  for _, p in ipairs(pieces) do
    out[#out + 1] = ev("content_block_delta", {
      type = "content_block_delta", index = index,
      delta = { type = "text_delta", text = p },
    })
  end
  out[#out + 1] = ev("content_block_stop", { type = "content_block_stop", index = index })
  return table.concat(out)
end

-- tool_use block whose input JSON arrives as input_json_delta fragments
local function tool_block(index, id, name, json_pieces)
  local out = { ev("content_block_start", {
    type = "content_block_start", index = index,
    content_block = { type = "tool_use", id = id, name = name, input = {} },
  }) }
  for _, p in ipairs(json_pieces) do
    out[#out + 1] = ev("content_block_delta", {
      type = "content_block_delta", index = index,
      delta = { type = "input_json_delta", partial_json = p },
    })
  end
  out[#out + 1] = ev("content_block_stop", { type = "content_block_stop", index = index })
  return table.concat(out)
end

local function finish(stop_reason)
  return ev("message_delta", {
    type = "message_delta", delta = { stop_reason = stop_reason },
    usage = { output_tokens = 42 },
  }) .. ev("message_stop", { type = "message_stop" })
end

local function plain_text_response(text_pieces, stop)
  return message_start() .. text_block(0, text_pieces) .. finish(stop or "end_turn")
end

-- ---- the http.begin stub ---------------------------------------------------
-- Splits the next canned SSE stream into small, deliberately awkward chunks and
-- hands them out one per req:take() -- the async transport's contract. The
-- scheduler yields "io", we pump (a no-op here -- no real transfers), and the
-- transport drains the chunks. Same hostile boundaries as before, so the
-- chunk-boundary buffering is exercised identically.
local sched = require("sched")
bog.sched = sched
local queue = {}          -- pending canned SSE bodies
local requests = {}       -- decoded request bodies, for wire-shape asserts
local mid_data_splits = 0 -- count of chunk boundaries that landed inside a data: line

local function chunk_sse(sse)
  local sizes = { 7, 3, 29, 11, 41, 5, 17 }
  local chunks, i, k = {}, 1, 1
  while i <= #sse do
    local n = sizes[(k - 1) % #sizes + 1]
    local last = math.min(#sse, i + n - 1)
    -- did this boundary land strictly inside a `data:` line?
    if last < #sse then
      local prev_nl = sse:sub(1, last):match("()\n[^\n]*$")
      local ls = prev_nl and (prev_nl + 1) or 1
      if ls <= last and sse:sub(ls, ls + 4) == "data:"
          and sse:find("\n", last + 1, true) then
        mid_data_splits = mid_data_splits + 1
      end
    end
    chunks[#chunks + 1] = sse:sub(i, last)
    i = last + 1
    k = k + 1
  end
  return chunks
end

http.pump = function() return 0 end -- no real transfers; the stub feeds via take()
http.begin = function(opts)
  assert(type(opts) == "table", "stub: opts must be a table")
  assert(opts.url and opts.method == "POST", "stub: unexpected request shape")
  requests[#requests + 1] = json.decode(opts.body)
  local sse = table.remove(queue, 1)
  if not sse then
    error("stub: http.begin called with empty response queue (runaway loop?)")
  end
  local req = { chunks = chunk_sse(sse), idx = 0 }
  function req:take()
    self.idx = self.idx + 1
    return self.chunks[self.idx] or ""
  end
  function req:status()
    if self.idx >= #self.chunks then return "done", 200 end
    return "running"
  end
  function req:close() end
  return req
end

-- Drive one default-session turn to completion under the scheduler -- the same
-- coroutine-on-the-loop shape every front end uses. Errors are re-raised so the
-- error-path scenarios still see them.
local function run_turn_sync(text, on_text)
  local err
  local co = coroutine.create(function()
    local ok2, e = pcall(bog.api.run_turn, text, on_text)
    if not ok2 then err = e end
  end)
  sched.actors, sched.by_id = {}, {}
  sched.add(bog.session.id or 9000, co)
  sched.run()
  if err then error(err, 0) end
end

-- Drive run_on on an arbitrary session/opts to completion under the scheduler
-- (for the durability scenarios, which use throwaway sessions + a spy checkpoint).
local function run_on_sync(sess, text, opts, on_text)
  local err
  local co = coroutine.create(function()
    local ok2, e = pcall(bog.api.run_on, sess, text, on_text, opts)
    if not ok2 then err = e end
  end)
  sched.actors, sched.by_id = {}, {}
  sched.add(sess.id or 9000, co)
  sched.run()
  if err then error(err, 0) end
end

-- per-scenario reset
local function begin_scenario()
  bog.session.messages = {}
  queue = {}
  requests = {}
end

-- ==========================================================================
-- Scenario 1: plain text answer, end_turn
-- ==========================================================================
do
  begin_scenario()
  queue[1] = plain_text_response({ "Hello", " from", " boggart", "!" })

  local got = {}
  run_turn_sync("say hi", function(t) got[#got + 1] = t end)

  eq(table.concat(got), "Hello from boggart!", "s1: on_text saw the concatenated text")
  eq(#bog.session.messages, 2, "s1: two messages (user, assistant)")
  eq(bog.session.messages[1].role, "user", "s1: first message is user")
  eq(bog.session.messages[1].content, "say hi", "s1: user text recorded")
  local a = bog.session.messages[2]
  eq(a.role, "assistant", "s1: second message is assistant")
  eq(type(a.content), "table", "s1: assistant content is a block array")
  eq(#a.content, 1, "s1: assistant has exactly one content block")
  eq(a.content[1].type, "text", "s1: block is a text block")
  eq(a.content[1].text, "Hello from boggart!", "s1: text block accumulated all deltas")
  eq(#queue, 0, "s1: exactly one canned response consumed")
  -- wire shape: stream request included tools + system prompt
  ok(requests[1].stream == true, "s1: request had stream=true")
  ok(type(requests[1].tools) == "table" and #requests[1].tools > 0, "s1: tools sent")
  ok(type(requests[1].system) == "table", "s1: system prompt sent")
end

-- ==========================================================================
-- Scenario 2: single tool_use round (real `write` tool side effect), then end_turn
-- ==========================================================================
do
  begin_scenario()
  local target = bog.userdir .. "/s2_out.txt"
  local input_json = json.encode({ path = target, content = "hi" })
  queue[1] = message_start()
    .. text_block(0, { "I'll write", " the file." })
    .. tool_block(1, "toolu_s2_01", "write", { input_json }) -- one whole piece here; splitting tested in s5
    .. finish("tool_use")
  queue[2] = plain_text_response({ "Done." })

  local got = {}
  run_turn_sync("write hi to a file", function(t) got[#got + 1] = t end)

  -- the tool really ran
  eq(util.read_file(target), "hi", "s2: write tool actually wrote the file")

  -- conversation shape: [user, assistant(tool_use), user(tool_result), assistant(text)]
  eq(#bog.session.messages, 4, "s2: four messages after one tool round")
  local m = bog.session.messages
  eq(m[1].role, "user", "s2: m1 role")
  eq(m[2].role, "assistant", "s2: m2 role")
  eq(m[3].role, "user", "s2: m3 role")
  eq(m[4].role, "assistant", "s2: m4 role")

  eq(#m[2].content, 2, "s2: assistant has text + tool_use blocks")
  eq(m[2].content[1].type, "text", "s2: block 1 is text")
  eq(m[2].content[2].type, "tool_use", "s2: block 2 is tool_use")
  eq(m[2].content[2].id, "toolu_s2_01", "s2: tool_use id preserved")
  eq(m[2].content[2].name, "write", "s2: tool_use name preserved")
  eq(m[2].content[2].input.path, target, "s2: tool input.path decoded")
  eq(m[2].content[2].input.content, "hi", "s2: tool input.content decoded")

  local trs = m[3].content
  eq(type(trs), "table", "s2: tool_result message content is an array")
  eq(#trs, 1, "s2: exactly one tool_result block")
  eq(trs[1].type, "tool_result", "s2: block type tool_result")
  eq(trs[1].tool_use_id, "toolu_s2_01", "s2: tool_result matches tool_use id")
  eq(trs[1].is_error, nil, "s2: is_error nil on success")
  ok(type(trs[1].content) == "string" and trs[1].content:find("^Wrote "), "s2: tool_result carries the tool output")

  eq(#m[4].content, 1, "s2: final assistant has one block")
  eq(m[4].content[1].text, "Done.", "s2: final assistant text")
  eq(#queue, 0, "s2: both canned responses consumed (loop terminated)")
  eq(#requests, 2, "s2: exactly two API calls")
  -- second request must carry the tool_result back to the API
  local req2_last = requests[2].messages[#requests[2].messages]
  eq(req2_last.role, "user", "s2: 2nd request ends with the tool_result user msg")
  eq(req2_last.content[1].type, "tool_result", "s2: 2nd request carries tool_result")
end

-- ==========================================================================
-- Scenario 3: parallel tool_use -- two tools, one assistant message,
-- both results in a SINGLE user message
-- ==========================================================================
do
  begin_scenario()
  local t1 = bog.userdir .. "/s3_a.txt"
  local t2 = bog.userdir .. "/s3_b.txt"
  queue[1] = message_start()
    .. text_block(0, { "Writing two files." })
    .. tool_block(1, "toolu_s3_01", "write", { json.encode({ path = t1, content = "alpha" }) })
    .. tool_block(2, "toolu_s3_02", "write", { json.encode({ path = t2, content = "beta" }) })
    .. finish("tool_use")
  queue[2] = plain_text_response({ "Both written." })

  run_turn_sync("write two files", nil)

  eq(util.read_file(t1), "alpha", "s3: first tool ran")
  eq(util.read_file(t2), "beta", "s3: second tool ran")
  eq(#bog.session.messages, 4, "s3: four messages (single tool round)")
  local m = bog.session.messages
  eq(#m[2].content, 3, "s3: assistant streamed text + 2 tool_use blocks")
  eq(m[2].content[2].type, "tool_use", "s3: block index 1 is tool_use")
  eq(m[2].content[3].type, "tool_use", "s3: block index 2 is tool_use")

  local trs = m[3].content
  eq(#trs, 2, "s3: BOTH tool_results in a single user message")
  eq(trs[1].tool_use_id, "toolu_s3_01", "s3: result 1 id matches")
  eq(trs[2].tool_use_id, "toolu_s3_02", "s3: result 2 id matches")
  eq(trs[1].is_error, nil, "s3: result 1 no error")
  eq(trs[2].is_error, nil, "s3: result 2 no error")
  eq(#requests, 2, "s3: exactly two API calls (parallel tools = one round)")
end

-- ==========================================================================
-- Scenario 4: tool error path -- unknown tool; loop continues, not throws
-- ==========================================================================
do
  begin_scenario()
  queue[1] = message_start()
    .. tool_block(0, "toolu_s4_01", "no_such_tool", { json.encode({ x = 1 }) })
    .. finish("tool_use")
  queue[2] = plain_text_response({ "Recovered." })

  local threw = not pcall(run_turn_sync, "call a bogus tool", nil)
  ok(not threw, "s4: run_turn does not throw on unknown tool")

  local m = bog.session.messages
  eq(#m, 4, "s4: loop continued to the follow-up round")
  local tr = m[3].content[1]
  eq(tr.type, "tool_result", "s4: error surfaced as a tool_result")
  eq(tr.tool_use_id, "toolu_s4_01", "s4: error result id matches")
  ok(tr.content:sub(1, 11) == "Tool error:", "s4: content starts with 'Tool error:'")
  eq(tr.is_error, true, "s4: is_error=true set")
  eq(m[4].content[1].text, "Recovered.", "s4: follow-up end_turn response consumed")

  -- also a real tool with bad args (write without content) -> Tool error result
  begin_scenario()
  queue[1] = message_start()
    .. tool_block(0, "toolu_s4_02", "write", { json.encode({ path = bog.userdir .. "/nope.txt" }) })
    .. finish("tool_use")
  queue[2] = plain_text_response({ "ok" })
  run_turn_sync("bad args", nil)
  local tr2 = bog.session.messages[3].content[1]
  ok(tr2.content:sub(1, 11) == "Tool error:", "s4: bad-args tool returns Tool error:")
  eq(tr2.is_error, true, "s4: bad-args is_error=true")
  eq(sys.stat(bog.userdir .. "/nope.txt"), nil, "s4: no file written on bad args")
end

-- ==========================================================================
-- Scenario 5: input_json_delta split mid-token across event AND chunk boundaries
-- ==========================================================================
do
  begin_scenario()
  local target = bog.userdir .. "/s5_out.txt"
  -- fragments split inside keys, inside string values, and inside escapes;
  -- the whole SSE byte stream is additionally re-chunked by feed_chunked.
  -- The path goes into a JSON *string*, so it has to be escaped: on Windows
  -- bog.userdir is a backslash path and the raw form would be a stream of
  -- invalid escapes. Escaping before splitting is safe precisely because the
  -- decoder reassembles every fragment before parsing -- which is the property
  -- under test.
  local esc = target:gsub("\\", "\\\\")
  local frags = {
    '{"pa', 'th', '": "', esc:sub(1, 5), esc:sub(6), '", "co',
    'nten', 't": "spl', 'it', '-ok\\', 'n"}',
  }
  queue[1] = message_start()
    .. tool_block(0, "toolu_s5_01", "write", frags)
    .. finish("tool_use")
  queue[2] = plain_text_response({ "done" })

  run_turn_sync("split json", nil)

  local tu = bog.session.messages[2].content[1]
  eq(tu.type, "tool_use", "s5: tool_use block assembled")
  eq(tu.input.path, target, "s5: fragmented input.path decoded correctly")
  eq(tu.input.content, "split-ok\n", "s5: fragmented input.content (incl. split escape) decoded")
  eq(util.read_file(target), "split-ok\n", "s5: tool ran with the reassembled input")
  eq(bog.session.messages[3].content[1].is_error, nil, "s5: tool succeeded")
end

-- ==========================================================================
-- Scenario 6: event: lines, ping, comments, empty/[DONE] data lines are ignored
-- ==========================================================================
do
  begin_scenario()
  queue[1] = message_start()
    .. "event: ping\ndata: {\"type\": \"ping\"}\n\n"
    .. ": this is an SSE comment keep-alive\n\n"
    .. text_block(0, { "Still ", "fine." })
    .. "data: \n\n"        -- empty data payload
    .. "data:\n\n"          -- data with no space, no payload
    .. "event: ping\ndata: {\"type\": \"ping\"}\n\n"
    .. finish("end_turn")
    .. "data: [DONE]\n\n"   -- OpenAI-style terminator some proxies append

  local got = {}
  run_turn_sync("noise test", function(t) got[#got + 1] = t end)

  eq(table.concat(got), "Still fine.", "s6: text intact despite ping/comment/empty-data noise")
  eq(#bog.session.messages, 2, "s6: clean [user, assistant] shape")
  eq(#bog.session.messages[2].content, 1, "s6: one text block, ping created no block")
  eq(bog.session.messages[2].content[1].text, "Still fine.", "s6: block text correct")
end

-- ==========================================================================
-- Scenario 7: a turn cancelled mid-tool leaves a dangling tool_use. The next
-- turn must REPAIR it (synthetic tool_result) instead of 400ing forever.
-- ==========================================================================
do
  begin_scenario()
  -- the corrupted transcript a Ctrl-C during a slow tool leaves behind:
  -- assistant asked for a tool, the kill happened before the result was written
  bog.session.messages = {
    { role = "user", content = "do a thing" },
    { role = "assistant", content = {
        { type = "text", text = "working" },
        { type = "tool_use", id = "toolu_dangle", name = "read", input = { path = "x" } },
    } },
  }
  queue[1] = plain_text_response({ "recovered" })
  run_turn_sync("never mind, hi", nil)

  local m = requests[1].messages
  eq(m[2].role, "assistant", "s7: assistant tool_use preserved")
  eq(m[3].role, "user", "s7: a user turn follows the tool_use (alternation kept)")
  eq(m[3].content[1].type, "tool_result", "s7: synthetic tool_result inserted")
  eq(m[3].content[1].tool_use_id, "toolu_dangle", "s7: result answers the dangling id")
  eq(m[3].content[1].is_error, true, "s7: marked interrupted/error")
  eq(m[3].content[2].type, "text", "s7: the new prompt rides the same user turn")
  eq(m[3].content[2].text, "never mind, hi", "s7: new prompt text preserved")
  local last = bog.session.messages[#bog.session.messages]
  eq(last.content[1].text, "recovered", "s7: turn recovered instead of 400ing")
end

-- ==========================================================================
-- Scenario 8: cancelled mid-stream (no assistant reply) leaves a trailing user
-- message; the next prompt must coalesce, not create two user turns (a 400).
-- ==========================================================================
do
  begin_scenario()
  bog.session.messages = { { role = "user", content = "first prompt (never answered)" } }
  queue[1] = plain_text_response({ "ok" })
  run_turn_sync("second prompt", nil)

  local m = requests[1].messages
  eq(#m, 1, "s8: consecutive user prompts coalesced into one message")
  eq(m[1].role, "user", "s8: single user turn sent")
  ok(m[1].content:find("first prompt") and m[1].content:find("second prompt"),
     "s8: both prompts present in the merged turn")
end

-- ==========================================================================
-- Scenario 9: mid-turn input injection -- text submitted while the turn runs is
-- queued on sess.inbox and folded into the NEXT request during the tool round.
-- ==========================================================================
do
  begin_scenario()
  bog.session.inbox = nil
  queue[1] = message_start()
    .. text_block(0, { "reading" })
    .. tool_block(1, "toolu_inj", "read", { json.encode({ path = bog.userdir .. "/nope" }) })
    .. finish("tool_use")
  queue[2] = plain_text_response({ "after" })

  local injected = false
  run_turn_sync("do a read", function(_)
    if not injected then -- simulate the user hitting Enter mid-turn
      bog.session.inbox = bog.session.inbox or {}
      bog.session.inbox[#bog.session.inbox + 1] = "stop and summarize"
      injected = true
    end
  end)

  local m2 = requests[2].messages
  local last = m2[#m2]
  eq(last.role, "user", "s9: 2nd request ends with a user turn")
  local saw = false
  for _, b in ipairs(last.content) do
    if b.type == "text" and b.text:find("summarize") then saw = true end
  end
  ok(saw, "s9: injected steering text rode the next request alongside the tool result")
  ok(#bog.session.inbox == 0, "s9: the inbox was drained")
end

-- ==========================================================================
-- Scenario 10: durable checkpointing -- the checkpoint hook fires after the
-- assistant message and around every tool call (intent + result).
-- ==========================================================================
do
  begin_scenario()
  local target = bog.userdir .. "/s10.txt"
  queue[1] = message_start()
    .. tool_block(0, "toolu_s10", "write", { json.encode({ path = target, content = "x" }) })
    .. finish("tool_use")
  queue[2] = plain_text_response({ "ok" })

  local sess = { id = 9100, model = bog.session.model, messages = {}, max_tokens = 16000 }
  local ck = 0
  run_on_sync(sess, "write x", { checkpoint = function() ck = ck + 1 end }, nil)
  -- round1 assistant + tool intent + tool result + round2 assistant = 4
  eq(ck, 4, "s10: checkpoint fired per assistant msg and around the tool call")
  eq(util.read_file(target), "x", "s10: the tool actually ran")
end

-- ==========================================================================
-- Scenario 11: resume a turn interrupted BEFORE a tool started -- the tool must
-- run now and the turn continue to completion.
-- ==========================================================================
do
  begin_scenario()
  local target = bog.userdir .. "/s11.txt"
  local sess = { id = 9101, model = bog.session.model, max_tokens = 16000, messages = {
    { role = "user", content = "write it" },
    { role = "assistant", content = {
        { type = "tool_use", id = "toolu_s11", name = "write",
          input = { path = target, content = "resumed" } },
    } },
  } }
  queue[1] = plain_text_response({ "done after resume" })

  run_on_sync(sess, nil, {}, nil) -- nil user_text == resume/continue

  eq(util.read_file(target), "resumed", "s11: the never-started tool ran on resume")
  local m = sess.messages
  eq(m[3].role, "user", "s11: tool_result user turn inserted")
  eq(m[3].content[1].type, "tool_result", "s11: result block present")
  eq(m[3].content[1].tool_use_id, "toolu_s11", "s11: result answers the tool_use")
  eq(m[3].content[1].is_error, nil, "s11: tool succeeded on resume")
  eq(m[#m].content[1].text, "done after resume", "s11: turn ran to completion")
end

-- ==========================================================================
-- Scenario 12: resume a turn interrupted WHILE a tool was in flight -- the
-- in-flight tool (a `pending` marker) must NOT re-run (its side effect may be
-- half-applied); it is answered as interrupted and the turn continues.
-- ==========================================================================
do
  begin_scenario()
  local target = bog.userdir .. "/s12.txt"
  local sess = { id = 9102, model = bog.session.model, max_tokens = 16000, messages = {
    { role = "user", content = "do it" },
    { role = "assistant", content = {
        { type = "tool_use", id = "toolu_s12", name = "write",
          input = { path = target, content = "SHOULD NOT WRITE" } },
    } },
    { role = "user", content = {
        { type = "tool_result", tool_use_id = "toolu_s12", content = "", pending = true },
    } },
  } }
  queue[1] = plain_text_response({ "acknowledged" })

  run_on_sync(sess, nil, {}, nil)

  eq(sys.stat(target), nil, "s12: the in-flight tool was NOT re-run (no file written)")
  local tr = sess.messages[3].content[1]
  eq(tr.pending, nil, "s12: pending marker finalized")
  eq(tr.content, "[interrupted]", "s12: in-flight tool answered as interrupted")
  eq(tr.is_error, true, "s12: marked as error")
  eq(sess.messages[#sess.messages].content[1].text, "acknowledged", "s12: turn continued")
end

-- ---- meta: the chunker really did split inside data: lines ------------------
ok(mid_data_splits > 0,
  string.format("chunker split inside a data: line at least once (%d times)", mid_data_splits))

-- ---- cleanup ----------------------------------------------------------------
os.getenv = real_getenv -- luacheck: ignore
sys.rmtree(bog.userdir) -- not a shell command: cmd.exe has no rm

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
return failed == 0 and 0 or 1
