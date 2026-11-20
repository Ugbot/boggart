-- tests/reply_limit.lua -- the reply limit a request asks for.
--
-- Precedence: the session's own setting, then the catalog's longest reply for
-- the model, then 16,000. Then, per request, lowered to the room left in the
-- context window (never below 1,024), so a provider that enforces
-- prompt + max_tokens <= window never receives a request it must refuse.
-- Run: boggart --eval tests/reply_limit.lua
bog.store.open()
local json = require("json")
local window = require("window")

local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end

-- A scripted transport that records every request body and reports a prompt
-- size the way a server would (here: the same chars/4 rule, so the numbers
-- below are exact rather than approximate).
local bodies = {}
local function mock(body, sink)
  bodies[#bodies + 1] = body
  if sink then sink("ok") end
  return { role = "assistant", content = { { type = "text", text = "ok" } },
           usage = { input_tokens = 10, output_tokens = 2 } }, "end_turn"
end
local NO_TOOLS = function() return {} end
local function turn(sess, text, system)
  bodies = {}
  local _, stop = bog.api.run_on(sess, text or "hello", nil, {
    stream = mock, system = function() return system or "" end, tools = NO_TOOLS })
  ck(stop == "end_turn", "turn completed (" .. tostring(stop) .. ")")
  return bodies[#bodies]
end
local function fresh(t)
  t.messages = t.messages or {}
  t.compact_ratio = t.compact_ratio or 0.99   -- keep compaction out of the way
  return t
end

-- ---- precedence -------------------------------------------------------------
do
  local b = turn(fresh{ id = 801, model = "uncatalogued-model", context_limit = 200000 })
  ck(b.max_tokens == 16000, "no setting, no catalog entry: 16000 (got " .. tostring(b.max_tokens) .. ")")
end

require("catalog").import({
  providers = { replytest = { url = "http://127.0.0.1:9", wire = "anthropic" } },
  models = { ["long-reply-model"] = { provider = "replytest", context = 200000, max_output = 64000 } },
}, "test")
do
  local b = turn(fresh{ id = 802, model = "long-reply-model", context_limit = 200000 })
  ck(b.max_tokens == 64000, "the catalog's longest reply is used (got " .. tostring(b.max_tokens) .. ")")
  local b2 = turn(fresh{ id = 803, model = "long-reply-model", context_limit = 200000, max_tokens = 8000 })
  ck(b2.max_tokens == 8000, "an explicit session setting beats the catalog (got " .. tostring(b2.max_tokens) .. ")")
end

-- ---- lowered to the room left ----------------------------------------------
do
  -- The last request measured 45,000 tokens in a 50,000 window: about 5,000
  -- are left, minus the new user message (estimated, with margin).
  local sess = fresh{ id = 804, model = "uncatalogued-model", context_limit = 50000,
    messages = { { role = "user", content = "earlier" },
                 { role = "assistant", content = { { type = "text", text = "reply" } } } },
    usage = { input = 0, output = 0, cached = 0, cache_write = 0, turns = 1,
              last_input = 45000, last_input_n = 2 } }
  local b = turn(sess, "next question")
  local newer = window.tokens(sess.messages[3])   -- the new user message
  local expect = 50000 - 45000 - math.ceil(newer * window.ESTIMATE_MARGIN)
    - window.framing_of(sess.messages, 3, 3) - window.reply_safety(50000)
  ck(b.max_tokens == expect, string.format("room = window - measured - newer estimate - safety (want %d, got %s)",
    expect, tostring(b.max_tokens)))
  ck(45000 + newer + b.max_tokens <= 50000, "prompt + max_tokens fits the window")
end
do
  local sess = fresh{ id = 805, model = "uncatalogued-model", context_limit = 50000, compact_ratio = 0.999,
    messages = { { role = "user", content = "earlier" },
                 { role = "assistant", content = { { type = "text", text = "reply" } } } },
    usage = { input = 0, output = 0, cached = 0, cache_write = 0, turns = 1,
              last_input = 49400, last_input_n = 2 } }
  local b = turn(sess, "next")
  -- Less than the 1,024-token floor is left: the request compacts rather than
  -- ask for a reply that would overshoot the window (tests/window_guard.lua).
  ck(sess.usage.compactions == 1, "a window too full for the floor compacts first")
  ck(b.max_tokens >= 1024, "and the reply is never below 1024 (got " .. tostring(b.max_tokens) .. ")")
  local small = fresh{ id = 806, model = "uncatalogued-model", context_limit = 50000, max_tokens = 100 }
  ck(turn(small, "x").max_tokens == 100, "a session asking for less than the floor gets what it asked for")
end
do
  -- Nothing measured yet: the whole request is estimated -- the system prompt
  -- and tool schemas included, which are not in sess.messages.
  local system = string.rep("s", 4 * 40000)                -- ~40,000 tokens of system prompt
  local b = turn(fresh{ id = 807, model = "uncatalogued-model", context_limit = 50000 }, "go", system)
  local prompt = #json.encode({ system = b.system, messages = b.messages, tools = b.tools }) // 4
  ck(b.max_tokens < 10000, "an unmeasured large prompt lowers the limit (got " .. tostring(b.max_tokens) .. ")")
  ck(prompt + b.max_tokens <= 50000, string.format("estimated prompt %d + max_tokens %d fits 50000",
    prompt, b.max_tokens))
end

-- ---- a multi-round run never overflows a strict window ----------------------
do
  -- The mock reports the prompt it was sent (chars/4) and asks for a tool on
  -- each of 12 rounds; each result is ~2,500 tokens. Every request must fit.
  local WIN = 60000
  local filler = string.rep("tool output line\n", 600)
  local rounds, worst = 0, 0
  local function strict(body, sink)
    rounds = rounds + 1
    local prompt = #json.encode({ system = body.system, messages = body.messages, tools = body.tools }) // 4
    worst = math.max(worst, prompt + body.max_tokens)
    ck(prompt + body.max_tokens <= WIN, string.format("round %d: %d + %d > %d", rounds, prompt, body.max_tokens, WIN))
    if json.encode(body.messages[#body.messages]):find("context-compaction request", 1, true) then  -- the compaction call
      return { role = "assistant", content = { { type = "text", text = "summary" } },
               usage = { input_tokens = prompt, output_tokens = 5 } }, "end_turn"
    end
    if rounds >= 14 then
      return { role = "assistant", content = { { type = "text", text = "done" } },
               usage = { input_tokens = prompt, output_tokens = 2 } }, "end_turn"
    end
    return { role = "assistant", content = { { type = "tool_use", id = "t" .. rounds, name = "bash",
               input = { command = "ls" } } }, usage = { input_tokens = prompt, output_tokens = 9 } }, "tool_use"
  end
  local sess = { id = 808, model = "long-reply-model", context_limit = WIN, messages = {} }
  local _, stop = bog.api.run_on(sess, "work", nil, {
    stream = strict, system = function() return "" end,
    tools = function() return { { name = "bash", description = "run", input_schema = { type = "object" } } } end,
    run_tool = function() return filler end })
  ck(stop == "end_turn", "strict-window run completed (" .. tostring(stop) .. ")")
  ck(worst > 0 and worst <= WIN, "worst prompt + max_tokens " .. worst .. " <= " .. WIN)
end

-- ---- ...counting the wire framing, as a real endpoint does --------------------
do
  -- A real endpoint counts the whole request: roles, tool-call ids, the JSON
  -- around every block. tokens_of() counts only the content, so after the
  -- first measured call the estimate of newer messages ran low, and an
  -- endpoint's own count put prompt + max_tokens tens of tokens over the
  -- window (4531 + 35515 = 40046 > 40000 in the run that found it). Here the
  -- mock counts chars/4 of the whole encoded body, framing included, reports
  -- that as the measured input, and each round's tool result is short, so the
  -- framing is most of what each round adds.
  local WIN = 40000
  local rounds, worst = 0, 0
  local function framed(body, sink)
    rounds = rounds + 1
    local prompt = #json.encode(body) // 4
    worst = math.max(worst, prompt + body.max_tokens)
    ck(prompt + body.max_tokens <= WIN, string.format("framed round %d: %d + %d = %d > %d",
      rounds, prompt, body.max_tokens, prompt + body.max_tokens, WIN))
    if rounds >= 10 then
      return { role = "assistant", content = { { type = "text", text = "done" } },
               usage = { input_tokens = prompt, output_tokens = 2 } }, "end_turn"
    end
    return { role = "assistant", content = { { type = "tool_use",
               id = string.format("toolu_01%022d", rounds), name = "bash",
               input = { command = "ls" } } }, usage = { input_tokens = prompt, output_tokens = 9 } }, "tool_use"
  end
  local sess = { id = 809, model = "long-reply-model", context_limit = WIN, messages = {} }
  local _, stop = bog.api.run_on(sess, "work", nil, {
    stream = framed, system = function() return string.rep("system prompt ", 2000) end,
    tools = function() return { { name = "bash", description = "run", input_schema = { type = "object" } } } end,
    run_tool = function() return "ok" end })
  ck(stop == "end_turn", "framed strict-window run completed (" .. tostring(stop) .. ")")
  ck(rounds >= 10, "the framed run made every round (" .. rounds .. ")")
  ck(worst > 0 and worst <= WIN, "framed: worst prompt + max_tokens " .. worst .. " <= " .. WIN)
end

if fails == 0 then
  io.write("ok  reply_limit: session > catalog > 16000, lowered to the room left in the window\n")
else
  io.write(string.format("FAIL reply_limit: %d check(s) failed\n", fails))
  os.exit(1)
end
