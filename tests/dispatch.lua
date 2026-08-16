-- dispatch.lua -- the OPTIONAL auto-routing heuristic (lua/dispatch.lua): decide
-- whether a request is "different enough" (route mismatch AND topic shift) to be
-- worth handing to a specialist. Tests the pure heuristic; the delegation path
-- (spawn + await) reuses the swarm machinery covered in tests/swarm.lua.
local dispatch = require("dispatch")
local tools = require("tools")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

-- ---- novelty (pure lexical) ------------------------------------------------
ok(dispatch.novelty("compile the rust firmware for the board", "we edited a python web form") >= 0.9,
   "novelty: a brand-new topic scores high")
ok(dispatch.novelty("add a field to the python web form", "we edited a python web form earlier") <= 0.5,
   "novelty: a continuation scores low")
eq(dispatch.novelty("", "anything"), 0, "novelty: empty request is 0")

-- ---- toggle ----------------------------------------------------------------
dispatch.set(false); ok(not dispatch.enabled(), "disabled by default / after set(false)")
dispatch.set(true);  ok(dispatch.enabled(), "set(true) enables")
dispatch.set(false)

-- ---- assess (needs a skill corpus + the store) -----------------------------
local saved_userdir = bog.userdir
bog.userdir = os.tmpname() .. "_dispatch"
sys.mkdir_p(bog.userdir .. "/lua/skills")
package.path = bog.userdir .. "/lua/?.lua;" .. package.path
if not bog.db then pcall(bog.store.open) end

tools.run("define_skill", { name = "rust_embedded",
  description = "compile, link and flash rust firmware for microcontrollers and embedded boards",
  tools = { "bash" } })

-- Mirror run_on: the current request is appended as the last message BEFORE
-- assess runs (assess skips that last message to read the PRIOR context).
local function sess_with(prior, request)
  local msgs = {}
  for _, p in ipairs(prior) do msgs[#msgs + 1] = { role = "user", content = p } end
  msgs[#msgs + 1] = { role = "user", content = request }
  return { messages = msgs }
end

-- (a) generalist agent, novel specialised request -> delegate
local reqA = "compile and flash the rust firmware to the microcontroller board"
local a = dispatch.assess(reqA, {}, sess_with({ "we were editing a python web form earlier" }, reqA))
ok(a.delegate, "assess: delegates a novel, specialised request (both signals agree)")
eq(a.match, "rust_embedded", "assess: names the matched specialist skill")

-- (b) trivial request never delegates
ok(not dispatch.assess("thanks", {}, sess_with({}, "thanks")).delegate, "assess: trivial request stays local")
ok(not dispatch.assess("do that too", {}, sess_with({}, "do that too")).delegate,
   "assess: under MIN_WORDS stays local")

-- (c) if the current agent ALREADY holds the best-matching skill, no delegation
local held = dispatch.assess(reqA, { "rust_embedded" },
  sess_with({ "we were editing a python web form earlier" }, reqA))
ok(not held.delegate, "assess: best skill already held -> no hand-off")
ok(held.reason:find("already held"), "assess: says the skill is already held")

-- (d) same topic (low novelty) does not delegate even on a route mismatch
local reqD = "flash the rust firmware to the microcontroller again"
local same = dispatch.assess(reqD, {},
  sess_with({ "we are compiling and flashing the rust firmware to the microcontroller board" }, reqD))
ok(not same.delegate, "assess: a continuation of the same topic stays local")
ok(same.reason:find("same topic"), "assess: cites the topic-continuity reason")

sys.rmtree(bog.userdir)
bog.userdir = saved_userdir

io.write(string.format("dispatch: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
