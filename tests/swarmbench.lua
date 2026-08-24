-- tests/swarmbench.lua -- the reliability scoreboard, made deterministic.
--
-- This reproduces the failure that motivated the whole reliability layer: a
-- 14-agent fan-out where most agents produce NOTHING, the swarm reports success,
-- and it self-certifies "clean". It runs entirely on the scripted mock stream
-- (opts.stream) -- no network, no model, no flake -- so it can live in CI.
--
-- What it proves: with the exit contract + telemetry, that fan-out is no longer
-- reportable as success. Every non-delivering agent is marked failed, and the
-- COMPUTED KPIs read the true deliverable rate. Run: boggart --eval tests/swarmbench.lua
bog.store.open()

local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end

local RUN = 700000 + (os.time() % 100000)

-- A scripted model that just claims completion (like the agents that "did
-- nothing" but reported done). It never actually calls a tool.
local function claims_done()
  return function(_body, sink)
    sink("all done!")
    return { role = "assistant", content = { { type = "text", text = "all done!" } },
             usage = { output_tokens = 6, input_tokens = 20 } }, "end_turn"
  end
end

-- Run one agent under the exit contract. `will_deliver` decides whether its
-- required artifact actually appears (a delivering agent writes it first).
local function run_agent(id, path, will_deliver)
  if will_deliver then local f = io.open(path, "w"); f:write("done"); f:close() end
  local rec = {
    id = id, run_id = RUN, spec_name = "coder", deliverables = { path }, max_attempts = 1,
    session = { id = id, model = "mock", messages = {}, max_tokens = 100 },
  }
  rec.opts = { run_id = RUN, stream = claims_done(),
    system = function() return "" end, tools = function() return {} end }
  bog.thread._run(rec, "produce the required artifact at " .. path)
end

-- The chapter run in miniature: 14 agents, only 3 deliver.
local N_TOTAL, N_GOOD = 14, 3
for i = 1, N_TOTAL do
  run_agent(RUN * 10 + i, string.format("/tmp/swb_%d_%d.txt", RUN, i), i <= N_GOOD)
end

local k = bog.telemetry.kpis(RUN)
ck(k.agents == N_TOTAL, "all 14 agents recorded (got " .. tostring(k.agents) .. ")")
ck(k.delivered == N_GOOD, "exactly 3 delivered (got " .. tostring(k.delivered) .. ")")
ck(math.abs((k.deliverable_rate or 0) - N_GOOD / N_TOTAL) < 0.01,
  "deliverable_rate ~ 3/14 (got " .. tostring(k.deliverable_rate) .. ")")
-- The OLD failure was reporting this as success. It is now provably NOT one:
ck((k.deliverable_rate or 1) < 0.5,
  "a mostly-failed fan-out reads as mostly-failed, never success")

io.write(string.format(
  "swarm-bench: %d/%d delivered (rate %.2f) -- the 11/14 failure is CAUGHT by measurement\n",
  k.delivered, k.agents, k.deliverable_rate or 0))

if fails == 0 then
  io.write("ok  swarmbench: chapter-run failure is caught, not narrated away\n")
else
  io.write(string.format("FAILED: %d assertion(s)\n", fails)); os.exit(1)
end
