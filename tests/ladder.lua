-- ladder.lua -- the tier ladder (lua/ladder.lua), headless.
--
-- jev is stubbed at bog.typesafe.ask, so judge.jev_only runs for real (routing,
-- key presence, confidence) with no network. Checked: a site is off until
-- switched on; code wins before jev; jev wins when sure; low confidence and jev
-- errors fall through to the llm stage; /judge off|chat drops jev; the sampled
-- agreement is recorded; stages out of cost order are refused.
local ladder = bog.ladder or require("ladder")

local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local function eq(a, b, n)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", n, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

-- hermetic config + jev stub
local kv = {}
bog.store = bog.store or {}
bog.store.kv_get = function(k) return kv[k] end
bog.store.kv_set = function(k, v) kv[k] = v end
local records = {}
bog.store.record_append = function(kind, row) records[#records + 1] = { kind = kind, row = row } end

local jev_keyed, jev_calls, jev_script = true, 0, nil
bog.typesafe = bog.typesafe or {}
bog.typesafe.available = function() return jev_keyed end
bog.typesafe.ask = function(spec)
  jev_calls = jev_calls + 1
  if jev_script then return jev_script(spec) end
  return nil, { kind = "auth", message = "stub: no jev" }
end
local function answer(choice, conf)
  return function() return { q = { type = "choice", choice = choice, confidence = conf,
    probabilities = { [choice] = conf } } }, { status = 200 } end
end

local llm_calls, llm_value = 0, "llm-says"
local function reset()
  kv = {}; jev_calls, llm_calls, jev_script, jev_keyed = 0, 0, nil, true
  records = {}
  ladder.reset()
  ladder.rand = function() return 1 end -- never sample unless a test says so
end

local function define(code_fn)
  ladder.define{ id = "t.site", help = "test", stages = {
    ladder.code(code_fn or function() return nil end),
    ladder.jev{
      state = function(ctx) return ctx.text end,
      questions = { q = { kind = "choice", instructions = "which", options = { a = "A", b = "B" } } },
      map = function(a) return a.q.choice end,
    },
    ladder.llm(function() llm_calls = llm_calls + 1; return llm_value end),
  } }
end

-- off by default: only the llm stage runs
reset(); define(function() return "code" end)
do
  local v, m = ladder.run("t.site", { text = "x" })
  eq(v, llm_value, "a site that is not switched on runs only its llm stage")
  eq(m.tier, "llm", "off site reports llm")
  eq(jev_calls, 0, "off site never touches jev")
  ok(m.enabled == false, "meta says disabled")
end

-- code wins first
reset(); define(function() return "code" end)
ladder.set_enabled("t.site", true)
do
  local v, m = ladder.run("t.site", { text = "x" })
  eq(v, "code", "code stage answers first")
  eq(m.tier, "code", "tier is code")
  eq(jev_calls, 0, "jev not consulted when code answered")
  eq(llm_calls, 0, "llm not consulted when code answered")
end

-- jev wins when sure
reset(); define()
ladder.set_enabled("t.site", true)
jev_script = answer("a", 0.95)
do
  local v, m = ladder.run("t.site", { text = "x" })
  eq(v, "a", "jev answers when confident")
  eq(m.tier, "jev", "tier is jev")
  eq(llm_calls, 0, "llm skipped")
  eq(#m.tried, 2, "code abstained then jev answered")
end

-- low confidence falls through to the llm
reset(); define()
ladder.set_enabled("t.site", true)
jev_script = answer("a", 0.40)
do
  local v, m = ladder.run("t.site", { text = "x" })
  eq(v, llm_value, "low-confidence jev falls through to llm")
  eq(m.tier, "llm", "tier is llm")
  ok(m.escalated, "escalated flagged")
  eq(m.tried[2].outcome, "below threshold", "reason recorded")
end

-- threshold is a setting
reset(); define()
ladder.set_enabled("t.site", true)
jev_script = answer("a", 0.70)
ladder.set_number("t.site", "threshold", 0.6)
do
  local v = ladder.run("t.site", { text = "x" })
  eq(v, "a", "lowering the threshold lets 0.70 through")
end

-- jev error falls through, never raises
reset(); define()
ladder.set_enabled("t.site", true)
do
  local v, m = ladder.run("t.site", { text = "x" })
  eq(v, llm_value, "jev error falls through to llm")
  eq(m.tried[2].outcome, "abstain", "error is an abstain")
  ok(m.tried[2].info ~= nil, "error text kept")
end

-- /judge off|chat drops the jev stage
reset(); define()
ladder.set_enabled("t.site", true)
jev_script = answer("a", 0.99)
kv["config.judge.backend"] = "chat"
do
  local v = ladder.run("t.site", { text = "x" })
  eq(v, llm_value, "backend chat skips jev")
  eq(jev_calls, 0, "no jev request made")
end
kv["config.judge.backend"] = nil

-- a throwing stage is an abstain
reset()
ladder.define{ id = "t.boom", stages = { ladder.code(function() error("kaboom") end),
  ladder.llm(function() return "fine" end) } }
ladder.set_enabled("t.boom", true)
do
  local v, m = ladder.run("t.boom", {})
  eq(v, "fine", "throwing stage does not stop the ladder")
  eq(m.tried[1].outcome, "error", "throw recorded")
end

-- master switch
reset(); define(function() return "code" end)
ladder.set_enabled("t.site", true)
ladder.set_master(false)
do
  local v = ladder.run("t.site", { text = "x" })
  eq(v, llm_value, "master off behaves like every site off")
end

-- sampling records agreement and keeps the routed verdict
reset(); define()
ladder.set_enabled("t.site", true)
ladder.set_number("t.site", "sample", 1)
ladder.rand = function() return 0 end
jev_script = answer("a", 0.95)
llm_value = "a"
do
  local v, m = ladder.run("t.site", { text = "x" })
  eq(v, "a", "routed verdict is returned")
  eq(m.agree, true, "agreement recorded when llm matches")
  eq(llm_calls, 1, "llm consulted once for the sample")
  local saw
  for _, r in ipairs(records) do if r.kind == "ladder" then saw = r.row.payload end end
  ok(saw and saw.site == "t.site" and saw.tier == "jev" and saw.agree == true, "ladder record emitted")
end
llm_value = "b"
do
  local v, m = ladder.run("t.site", { text = "x" })
  eq(v, "a", "disagreeing llm does not change the verdict")
  eq(m.agree, false, "disagreement recorded")
end
llm_value = "llm-says"

-- definition rules
reset()
ok(not pcall(ladder.define, { id = "t.bad", stages = { ladder.llm(function() end), ladder.code(function() end) } }),
   "stages out of cost order are refused")
ok(select(2, ladder.set_enabled("nope", true)) ~= nil, "unknown site rejected")
ok(select(2, ladder.set_number("nope", "threshold", 0.5)) ~= nil, "unknown site rejected for numbers")
define()
ok(select(2, ladder.set_number("t.site", "threshold", 2)) ~= nil, "out-of-range number rejected")

-- command surface
reset(); define()
ok(ladder.command(""):find("t.site", 1, true), "describe lists sites")
ok(ladder.command("on t.site"):find("on"), "on <site> works")
eq(ladder.enabled("t.site"), true, "command enabled the site")
ok(ladder.command("off t.site"):find("t.site", 1, true), "off <site> works")
eq(ladder.enabled("t.site"), false, "command disabled the site")
ok(ladder.command("bogus"):find("usage"), "unknown subcommand prints usage")

io.write(string.format("ladder: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
