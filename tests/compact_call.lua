-- tests/compact_call.lua -- the compaction summary call is a model call like any other.
--
--   * effort: a session that set an effort summarises at "low" (bookkeeping,
--     and reasoning tokens would come out of a short reply limit); a session
--     with no effort sends none; a route that withholds effort gets none;
--   * reply limit: 4,096 at most, never more than the session's / route's
--     reply limit, and lowered to the room the summary request leaves in the
--     summary route's window;
--   * accounting: one span:turn record marked compaction=true, and its tokens
--     added to sess.usage -- without becoming the conversation's measured size.
-- Run: boggart --eval tests/compact_call.lua
bog.store.open()
local json = require("json")
local api = bog.api
local window = require("window")

local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end
-- run ids unique to this run: the store (and its records) outlives a run under ctest
local RUN = string.format("%d-%d", os.time(), math.random(1, 1e9))

require("catalog").import({
  providers = { cctest = { url = "http://127.0.0.1:9", wire = "anthropic" } },
  models = {
    ["cc-model"] = { provider = "cctest", context = 100000, max_output = 2000, effort = true },
    ["cc-no-effort"] = { provider = "cctest", context = 100000, effort = false },
  },
}, "test")

local body_seen, route_seen
local function mock(body, _, _, route)
  body_seen, route_seen = body, route
  return { role = "assistant", content = { { type = "text", text = "SUMMARY" } },
           usage = { input_tokens = 700, output_tokens = 40, cache_read_input_tokens = 300,
                     reasoning_tokens = 12 } }, "end_turn"
end

local function conv(n, bytes)
  local msgs = { { role = "user", content = "Fix the build." } }
  for i = 1, n do
    msgs[#msgs + 1] = { role = "assistant", content = { { type = "tool_use", id = "c" .. i, name = "bash", input = { command = "make" } } } }
    msgs[#msgs + 1] = { role = "user", content = { { type = "tool_result", tool_use_id = "c" .. i,
      content = string.rep("make output line\n", (bytes or 1700) // 17) } } }
  end
  return msgs
end
local function compact(s, opts)
  opts = opts or {}
  opts.stream = mock; opts.system = opts.system or function() return "" end
  body_seen = nil
  return api.compact(s, opts)
end

-- ---- effort --------------------------------------------------------------------
do
  local s = { id = 981, model = "cc-model", effort = "high", messages = conv(4) }
  compact(s, { compact_route = "cc-model" })
  ck(body_seen and body_seen.reasoning_effort == "low",
     "a session with an effort summarises at low (got " .. tostring(body_seen and body_seen.reasoning_effort) .. ")")
  local s2 = { id = 982, model = "cc-model", messages = conv(4) }
  compact(s2, { compact_route = "cc-model" })
  ck(body_seen and body_seen.reasoning_effort == nil, "no session effort: none sent")
  local s3 = { id = 983, model = "cc-model", effort = "high", messages = conv(4) }
  compact(s3, { compact_route = "cc-no-effort" })
  ck(body_seen and body_seen.reasoning_effort == nil, "a route that withholds effort gets none")
  local s4 = { id = 984, model = "cc-model", effort = "high", compact_effort = "medium", messages = conv(4) }
  compact(s4, { compact_route = "cc-model" })
  ck(body_seen and body_seen.reasoning_effort == "medium", "sess.compact_effort overrides")
end

-- ---- reply limit -----------------------------------------------------------------
do
  local s = { id = 985, model = "cc-model", messages = conv(4) }
  compact(s, { compact_route = "cc-model" })
  ck(body_seen and body_seen.max_tokens == 2000,
     "the route's catalog reply limit (2000) caps the summary (got " .. tostring(body_seen and body_seen.max_tokens) .. ")")
  local s2 = { id = 986, model = "cc-no-effort", max_tokens = 1500, messages = conv(4) }
  compact(s2, { compact_route = "cc-no-effort" })
  ck(body_seen and body_seen.max_tokens == 1500,
     "the session's reply limit caps it (got " .. tostring(body_seen and body_seen.max_tokens) .. ")")
  local s3 = { id = 987, model = "uncatalogued-cc", messages = conv(4) }
  compact(s3, { compact_route = "uncatalogued-cc" })
  ck(body_seen and body_seen.max_tokens == 4096, "4096 when nothing lowers it (got " .. tostring(body_seen and body_seen.max_tokens) .. ")")
  -- A conversation close to the summary route's window: the reply limit is
  -- lowered to the room the summary request leaves (estimated the way every
  -- request is: content with the margin, plus framing).
  local s4 = { id = 988, model = "uncatalogued-cc", context_limit = 30000, messages = conv(13, 7000) }
  compact(s4, { compact_route = "uncatalogued-cc" })
  local m = body_seen and body_seen.messages or {}
  local est = math.ceil(window.tokens_of(m) * window.ESTIMATE_MARGIN) + window.framing_of(m)
  ck(body_seen and body_seen.max_tokens < 4096 and est + body_seen.max_tokens <= 30000,
     string.format("estimated prompt %d + max_tokens %s fits the 30000 window", est, tostring(body_seen and body_seen.max_tokens)))
end

-- ---- recorded and counted ------------------------------------------------------------
do
  local s = { id = 989, model = "cc-model", messages = conv(4),
    usage = { input = 1000, output = 100, cached = 0, cache_write = 0, turns = 3, last_input = 9000, last_input_n = 9 } }
  compact(s, { compact_route = "cc-model", run_id = "cc-989-" .. RUN })
  ck(s.usage.input == 1700 and s.usage.output == 140 and s.usage.cached == 300,
     string.format("the summary's tokens are added to sess.usage (in %d out %d cached %d)",
       s.usage.input, s.usage.output, s.usage.cached))
  ck(s.usage.reasoning == 12, "...reasoning tokens too (" .. tostring(s.usage.reasoning) .. ")")
  ck(s.usage.last_input == nil, "the summary request does not become the conversation's measured size")
  ck(s.usage.turns == 3, "the conversation's turn count is unchanged")
  local recs = {}
  for _, r in ipairs(bog.store.records_for("cc-989-" .. RUN) or {}) do
    if r.kind == "span:turn" then recs[#recs + 1] = json.decode(r.payload) end
  end
  ck(#recs == 1, "one span:turn record for the summary call (got " .. #recs .. ")")
  local r = recs[1] or {}
  ck(r.compaction == true, "marked as a compaction call")
  ck(r.model == "cc-model" and r.in_tokens == 700 and r.out_tokens == 40 and r.cache_read == 300,
     "with its model and tokens: " .. json.encode(r))
end

if fails == 0 then
  io.write("ok  compact_call: effort, reply limit and accounting of the summary call\n")
else
  io.write(string.format("FAIL compact_call: %d check(s) failed\n", fails))
  os.exit(1)
end
