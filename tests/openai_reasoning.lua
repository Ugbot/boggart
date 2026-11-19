-- openai_reasoning.lua -- a reasoning model's earlier reasoning goes back to it.
--
-- OpenAI-compatible servers stream reasoning in one of two fields:
-- `reasoning_content` (llama.cpp, SGLang, vLLM's older name, DeepInfra) or
-- `reasoning` (vLLM's newer name, the Hugging Face router, OpenRouter), the
-- latter often with structured `reasoning_details`. Chat templates for the
-- reasoning families (Qwen, DeepSeek, GLM) read `reasoning_content` on prior
-- assistant messages, and the routers read `reasoning`/`reasoning_details`.
-- A harness that drops it makes the model re-derive its plan every call.
--
-- These tests pin the whole loop offline: streamed chunks in -> a thinking
-- block that remembers where it came from -> the next request carries it back
-- in that same field; the per-route withhold flag; the other wires' handling of
-- such a block; and the block surviving checkpoint + resume.
local api = bog.api or require("api")
local json = require("json")

local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local function eq(a, b, n)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", n, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

-- Feed SSE frames (each a Lua table, or a raw string) through the decoder.
local function decode(frames, opts)
  local seen = {}
  local dec = api._openai_decoder(nil, function(t) seen[#seen + 1] = t end)
  for _, f in ipairs(frames) do
    local data = type(f) == "string" and f or json.encode(f)
    -- split each frame across two chunks to exercise line buffering
    local line = "data: " .. data .. "\n\n"
    local cut = math.floor(#line / 2)
    dec.feed(line:sub(1, cut)); dec.feed(line:sub(cut + 1))
  end
  if not (opts and opts.no_done) then dec.feed("data: [DONE]\n\n") end
  local msg, stop, err = dec.finish()
  return msg, stop, err, table.concat(seen)
end

local function delta(d, finish)
  return { choices = { { index = 0, delta = d, finish_reason = finish } } }
end

local function block(msg, t)
  for _, b in ipairs(msg.content) do if b.type == t then return b end end
end

local function body(msgs) return { model = "m", max_tokens = 100, messages = msgs, stream = true } end

-- the assistant message the decoder produced, in a transcript that continues
local function next_request(amsg, rt)
  amsg.usage = nil
  return api._body_for_wire("openai", body{
    { role = "user", content = "list the files" },
    amsg,
    { role = "user", content = { { type = "tool_result", tool_use_id = "call_1", content = "a.txt" } } },
  }, rt)
end

local tool_frame = delta{ tool_calls = { { index = 0, id = "call_1", type = "function",
  ["function"] = { name = "ls", arguments = "{}" } } } }

-- ---- reasoning_content (llama.cpp / SGLang / DeepInfra) --------------------
do
  local msg, stop, err, live = decode{
    delta{ role = "assistant", reasoning_content = "I should " },
    delta{ reasoning_content = "call ls." },
    tool_frame,
    delta({}, "tool_calls"),
  }
  eq(err, nil, "reasoning_content: no stream error")
  eq(stop, "tool_use", "reasoning_content: tool stop")
  local th = block(msg, "thinking")
  ok(th ~= nil, "reasoning_content: a thinking block is produced")
  eq(th and th.thinking, "I should call ls.", "reasoning_content: text accumulated")
  eq(th and th.reasoning_field, "reasoning_content", "reasoning_content: source field recorded")
  eq(th and th.signature, nil, "reasoning_content: no signature is invented")
  eq(live, "I should call ls.", "reasoning_content: streamed live to on_think")

  local out = next_request(msg)
  local a = out.messages[2]
  eq(a.role, "assistant", "round trip: assistant message present")
  eq(a.reasoning_content, "I should call ls.", "round trip: reasoning goes back as reasoning_content")
  eq(a.reasoning, nil, "round trip: not duplicated into `reasoning`")
  eq(a.reasoning_details, nil, "round trip: no reasoning_details invented")
  eq(a.tool_calls and a.tool_calls[1].id, "call_1", "round trip: tool call kept alongside")
  eq(out.messages[3].role, "tool", "round trip: tool result follows")
  -- the encoded body really carries it (what goes on the wire)
  ok(json.encode(out):find('"reasoning_content":"I should call ls."', 1, true) ~= nil,
     "round trip: encoded body carries reasoning_content")
end

-- ---- reasoning (+ reasoning_details) (HF router / OpenRouter / new vLLM) ---
do
  local msg = decode{
    delta{ role = "assistant", reasoning = "Plan: ",
           reasoning_details = { { type = "reasoning.text", text = "Plan: ", index = 0, format = "unknown" } } },
    delta{ reasoning = "use ls.",
           reasoning_details = { { type = "reasoning.text", text = "use ls.", index = 0 } } },
    delta{ reasoning_details = { { type = "reasoning.text", signature = "sig-xyz", index = 0 } } },
    delta{ reasoning_details = { { type = "reasoning.encrypted", data = "ENC==", index = 1 } } },
    tool_frame,
    delta({}, "tool_calls"),
  }
  local th = block(msg, "thinking")
  eq(th and th.thinking, "Plan: use ls.", "reasoning: text accumulated")
  eq(th and th.reasoning_field, "reasoning", "reasoning: source field recorded")
  local det = th and th.reasoning_details or {}
  eq(#det, 2, "reasoning_details: fragments merged by index (2 entries)")
  eq(det[1] and det[1].text, "Plan: use ls.", "reasoning_details: text fragments concatenated")
  eq(det[1] and det[1].signature, "sig-xyz", "reasoning_details: late signature attached")
  eq(det[1] and det[1].format, "unknown", "reasoning_details: other fields kept")
  eq(det[2] and det[2].type, "reasoning.encrypted", "reasoning_details: distinct index kept separate")
  eq(det[2] and det[2].data, "ENC==", "reasoning_details: encrypted data kept")

  local a = next_request(msg).messages[2]
  eq(a.reasoning, "Plan: use ls.", "round trip: reasoning goes back in `reasoning`")
  eq(a.reasoning_content, nil, "round trip: not duplicated into reasoning_content")
  eq(type(a.reasoning_details), "table", "round trip: reasoning_details sent back")
  eq(a.reasoning_details and #a.reasoning_details, 2, "round trip: all details")
  eq(a.reasoning_details and a.reasoning_details[2].data, "ENC==", "round trip: details verbatim")
end

-- ---- a delta carrying BOTH fields with the same text is not double-counted --
do
  local msg = decode{
    delta{ reasoning_content = "once", reasoning = "once" },
    delta{ content = "done" },
    delta({}, "stop"),
  }
  local th = block(msg, "thinking")
  eq(th and th.thinking, "once", "both fields: counted once")
  eq(th and th.reasoning_field, "reasoning_content", "both fields: reasoning_content preferred")
end

-- ---- details only (no plain-text reasoning field) --------------------------
do
  local msg = decode{
    delta{ reasoning_details = { { type = "reasoning.summary", summary = "Short plan.", index = 0 } } },
    delta{ content = "ok" },
    delta({}, "stop"),
  }
  local th = block(msg, "thinking")
  ok(th ~= nil, "details only: a thinking block is still produced")
  eq(th and th.thinking, "Short plan.", "details only: readable text taken from the summary")
  eq(th and th.reasoning_field, nil, "details only: no text field recorded")
  local a = api._body_for_wire("openai", body{ { role = "user", content = "q" }, msg })
    .messages[2]
  eq(a.reasoning_content, nil, "details only: no reasoning_content synthesised")
  eq(a.reasoning, nil, "details only: no reasoning synthesised")
  eq(a.reasoning_details and a.reasoning_details[1].summary, "Short plan.",
     "details only: details go back verbatim")
end

-- ---- null fields are ignored ----------------------------------------------
do
  local msg = decode{
    '{"choices":[{"index":0,"delta":{"content":"hi","reasoning_content":null,"reasoning":null,"reasoning_details":null}}]}',
    delta({}, "stop"),
  }
  eq(block(msg, "thinking"), nil, "null reasoning fields: no thinking block")
  eq(block(msg, "text").text, "hi", "null reasoning fields: text intact")
end

-- ---- non-streamed response (a server that ignores stream=true) -------------
do
  local dec = api._openai_decoder(nil, nil)
  dec.feed(json.encode{
    id = "x", object = "chat.completion",
    choices = { { index = 0, finish_reason = "tool_calls", message = {
      role = "assistant", content = "",
      reasoning = "whole plan",
      reasoning_details = { { type = "reasoning.text", text = "whole plan", index = 0 },
                            { type = "reasoning.text", text = "second", index = 0 } },
      tool_calls = { { id = "c1", type = "function", ["function"] = { name = "ls", arguments = "{}" } },
                     { id = "c2", type = "function", ["function"] = { name = "pwd", arguments = "{}" } } },
    } } },
    usage = { prompt_tokens = 10, completion_tokens = 5 },
  })
  dec.feed("\n")
  local msg, stop = dec.finish()
  local th = block(msg, "thinking")
  eq(th and th.thinking, "whole plan", "non-streamed: reasoning read from message")
  eq(th and th.reasoning_field, "reasoning", "non-streamed: source field recorded")
  eq(th and th.reasoning_details and #th.reasoning_details, 2,
     "non-streamed: reasoning_details kept verbatim (not merged)")
  local n = 0; for _, b in ipairs(msg.content) do if b.type == "tool_use" then n = n + 1 end end
  eq(n, 2, "non-streamed: both tool calls (no index field) kept separate")
  eq(stop, "tool_use", "non-streamed: tool stop")
  eq(msg.usage.output_tokens, 5, "non-streamed: usage read")
end
do
  local dec = api._openai_decoder(nil, nil)
  dec.feed(json.encode{ choices = { { index = 0, finish_reason = "stop", message = {
    role = "assistant", content = "answer", reasoning_content = "rc plan" } } } })
  local msg = dec.finish()
  eq(block(msg, "thinking").reasoning_field, "reasoning_content", "non-streamed: reasoning_content")
  eq(block(msg, "text").text, "answer", "non-streamed: text")
end

-- ---- foreign / legacy thinking blocks on the OpenAI wire --------------------
do
  local out = api._body_for_wire("openai", body{
    { role = "user", content = "q" },
    { role = "assistant", content = {   -- stored before the field was recorded
        { type = "thinking", thinking = "legacy" }, { type = "text", text = "a" } } },
    { role = "user", content = "q2" },
    { role = "assistant", content = {   -- Anthropic-signed: a different protocol's reasoning
        { type = "thinking", thinking = "claude", signature = "sig" }, { type = "text", text = "b" } } },
    { role = "user", content = "q3" },
    { role = "assistant", content = {
        { type = "redacted_thinking", data = "opaque" }, { type = "text", text = "c" } } },
  })
  eq(out.messages[2].reasoning_content, "legacy", "legacy unsigned block: echoed as reasoning_content (default)")
  eq(out.messages[4].reasoning_content, nil, "signed Anthropic block: not echoed on the OpenAI wire")
  eq(out.messages[4].reasoning, nil, "signed Anthropic block: not echoed as reasoning either")
  eq(out.messages[6].reasoning_content, nil, "redacted_thinking: never echoed")
  eq(out.messages[6].content, "c", "redacted_thinking: text intact")
end
do
  -- an unknown recorded field falls back to the default rather than inventing one
  local out = api._body_for_wire("openai", body{ { role = "user", content = "q" },
    { role = "assistant", content = { { type = "thinking", thinking = "x", reasoning_field = "bogus" } } } })
  eq(out.messages[2].reasoning_content, "x", "unknown recorded field: default reasoning_content")
  eq(out.messages[2].bogus, nil, "unknown recorded field: never sent")
end
do
  -- reasoning never rides on a user message
  local out = api._body_for_wire("openai", body{ { role = "user", content = {
    { type = "thinking", thinking = "x" }, { type = "text", text = "q" } } } })
  eq(out.messages[1].reasoning_content, nil, "user message: no reasoning field")
end

-- ---- withhold flag ---------------------------------------------------------
do
  local msg = decode{ delta{ reasoning = "secret plan",
    reasoning_details = { { type = "reasoning.text", text = "secret plan", index = 0 } } },
    tool_frame, delta({}, "tool_calls") }
  local function copy(m) return json.decode(json.encode(m)) end
  local held = next_request(copy(msg), { wire = "openai", reasoning_echo = false }).messages[2]
  eq(held.reasoning, nil, "reasoning_echo=false: reasoning withheld")
  eq(held.reasoning_content, nil, "reasoning_echo=false: reasoning_content withheld")
  eq(held.reasoning_details, nil, "reasoning_echo=false: reasoning_details withheld")
  eq(held.tool_calls and held.tool_calls[1].id, "call_1", "reasoning_echo=false: the rest unchanged")
  local sent = next_request(copy(msg), { wire = "openai", reasoning_echo = true }).messages[2]
  eq(sent.reasoning, "secret plan", "reasoning_echo=true: sent")
  local dflt = next_request(copy(msg), { wire = "openai" }).messages[2]
  eq(dflt.reasoning, "secret plan", "reasoning_echo unset: sent (default on)")
end

-- ---- the other wires: an OpenAI-wire thinking block is never leaked --------
do
  local msgs = {
    { role = "user", content = "q" },
    { role = "assistant", content = {
        { type = "thinking", thinking = "qwen plan", reasoning_field = "reasoning",
          reasoning_details = { { type = "reasoning.text", text = "qwen plan" } } },
        { type = "tool_use", id = "call_1", name = "ls", input = {} } } },
    { role = "user", content = { { type = "tool_result", tool_use_id = "call_1", content = "a" } } },
    { role = "assistant", content = {
        { type = "thinking", thinking = "real", signature = "abc" }, { type = "text", text = "done" } } },
  }
  local an = api._body_for_wire("anthropic", { model = "claude-sonnet-5", max_tokens = 100, messages = msgs })
  eq(#an.messages[2].content, 1, "anthropic: unsigned OpenAI-wire thinking dropped")
  eq(an.messages[2].content[1].type, "tool_use", "anthropic: the tool_use survives")
  eq(an.messages[4].content[1].signature, "abc", "anthropic: a signed block goes back unchanged")
  eq(an.messages[4].content[1].thinking, "real", "anthropic: signed block text unchanged")
  local enc = json.encode(an)
  ok(not enc:find("reasoning_field", 1, true), "anthropic: no reasoning_field leaks")
  ok(not enc:find("reasoning_details", 1, true), "anthropic: no reasoning_details leaks")
  ok(not enc:find("reasoning_echo", 1, true), "anthropic: no reasoning_echo leaks")

  local rs = api._body_for_wire("responses", { model = "gpt-5.6-sol", max_tokens = 100, messages = msgs })
  local renc = json.encode(rs)
  ok(not renc:find("qwen plan", 1, true), "responses: OpenAI-wire reasoning not sent")
  ok(not renc:find("reasoning_details", 1, true), "responses: no reasoning_details leaks")
  ok(not renc:find("reasoning_field", 1, true), "responses: no reasoning_field leaks")
  local calls = 0
  for _, it in ipairs(rs.input) do if it.type == "function_call" then calls = calls + 1 end end
  eq(calls, 1, "responses: the tool call still goes")
end

-- ---- checkpoint + resume keeps the block and its source field --------------
do
  bog.userdir = os.tmpname() .. "_boggart_oair"
  sys.mkdir_p(bog.userdir)
  if bog.db then bog.db:close() end
  bog.db = nil
  bog.store.open()

  local msg = decode{ delta{ reasoning = "keep me",
    reasoning_details = { { type = "reasoning.encrypted", data = "E1", index = 0 } } },
    tool_frame, delta({}, "tool_calls") }
  msg.usage = nil
  local id = bog.store.sess_create("oai reasoning", "m")
  bog.store.sess_save(id, "oai reasoning", "m", {
    { role = "user", content = "list" },
    msg,
    { role = "user", content = { { type = "tool_result", tool_use_id = "call_1", content = "a.txt" } } },
    { role = "assistant", content = {   -- Anthropic-signed: still scrubbed on resume
        { type = "thinking", thinking = "signed", signature = "stale" }, { type = "text", text = "ok" } } },
  })
  ok(bog.resume_session(id), "resume: session loads")
  local m2 = bog.session.messages[2]
  local th = m2 and block(m2, "thinking")
  ok(th ~= nil, "resume: the OpenAI-wire thinking block survives")
  eq(th and th.thinking, "keep me", "resume: its text survives")
  eq(th and th.reasoning_field, "reasoning", "resume: its source field survives")
  eq(th and th.reasoning_details and th.reasoning_details[1].data, "E1", "resume: its details survive")
  eq(#bog.session.messages[4].content, 1, "resume: a signed block is still scrubbed")

  local out = api._body_for_wire("openai", body(bog.session.messages))
  eq(out.messages[2].reasoning, "keep me", "resume: the next request carries it back")
  eq(out.messages[2].reasoning_details[1].data, "E1", "resume: with its details")

  -- a model swap still scrubs every thinking block: another model's reasoning
  -- is not this model's own
  bog.session.model = "m"
  bog.set_model("other-model")
  ok(block(bog.session.messages[2], "thinking") == nil, "model swap: OpenAI-wire thinking scrubbed")
  bog.store.sess_delete(id)
end

io.write(failed == 0 and ("openai_reasoning: all " .. passed .. " passed\n")
                      or ("openai_reasoning: " .. failed .. " FAILED, " .. passed .. " passed\n"))
os.exit(failed == 0 and 0 or 1)
