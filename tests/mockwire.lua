-- tests/mockwire.lua -- the deterministic transport really is deterministic.
--
-- run_on has THREE model-call sites: the turn itself, context compaction, and
-- auto-dispatch. A "no network" test is only honest if ALL of them route through
-- the injected mock (opts.stream) -- a compaction that quietly fell back to
-- stream_async would make a live call in the middle of a "deterministic" run.
-- This locks that in. Run: boggart --eval tests/mockwire.lua
bog.store.open()

local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end

-- A scripted transport that counts every call. Nothing here touches the wire.
local calls = 0
local function mock(_body, sink)
  calls = calls + 1
  if sink then sink("x") end
  return { role = "assistant", content = { { type = "text", text = "x" } },
           usage = { output_tokens = 3 } }, "end_turn"
end

-- Force compaction on the first round (tiny limit + several messages) so the
-- compaction call fires. If M.compact honoured only stream_async, that call
-- would go to the live endpoint and `calls` would be short by one.
local sess = { id = 5, model = "mock", messages = {},
               max_tokens = 100, context_limit = 1, compact_ratio = 0.00001 }
for i = 1, 6 do
  sess.messages[i] = { role = (i % 2 == 1) and "user" or "assistant",
                       content = "lorem ipsum text number " .. i }
end

-- Enable dispatch too: it must be SKIPPED under a scripted transport (assess +
-- delegate are real model calls), not silently run.
if bog.dispatch and bog.dispatch.set_enabled then pcall(bog.dispatch.set_enabled, true) end

local _, stop = bog.api.run_on(sess, "hello", nil, {
  stream = mock, run_id = 5,
  system = function() return "" end, tools = function() return {} end })

ck(stop == "end_turn", "run completed via the mock (got " .. tostring(stop) .. ")")
ck(calls >= 2, "compaction AND the turn both went through the mock (calls=" .. calls .. ", want >=2)")

if fails == 0 then
  io.write("ok  mockwire: deterministic run makes zero real model calls (turn + compaction + dispatch)\n")
else
  io.write(string.format("FAILED: %d assertion(s)\n", fails)); os.exit(1)
end
