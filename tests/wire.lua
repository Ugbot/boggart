-- tests/wire.lua -- the OpenAI Responses-API wire adapter, in isolation.
--
-- The Responses API differs from chat-completions enough that the encode/decode
-- pair is worth checking without a live endpoint: system -> instructions, the
-- transcript -> an `input` array that splices function_call / function_call_output
-- items in transcript order, FLAT tools, reasoning.effort, and a TYPED SSE stream
-- decoded back into Anthropic content-blocks. Run: boggart --eval tests/wire.lua
local api = require("api")
local json = require("json")

local fails = 0
local function check(ok, msg)
  if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end
end

-- ---- encode: Anthropic body -> Responses request ---------------------------
local body = {
  model = "gpt-5-sol", max_tokens = 256, stream = true,
  system = "You are terse.", reasoning_effort = "high", temperature = 0.3,
  messages = {
    { role = "user", content = "search for cats" },
    { role = "assistant", content = {
        { type = "text", text = "on it" },
        { type = "tool_use", id = "call_1", name = "web", input = { q = "cats" } },
    } },
    { role = "user", content = {
        { type = "tool_result", tool_use_id = "call_1", content = "found 3" },
    } },
    { role = "user", content = "thanks" },
  },
  tools = {
    { name = "web", description = "search", input_schema = {
        type = "object",
        properties = { q = { type = "string" }, ids = { type = "array" } },
        required = { "q" } } },
  },
}

local r = api._to_responses_body(body)
check(r.instructions == "You are terse.", "system -> instructions")
check(r.model == "gpt-5-sol", "model carried through")
check(r.max_output_tokens == 256, "max_tokens -> max_output_tokens")
check(r.store == false, "store forced false")
check(r.stream == true, "stream carried through")
check(type(r.reasoning) == "table" and r.reasoning.effort == "high", "reasoning.effort set")
check(r.temperature == 0.3, "temperature carried through")

-- input items, in transcript order: user, assistant text, function_call,
-- function_call_output, user.
local it = r.input
check(#it == 5, "input has 5 items (got " .. #it .. ")")
check(it[1].role == "user" and it[1].content == "search for cats", "item1 user text")
check(it[2].role == "assistant" and it[2].content == "on it", "item2 assistant text")
check(it[3].type == "function_call" and it[3].call_id == "call_1"
  and it[3].name == "web", "item3 function_call")
check(it[3].arguments and json.decode(it[3].arguments).q == "cats", "item3 args JSON-encoded")
check(it[4].type == "function_call_output" and it[4].call_id == "call_1"
  and it[4].output == "found 3", "item4 function_call_output")
check(it[5].role == "user" and it[5].content == "thanks", "item5 user text")

-- tools: FLAT ({type,name,description,parameters}); array field gets `items`.
check(type(r.tools) == "table" and #r.tools == 1, "one tool")
local t = r.tools[1]
check(t.type == "function" and t.name == "web", "tool is flat function")
check(t.parameters and t.parameters.properties.ids.items ~= nil,
  "array param gains items (norm_schema)")

-- a bodyless-system / no-tools request must omit those keys, not send nil/empty.
local bare = api._to_responses_body({ model = "m", max_tokens = 8, messages = {
  { role = "user", content = "hi" } } })
check(bare.instructions == nil, "no system -> no instructions key")
check(bare.tools == nil, "no tools -> no tools key")
check(bare.reasoning == nil, "no effort -> no reasoning key")

-- ---- decode: typed SSE -> assistant message --------------------------------
-- A text-only stream.
local function feed_all(dec, frames)
  for _, f in ipairs(frames) do dec.feed("data: " .. json.encode(f) .. "\n") end
end

local d1 = api._new_responses_decoder(nil)
feed_all(d1, {
  { type = "response.output_text.delta", delta = "Hel" },
  { type = "response.output_text.delta", delta = "lo" },
  { type = "response.completed", response = { usage = { input_tokens = 5, output_tokens = 2 } } },
})
local m1, stop1, err1 = d1.finish()
check(err1 == nil, "text stream: no error")
check(stop1 == "end_turn", "text stream: end_turn")
check(#m1.content == 1 and m1.content[1].type == "text" and m1.content[1].text == "Hello",
  "text stream: assembled text")
check(m1.usage.input_tokens == 5 and m1.usage.output_tokens == 2, "usage captured")

-- A reasoning + tool-call stream (arguments streamed in fragments by item_id).
local d2 = api._new_responses_decoder(nil)
feed_all(d2, {
  { type = "response.reasoning_text.delta", delta = "think..." },
  { type = "response.output_item.added",
    item = { type = "function_call", id = "fc_1", call_id = "call_9", name = "web" } },
  { type = "response.function_call_arguments.delta", item_id = "fc_1", delta = '{"q":"c' },
  { type = "response.function_call_arguments.delta", item_id = "fc_1", delta = 'ats"}' },
  { type = "response.output_item.done",
    item = { type = "function_call", id = "fc_1", call_id = "call_9", name = "web" } },
  { type = "response.completed", response = { usage = { input_tokens = 9, output_tokens = 4 } } },
})
local m2, stop2, err2 = d2.finish()
check(err2 == nil, "tool stream: no error")
check(stop2 == "tool_use", "tool stream: stop_reason tool_use")
local thinking = m2.content[1]
check(thinking and thinking.type == "thinking" and thinking.thinking == "think...",
  "tool stream: thinking block first")
local tu = m2.content[#m2.content]
check(tu.type == "tool_use" and tu.id == "call_9" and tu.name == "web",
  "tool stream: tool_use block")
check(type(tu.input) == "table" and tu.input.q == "cats", "tool stream: args parsed")

-- A failed stream surfaces an error, not a silent empty turn.
local d3 = api._new_responses_decoder(nil)
feed_all(d3, {
  { type = "response.output_text.delta", delta = "partial" },
  { type = "response.failed", response = { error = { message = "boom" } } },
})
local _, _, err3 = d3.finish()
check(err3 ~= nil and err3:find("boom", 1, true), "failed stream surfaces error")

-- on_text callback fires per delta (the live-typing path).
local seen = {}
local d4 = api._new_responses_decoder(function(s) seen[#seen + 1] = s end)
feed_all(d4, {
  { type = "response.output_text.delta", delta = "a" },
  { type = "response.output_text.delta", delta = "b" },
})
d4.finish()
check(#seen == 2 and seen[1] == "a" and seen[2] == "b", "on_text fires per delta")

-- SSE frames split across feed() calls must still parse (partial-line buffering).
local d5 = api._new_responses_decoder(nil)
local line = "data: " .. json.encode({ type = "response.output_text.delta", delta = "XY" }) .. "\n"
d5.feed(line:sub(1, 10))
d5.feed(line:sub(11))
local m5 = d5.finish()
check(m5.content[1].text == "XY", "split-frame buffering")

if fails == 0 then
  io.write("ok  wire: all assertions passed\n")
else
  io.write(string.format("FAILED: %d assertion(s)\n", fails)); os.exit(1)
end
