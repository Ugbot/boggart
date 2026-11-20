-- tests/window_guard.lua -- no request goes out that the window cannot hold.
--
-- Before a model request is sent, its estimated prompt is checked against the
-- context window. Over it: compact first; still over (or compaction failed):
-- shrink the largest tool results to a shaped head (the full output saved to
-- a file the model can read); still over: end the turn with a clear error.
-- A request the endpoint must refuse is never sent.
--
-- The scripted model here plays a strict endpoint: it measures each request
-- (chars/4 of the whole body) and records any that would not fit.
-- Run: boggart --eval tests/window_guard.lua
bog.store.open()
local json = require("json")
local api = bog.api

local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end

local function prompt_of(body)
  return #json.encode({ system = body.system, messages = body.messages, tools = body.tools }) // 4
end
local function is_compaction(body)
  return json.encode(body.messages[#body.messages]):find("context-compaction request", 1, true) ~= nil
end
local TOOLS = function() return { { name = "bash", description = "run", input_schema = { type = "object" } } } end

-- A strict endpoint on a `win`-token window. Round 1 calls a tool; after that it
-- answers. `on_compact(body)` may replace the summary reply (or raise).
local function endpoint(win, label, on_compact)
  local st = { calls = 0, over = 0, compactions = 0, rounds = 0 }
  st.fn = function(body, sink)
    st.calls = st.calls + 1
    local p = prompt_of(body)
    if p > win then
      st.over = st.over + 1
      ck(false, string.format("%s: a %d-token request was sent to a %d-token window", label, p, win))
    end
    if is_compaction(body) then
      st.compactions = st.compactions + 1
      if on_compact then return on_compact(body, p) end
      return { role = "assistant", content = { { type = "text", text = "SUMMARY: listed the files" } },
               usage = { input_tokens = p, output_tokens = 10 } }, "end_turn"
    end
    st.rounds = st.rounds + 1
    if sink then sink("x") end
    if st.rounds == 1 then
      return { role = "assistant", content = { { type = "tool_use", id = "big1", name = "bash",
               input = { command = "cat huge.json" } } }, usage = { input_tokens = p, output_tokens = 9 } }, "tool_use"
    end
    return { role = "assistant", content = { { type = "text", text = "done" } },
             usage = { input_tokens = p, output_tokens = 2 } }, "end_turn"
  end
  return st
end

local HUGE = string.rep("x", 400000)   -- one tool result of ~100k tokens, on one line

-- ---- over the window: compact first ----------------------------------------------
do
  local WIN = 50000
  local ep = endpoint(WIN, "compact")
  -- compact_ratio 5: the threshold rule never fires, so only the guard can act
  local s = { id = 971, model = "guard-model", context_limit = WIN, compact_ratio = 5, messages = {} }
  local ok, err = pcall(api.run_on, s, "list everything", nil, {
    stream = ep.fn, system = function() return "" end, tools = TOOLS,
    run_tool = function() return HUGE end })
  ck(ok, "the turn completed (" .. tostring(err) .. ")")
  ck(ep.over == 0, "no over-window request was sent (" .. ep.over .. ")")
  ck(ep.compactions >= 1, "the guard compacted (" .. ep.compactions .. " compactions)")
  ck(ep.rounds == 2, "and the model got its second round (" .. ep.rounds .. ")")
end

-- ---- graph memory: the guard compacts into the graph, no model call ------------------
-- With BOGGART_MEMORY=local (sess.memory) compaction collapses the old part
-- into records and an outline instead of asking a model for a summary. The
-- guard must still keep every request inside the window, and the compaction
-- it triggers must not reach the endpoint at all.
do
  local WIN = 50000
  local ep = endpoint(WIN, "graph")
  local events = require("events")
  local modes = {}
  local unsub = events.on("context:compacted", function(_, e) modes[#modes + 1] = e.mode end)
  local s = { id = 975, model = "guard-model", context_limit = WIN, compact_ratio = 5,
              memory = "local", messages = {} }
  local ok, err = pcall(api.run_on, s, "list everything", nil, {
    stream = ep.fn, system = function() return "" end, tools = TOOLS,
    run_tool = function() return HUGE end })
  events.off(unsub)
  ck(ok, "graph: the turn completed (" .. tostring(err) .. ")")
  ck(ep.over == 0, "graph: no over-window request was sent (" .. ep.over .. ")")
  ck(ep.compactions == 0, "graph: compaction made no model call (" .. ep.compactions .. ")")
  ck(#modes >= 1 and modes[1] == "graph", "graph: the guard compacted into the graph ("
    .. table.concat(modes, ",") .. ")")
  ck(ep.rounds == 2, "graph: the model got its second round (" .. ep.rounds .. ")")
end

-- ---- compaction fails: shrink the largest tool results ----------------------------
do
  local WIN = 50000
  local ep = endpoint(WIN, "shrink", function() error("summary endpoint refused", 0) end)
  local s = { id = 972, model = "guard-model", context_limit = WIN, compact_ratio = 5, messages = {} }
  local ok, err = pcall(api.run_on, s, "list everything", nil, {
    stream = ep.fn, system = function() return "" end, tools = TOOLS,
    run_tool = function() return HUGE end })
  ck(ok, "the turn completed without compaction (" .. tostring(err) .. ")")
  ck(ep.over == 0, "no over-window request was sent (" .. ep.over .. ")")
  ck(ep.rounds == 2, "the model got its second round (" .. ep.rounds .. ")")
  local res
  for _, m in ipairs(s.messages) do
    if type(m.content) == "table" then
      for _, b in ipairs(m.content) do if b.type == "tool_result" and b.tool_use_id == "big1" then res = b end end
    end
  end
  local text = res and (type(res.content) == "string" and res.content or json.encode(res.content)) or ""
  ck(res and #text < 10000, "the huge result was shrunk to its head (" .. #text .. " bytes)")
  local path = text:match("Full output saved to (%S+) ")
  local f = path and io.open(path, "rb")
  local whole = f and f:read("a"); if f then f:close() end
  ck(whole == HUGE, "the full output is in the file the shaped head names (" .. tostring(path) .. ")")
end

-- ---- nothing helps: a clear error, nothing sent ------------------------------------
do
  local WIN = 50000
  local ep = endpoint(WIN, "error")
  local s = { id = 973, model = "guard-model", context_limit = WIN, messages = {} }
  local system = string.rep("rules ", 50000)  -- ~75k tokens of system prompt
  local ok, err = pcall(api.run_on, s, "hi", nil, {
    stream = ep.fn, system = function() return system end, tools = TOOLS,
    run_tool = function() return "ok" end })
  ck(not ok, "the turn ends with an error")
  ck(api.is_error(err) and err.kind == "context_window",
     "a context_window error (got " .. tostring(api.is_error(err) and err.kind or err) .. ")")
  ck(tostring(err):find("window", 1, true) ~= nil, "the message names the window: " .. tostring(err):sub(1, 160))
  ck(tostring(err):find("compaction failed", 1, true) ~= nil, "and why compaction did not help")
  ck(ep.over == 0, "no over-window request was sent (" .. ep.over .. ")")
end

-- ---- the reply floor never pushes a request over ------------------------------------
-- The reply limit is lowered to the room left, but never below 1,024 tokens
-- (window.REPLY_MIN). With less room than that, the floor itself used to push
-- prompt + max_tokens over the window. Now the request compacts first.
do
  local WIN = 50000
  local s
  local over, compactions = 0, 0
  local function mock(body, sink)
    if is_compaction(body) then
      compactions = compactions + 1
      return { role = "assistant", content = { { type = "text", text = "SUMMARY" } },
               usage = { input_tokens = 100, output_tokens = 5 } }, "end_turn"
    end
    local est = api.request_prompt_tokens(s, body)
    if est + body.max_tokens > WIN then
      over = over + 1
      ck(false, string.format("floor: estimated prompt %d + max_tokens %d > %d", est, body.max_tokens, WIN))
    end
    if sink then sink("ok") end
    return { role = "assistant", content = { { type = "text", text = "ok" } },
             usage = { input_tokens = est, output_tokens = 2 } }, "end_turn"
  end
  -- 49,400 of 50,000 measured; the threshold (compact_ratio 0.999) is not
  -- reached, but less than 1,024 tokens of room is left.
  s = { id = 974, model = "guard-model", context_limit = WIN, compact_ratio = 0.999,
    messages = { { role = "user", content = "earlier" },
                 { role = "assistant", content = { { type = "text", text = "reply" } } } },
    usage = { input = 0, output = 0, cached = 0, cache_write = 0, turns = 1,
              last_input = 49400, last_input_n = 2 } }
  local ok, err = pcall(api.run_on, s, "next", nil, { stream = mock,
    system = function() return "" end, tools = function() return {} end })
  ck(ok, "the nearly-full turn completed (" .. tostring(err) .. ")")
  ck(over == 0, "no request overshot the window (" .. over .. ")")
  ck(compactions == 1, "it compacted instead (" .. compactions .. ")")
end

if fails == 0 then
  io.write("ok  window_guard: compact, then shrink, then refuse -- never send an over-window request\n")
else
  io.write(string.format("FAIL window_guard: %d check(s) failed\n", fails))
  os.exit(1)
end
