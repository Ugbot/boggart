-- tests/compact_long_turn.lua -- compaction must shrink a single long turn.
--
-- An agent working one task makes many tool calls inside one turn: the only
-- plain-text user message is the task, and every later user message carries
-- tool results. Compaction has to make that conversation smaller, or a long
-- task crosses the threshold, "compacts", and grows anyway until the
-- provider refuses the request.
-- Run: boggart --eval tests/compact_long_turn.lua
bog.store.open()

local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end

local function size(msgs)
  local json = require("json")
  return #json.encode(msgs)
end

local summary_calls, summary_body = 0, nil
local function mock(body, sink)
  summary_calls = summary_calls + 1
  summary_body = body
  local text = "SUMMARY: read the files, ran the tests, two fail in parser.c"
  if sink then sink(text) end
  return { role = "assistant", content = { { type = "text", text = text } },
           usage = { output_tokens = 20 } }, "end_turn"
end

local filler = string.rep("output line from a tool call\n", 400)  -- ~12 KB per result
local sess = { id = 7, model = "mock", messages = {
  { role = "user", content = "Fix the failing tests in this repository." } } }
for i = 1, 30 do
  local id = "call_" .. i
  sess.messages[#sess.messages + 1] = { role = "assistant", content = {
    { type = "text", text = "Running step " .. i },
    { type = "tool_use", id = id, name = "bash", input = { command = "make test " .. i } } } }
  sess.messages[#sess.messages + 1] = { role = "user", content = {
    { type = "tool_result", tool_use_id = id, content = filler } } }
end

local before_n, before_size = #sess.messages, size(sess.messages)
local ok = bog.api.compact(sess, { stream = mock, system = function() return "" end })

ck(ok == true, "compaction ran")
ck(summary_calls == 1, "one summary call (got " .. summary_calls .. ")")
ck(size(sess.messages) < before_size / 2,
   string.format("conversation at least halves: %d -> %d bytes", before_size, size(sess.messages)))
ck(#sess.messages < before_n,
   string.format("fewer messages: %d -> %d", before_n, #sess.messages))
local first = sess.messages[1]
ck(first and first.role == "user" and type(first.content) == "string"
   and first.content:find("SUMMARY:", 1, true) ~= nil, "first message carries the summary")
ck(first and first.content:find("Fix the failing tests", 1, true) ~= nil, "the task text survives")

-- Every tool_result left must answer a tool_use still present (no orphan halves).
local uses = {}
for _, m in ipairs(sess.messages) do
  if type(m.content) == "table" then
    for _, b in ipairs(m.content) do
      if b.type == "tool_use" then uses[b.id] = true end
      if b.type == "tool_result" then ck(uses[b.tool_use_id], "tool_result " .. tostring(b.tool_use_id) .. " has its tool_use") end
    end
  end
end


-- ---- what was kept ---------------------------------------------------------------
local window = require("window")
local json = require("json")
local keep = window.keep_budget(bog.api.compact_threshold(sess))
ck(window.tokens_of(sess.messages, 2) <= keep,
   string.format("kept tail within the budget: %d <= %d tokens", window.tokens_of(sess.messages, 2), keep))
ck(sess.messages[2] == nil or sess.messages[2].role == "assistant", "kept tail starts with an assistant turn")
for i = 2, #sess.messages do
  ck(sess.messages[i].role ~= sess.messages[i - 1].role, "roles alternate at message " .. i)
end

-- ---- no compaction loop -------------------------------------------------------
-- Straight after compacting, nothing new has happened: asking again must not
-- spend another model call, whatever the size estimate says.
local calls_before = summary_calls
ck(bog.api.maybe_compact(sess, { stream = mock, system = function() return "" end }) == false,
   "maybe_compact right after a compaction does nothing")
sess.compact_ratio = 0.000001   -- even when the threshold says compact at once
ck(bog.api.maybe_compact(sess, { stream = mock, system = function() return "" end }) == false,
   "...even with a threshold the kept tail is over")
sess.compact_ratio = nil
ck(summary_calls == calls_before, "no further summary call")
ck(sess.usage == nil or sess.usage.last_input == nil, "the stale measurement is forgotten")

-- ---- the summary request is valid on both wires --------------------------------------
-- The conversation ended on a user tool_result message; the compaction prompt
-- must join it rather than follow it as a second user message.
do
  local msgs = summary_body and summary_body.messages or {}
  for i = 2, #msgs do
    ck(msgs[i].role ~= msgs[i - 1].role, "summary request: roles alternate at " .. i)
  end
  local last = msgs[#msgs]
  ck(last and last.role == "user" and json.encode(last.content):find("context-compaction", 1, true),
     "summary request ends with the compaction prompt on the user turn")
  ck(last and type(last.content) == "table" and last.content[1].type == "tool_result",
     "...carried with the tool results it follows")
  local oa = bog.api._body_for_wire("openai", summary_body or { messages = {} }).messages
  for i = 2, #oa do
    ck(not (oa[i].role == "user" and oa[i - 1].role == "user"), "openai wire: no two user messages in a row at " .. i)
    if oa[i].role == "tool" then
      ck(oa[i - 1].role == "assistant" or oa[i - 1].role == "tool", "openai wire: a tool message follows its call at " .. i)
    end
  end
  ck(oa[#oa].role == "user" and oa[#oa].content:find("context-compaction", 1, true)
     and oa[#oa - 1].role == "tool", "openai wire: tool results, then the compaction prompt as the user turn")
end

-- ---- the threshold ---------------------------------------------------------------
local function thr(limit, ratio)
  return bog.api.compact_threshold({ model = "mock", messages = {}, context_limit = limit, compact_ratio = ratio })
end
ck(thr(200000) == 170000, "200k window compacts at 170k (15% buffer), got " .. thr(200000))
ck(thr(100000) == 84000, "100k window compacts at 84k (16k minimum buffer), got " .. thr(100000))
ck(thr(1000000) == 850000, "1M window compacts at 850k, got " .. thr(1000000))
ck(thr(24000) == 12000, "a small window never compacts before half of it, got " .. thr(24000))
ck(thr(200000, 0.3) == 60000, "a session's compact_ratio still overrides, got " .. thr(200000, 0.3))

-- ---- the measured size counts what arrived after it -------------------------------------
do
  local s = { model = "mock", context_limit = 200000, messages = {
    { role = "user", content = "q" }, { role = "assistant", content = "a" } },
    usage = { last_input = 100000, last_input_n = 2 } }
  s.messages[3] = { role = "user", content = { { type = "tool_result", tool_use_id = "x",
                    content = string.rep("y", 400000) } } }
  local used, how = bog.api.context_used(s)
  ck(how == "measured" and used >= 100000 + 100000, "tool results after the measurement are added: " .. used)
end

-- ---- a long run through the turn loop --------------------------------------------------
-- A scripted model that keeps calling a tool whose result is ~3,000 tokens, on
-- a 60k window, reporting the prompt it was sent. The turn must finish, every
-- request must fit the window, compaction must actually shrink what is sent,
-- and the request text must survive repeated compactions without nesting.
do
  local WIN, rounds, compactions, biggest = 60000, 0, 0, 0
  local result = string.rep("output line from a tool call\n", 400)
  local function prompt_of(body)
    return #json.encode({ system = body.system, messages = body.messages, tools = body.tools }) // 4
  end
  local function model(body, sink)
    local p = prompt_of(body)
    biggest = math.max(biggest, p)
    ck(p + body.max_tokens <= WIN, string.format("request fits the window: %d + %d", p, body.max_tokens))
    if json.encode(body.messages[#body.messages]):find("context-compaction request", 1, true) then
      compactions = compactions + 1
      return { role = "assistant", content = { { type = "text", text = "SUMMARY " .. compactions } },
               usage = { input_tokens = p, output_tokens = 10 } }, "end_turn"
    end
    rounds = rounds + 1
    if rounds > 40 then
      return { role = "assistant", content = { { type = "text", text = "finished" } },
               usage = { input_tokens = p, output_tokens = 2 } }, "end_turn"
    end
    return { role = "assistant", content = { { type = "tool_use", id = "c" .. rounds, name = "bash",
             input = { command = "step " .. rounds } } }, usage = { input_tokens = p, output_tokens = 9 } }, "tool_use"
  end
  local s = { id = 77, model = "mock", context_limit = WIN, messages = {} }
  local _, stop = bog.api.run_on(s, "Port the parser to the new grammar.", nil, {
    stream = model, system = function() return "" end,
    tools = function() return { { name = "bash", description = "run", input_schema = { type = "object" } } } end,
    run_tool = function() return result end })
  ck(stop == "end_turn", "the long turn finished (" .. tostring(stop) .. ")")
  ck(compactions >= 2, "it compacted more than once (" .. compactions .. ")")
  ck(compactions <= rounds // 3, string.format("but not every round (%d compactions in %d rounds)", compactions, rounds))
  ck(biggest <= bog.api.compact_threshold(s) + 8000,
     string.format("the conversation stayed near the threshold (%d tokens at most)", biggest))
  local first = s.messages[1].content
  local _, n_req = first:gsub("Port the parser", "")
  local _, n_pre = first:gsub("Earlier conversation compacted", "")
  ck(n_req == 1 and n_pre == 1, string.format("one request, one summary after repeated compactions (%d, %d)", n_req, n_pre))
end

if fails == 0 then
  io.write("ok  compact_long_turn: compaction shrinks a single long tool-call turn\n")
else
  io.write(string.format("FAIL compact_long_turn: %d check(s) failed\n", fails))
  os.exit(1)
end
