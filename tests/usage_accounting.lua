-- tests/usage_accounting.lua -- what a model call reports is what gets counted.
--
--   * reasoning tokens (Chat Completions completion_tokens_details, Responses
--     output_tokens_details) are recorded per call and summed on sess.usage;
--   * a reply cut at the reply limit that also called a tool still runs its
--     tools (stop tool_use) but keeps the fact that it was cut;
--   * an endpoint that reported no usage is "not reported", not zero tokens --
--     and does not wipe the last measured prompt size.
-- Run: boggart --eval tests/usage_accounting.lua
bog.store.open()
local json = require("json")
local api = bog.api

local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end
-- run ids unique to this run: the store (and its records) outlives a run under ctest
local RUN = string.format("%d-%d", os.time(), math.random(1, 1e9))

local function sse(events)
  local out = {}
  for _, e in ipairs(events) do out[#out + 1] = "data: " .. json.encode(e) .. "\n\n" end
  return table.concat(out)
end
local function decode(new, events)
  if not new then ck(false, "decoder not exposed for tests"); return { content = {}, usage = {} }, nil end
  local d = new(nil, nil)
  d.feed(sse(events) .. "data: [DONE]\n\n")
  return d.finish()
end

-- ---- the decoders ----------------------------------------------------------------
do -- Chat Completions: reasoning tokens
  local msg = decode(api._new_openai_decoder, {
    { choices = { { delta = { content = "hi" } } } },
    { choices = { { delta = {}, finish_reason = "stop" } } },
    { choices = {}, usage = { prompt_tokens = 500, completion_tokens = 200,
        completion_tokens_details = { reasoning_tokens = 120 } } },
  })
  ck(msg.usage and msg.usage.reasoning_tokens == 120,
     "chat: reasoning tokens read (got " .. tostring(msg.usage and msg.usage.reasoning_tokens) .. ")")
  ck(msg.usage and msg.usage.output_tokens == 200 and msg.usage.input_tokens == 500, "chat: in/out as before")
end
do -- Responses: reasoning tokens
  local msg = decode(api._new_responses_decoder, {
    { type = "response.output_text.delta", delta = "hi" },
    { type = "response.completed", response = { usage = { input_tokens = 300, output_tokens = 90,
        output_tokens_details = { reasoning_tokens = 64 } } } },
  })
  ck(msg.usage and msg.usage.reasoning_tokens == 64,
     "responses: reasoning tokens read (got " .. tostring(msg.usage and msg.usage.reasoning_tokens) .. ")")
end
do -- Chat Completions: cut at the limit while calling a tool
  local msg, stop = decode(api._new_openai_decoder, {
    { choices = { { delta = { tool_calls = { { index = 0, id = "c1",
        ["function"] = { name = "bash", arguments = "{\"command\":\"ls\"}" } } } } } } },
    { choices = { { delta = {}, finish_reason = "length" } } },
    { choices = {}, usage = { prompt_tokens = 10, completion_tokens = 5 } },
  })
  ck(stop == "tool_use", "chat: a cut reply with a tool call still runs the tool (" .. tostring(stop) .. ")")
  ck(msg.cut == true, "chat: ...and remembers it was cut at the limit")
end
do -- Responses: an incomplete response cut at max_output_tokens
  local msg, stop = decode(api._new_responses_decoder, {
    { type = "response.output_text.delta", delta = "partial" },
    { type = "response.incomplete", response = { incomplete_details = { reason = "max_output_tokens" },
        usage = { input_tokens = 30, output_tokens = 40 } } },
  })
  ck(stop == "max_tokens", "responses: an incomplete response is a max_tokens stop (" .. tostring(stop) .. ")")
  ck(msg.cut == true, "responses: ...and marked cut")
end
do -- no usage reported at all
  local msg = decode(api._new_openai_decoder, {
    { choices = { { delta = { content = "hi" } } } },
    { choices = { { delta = {}, finish_reason = "stop" } } },
  })
  ck(msg.usage == nil, "chat: no usage reported -> no usage, not zeros (got "
     .. (msg.usage and json.encode(msg.usage) or "nil") .. ")")
  local r = decode(api._new_responses_decoder, {
    { type = "response.output_text.delta", delta = "hi" },
    { type = "response.completed", response = {} },
  })
  ck(r.usage == nil, "responses: no usage reported -> no usage")
  local a = decode(api._new_decoder, {
    { type = "message_start", message = {} },
    { type = "content_block_start", index = 0, content_block = { type = "text", text = "" } },
    { type = "content_block_delta", index = 0, delta = { type = "text_delta", text = "hi" } },
    { type = "content_block_stop", index = 0 },
    { type = "message_delta", delta = { stop_reason = "end_turn" } },
  })
  ck(a.usage == nil, "anthropic: no usage reported -> no usage")
  local z = decode(api._new_openai_decoder, {
    { choices = { { delta = { content = "hi" } } } },
    { choices = { { delta = {}, finish_reason = "stop" } } },
    { choices = {}, usage = { prompt_tokens = 0, completion_tokens = 0 } },
  })
  ck(z.usage and z.usage.input_tokens == 0, "chat: a reported zero is still a zero")
end

-- ---- through the turn loop --------------------------------------------------------
local function records(run_id)
  local out = {}
  for _, r in ipairs(bog.store.records_for(run_id) or {}) do
    if r.kind == "span:turn" then out[#out + 1] = json.decode(r.payload) end
  end
  return out
end

do -- reasoning tokens and a cut tool call, counted
  local n = 0
  local function mock(_, sink)
    n = n + 1
    if sink then sink("x") end
    if n == 1 then
      return { role = "assistant", content = { { type = "tool_use", id = "u1", name = "bash", input = {} } },
               usage = { input_tokens = 100, output_tokens = 50, reasoning_tokens = 30 }, cut = true }, "tool_use"
    end
    return { role = "assistant", content = { { type = "text", text = "done" } },
             usage = { input_tokens = 160, output_tokens = 10, reasoning_tokens = 4 } }, "end_turn"
  end
  local s = { id = 961, model = "usage-mock", messages = {}, compact_ratio = 0.99, context_limit = 100000 }
  local _, stop = api.run_on(s, "go", nil, { stream = mock, run_id = "usage-961-" .. RUN,
    system = function() return "" end, tools = function() return {} end,
    run_tool = function() return "ok" end })
  ck(stop == "end_turn" and n == 2, "the cut tool call still ran its round (" .. tostring(stop) .. ", " .. n .. " calls)")
  ck(s.usage.reasoning == 34, "sess.usage.reasoning sums the calls (got " .. tostring(s.usage.reasoning) .. ")")
  ck(s.usage.cuts == 1, "sess.usage.cuts counts the cut reply (got " .. tostring(s.usage.cuts) .. ")")
  for _, m in ipairs(s.messages) do
    ck(m.cut == nil and m.usage == nil, "annotations are stripped before the transcript")
  end
  local rec = records("usage-961-" .. RUN)
  ck(#rec == 2, "two span:turn records (got " .. #rec .. ")")
  ck(rec[1] and rec[1].reasoning_tokens == 30 and rec[2] and rec[2].reasoning_tokens == 4,
     "each record carries its reasoning tokens")
  ck(rec[1] and rec[1].cut == true and rec[1].stop == "tool_use", "the record keeps the cut beside stop=tool_use")
  ck(rec[2] and not rec[2].cut, "an uncut reply is not marked")
end

do -- an endpoint that reports no usage
  local function mock(_, sink)
    if sink then sink("x") end
    return { role = "assistant", content = { { type = "text", text = "ok" } } }, "end_turn"
  end
  local s = { id = 962, model = "usage-mock", context_limit = 100000, compact_ratio = 0.99,
    messages = { { role = "user", content = "earlier" },
                 { role = "assistant", content = { { type = "text", text = "reply" } } } },
    usage = { input = 5000, output = 100, cached = 0, cache_write = 0, turns = 1,
              last_input = 5000, last_input_n = 2 } }
  api.run_on(s, "next", nil, { stream = mock, run_id = "usage-962-" .. RUN,
    system = function() return "" end, tools = function() return {} end })
  ck(s.usage.last_input == 5000 and s.usage.last_input_n == 2,
     "no usage: the last measurement stands (last_input " .. tostring(s.usage.last_input) .. ")")
  local used, how = api.context_used(s)
  ck(how == "measured" and used > 5000, "...and the new messages are estimated on top of it")
  ck(s.usage.turns == 2, "the call is still counted (turns " .. tostring(s.usage.turns) .. ")")
  ck(s.usage.unreported == 1, "...as one without usage (unreported " .. tostring(s.usage.unreported) .. ")")
  local rec = records("usage-962-" .. RUN)
  ck(rec[1] and rec[1].usage_reported == false and rec[1].in_tokens == nil and rec[1].out_tokens == nil,
     "the record says usage was not reported rather than 0 tokens")
end

if fails == 0 then
  io.write("ok  usage_accounting: reasoning tokens, cut replies and unreported usage\n")
else
  io.write(string.format("FAIL usage_accounting: %d check(s) failed\n", fails))
  os.exit(1)
end
