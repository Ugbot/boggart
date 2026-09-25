-- judge.lua -- the decision router (lua/judge.lua), headless.
--
-- Both backends are stubbed: bog.typesafe.ask is replaced with a scripted
-- answer (or failure) and judge.chat_impl with a scripted JSON reply, so the
-- routing rules, the schema translation, the confidence cascade and the
-- "optional by construction" contract are all checked without a key or a
-- model. The order matters: with no key nothing may reach jev.
local json = require("json")
local judge = bog.judge or require("judge")

local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local function eq(a, b, n)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", n, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

-- ---- the stubs --------------------------------------------------------------
local jev_calls, chat_calls = 0, 0
local jev_script, chat_script, jev_keyed = nil, nil, false
bog.typesafe = bog.typesafe or {}
local real_available, real_ask = bog.typesafe.available, bog.typesafe.ask
bog.typesafe.available = function() return jev_keyed end
bog.typesafe.ask = function(spec)
  jev_calls = jev_calls + 1
  if type(jev_script) == "function" then return jev_script(spec) end
  return nil, { kind = "auth", message = "stub: no jev" }
end
judge.chat_impl = function(system, user, route)
  chat_calls = chat_calls + 1
  if type(chat_script) == "function" then return chat_script(system, user, route) end
  return "no"
end
local function reset() jev_calls, chat_calls, jev_script, chat_script = 0, 0, nil, nil end

-- config lives in kv; keep the suite hermetic
local kv = {}
bog.store = bog.store or {}
bog.store.kv_get = function(k) return kv[k] end
bog.store.kv_set = function(k, v) kv[k] = v end

-- ---- questions --------------------------------------------------------------
do
  local q, e = judge.normalize_question{ kind = "choice", instructions = "which", options = { "a", "b" } }
  ok(q and q.options.a == "a" and q.options.b == "b", "bare option list describes itself")
  q, e = judge.normalize_question{ type = "score", instructions = "how", criteria = { "lo", "hi" } }
  ok(q and q.kind == "score" and #q.levels == 2, "wire-format question passes through")
  q, e = judge.normalize_question{ kind = "score", instructions = "how", levels = { "only" } }
  ok(q == nil and e:find("2..10"), "one score level rejected")
  local many = {}
  for i = 1, 256 do many["o" .. i] = "x" end
  q, e = judge.normalize_question{ kind = "choice", instructions = "which", options = many }
  ok(q == nil and e:find("255"), "256 options rejected")
  q, e = judge.normalize_question{ kind = "noul" }
  ok(q == nil and e:find("instructions"), "missing instructions rejected")
  q, e = judge.normalize_question{ kind = "essay", instructions = "write" }
  ok(q == nil and e:find("unknown"), "unknown kind rejected")
end

-- ---- schema translation -----------------------------------------------------
do
  local qs, e = judge.questions_from_schema{ type = "object", properties = {
    verdict = { enum = { "ship", "fix" }, enumDescriptions = { ship = "good", fix = "needs work" } },
    risky = { type = "boolean", description = "Is it risky" },
    quality = { type = "integer", minimum = 1, maximum = 4, ["x-levels"] = { "poor", "ok", "good", "great" } },
  } }
  ok(qs ~= nil, "simple schema translates: " .. tostring(e))
  eq(qs.verdict.kind, "choice", "enum -> choice")
  eq(qs.verdict.options.fix, "needs work", "enumDescriptions become option descriptions")
  eq(qs.risky.kind, "noul", "boolean -> noul")
  eq(qs.risky.instructions, "Is it risky", "description -> instructions")
  eq(qs.quality.kind, "score", "bounded integer -> score")
  eq(#qs.quality.levels, 4, "levels span the range")
  eq(qs.quality.minimum, 1, "minimum remembered")
  eq(qs.quality.levels[4], "great", "x-levels used verbatim")

  qs, e = judge.questions_from_schema{ type = "object", properties = { summary = { type = "string" } } }
  ok(qs == nil and e:find("free text"), "a string property is not simple")
  qs, e = judge.questions_from_schema{ type = "object", properties = { n = { type = "integer", minimum = 0, maximum = 50 } } }
  ok(qs == nil and e:find("2..10"), "a wide integer is not simple")
  qs, e = judge.questions_from_schema{ type = "string" }
  ok(qs == nil, "non-object schema is not simple")
end

-- ---- routing: optional by construction -------------------------------------
local Q = { pick = { kind = "choice", instructions = "which", options = { a = "A", b = "B" } } }
do
  reset(); jev_keyed = false; kv = {}
  eq(judge.backend(), "auto", "default backend is auto")
  local via, why = judge.route{ state = "s", questions = Q }
  eq(via, "chat", "no key: auto routes to chat")
  ok(why:find("unavailable"), "...and says why")
  ok(judge.status().effective == "chat", "status reports effective chat")

  jev_keyed = true
  via = judge.route{ state = "s", questions = Q }
  eq(via, "jev", "key present: simple decision routes to jev")

  judge.set_backend("off")
  via = judge.route{ state = "s", questions = Q }
  eq(via, "chat", "backend off never routes to jev even with a key")
  judge.set_backend("chat")
  eq(judge.route{ state = "s", questions = Q }, "chat", "backend chat never routes to jev")
  judge.set_backend("jev"); jev_keyed = false
  eq(judge.route{ state = "s", questions = Q }, "jev", "backend jev insists even without a key")
  ok(judge.set_backend("bogus") == nil, "bad backend rejected")
  ok(judge.set_min_confidence(2) == nil, "bad threshold rejected")
  judge.set_min_confidence(0.9); eq(judge.min_confidence(), 0.9, "threshold round-trips through kv")

  judge.set_backend("auto"); jev_keyed = true
  local big = string.rep("x", judge.DEFAULTS.max_state_chars + 1)
  eq(judge.route{ state = big, questions = Q }, "chat", "oversized state routes to chat")
  via, why = judge.route{ state = "s", schema = { type = "object", properties = { s = { type = "string" } } } }
  eq(via, "chat", "non-simple schema routes to chat")
  local v, e = judge.route{ state = "s", questions = {} }
  ok(v == nil and e:find("needs questions"), "empty questions is a caller error")
  v, e = judge.route{ state = "s", questions = { q = { kind = "score", instructions = "x", levels = { "1" } } } }
  ok(v == nil and e:find("2..10"), "malformed question is a caller error, not a chat fallback")
end

-- ---- decide: chat path --------------------------------------------------------
do
  reset(); kv = {}; jev_keyed = false
  chat_script = function(_, user)
    ok(user:find("SCHEMA:", 1, true) and user:find('"enum"', 1, true), "chat gets a schema with the enum")
    return 'thinking...\n{"pick":"b"}'
  end
  local a, m = judge.decide{ state = "s", questions = Q }
  ok(a and a.pick.choice == "b", "chat answer shaped like jev's")
  eq(a and a.pick.ranked[1].option, "b", "...with a ranked list")
  eq(m.via, "chat", "via chat")
  eq(jev_calls, 0, "jev never called without a key")
  eq(chat_calls, 1, "one chat call")

  reset()
  chat_script = function() return "I cannot decide." end
  a, m = judge.decide{ state = "s", questions = Q }
  ok(a == nil and m.kind == "parse", "no JSON from chat is a parse error, not a raise")
  reset()
  chat_script = function() return '{"pick":"zzz"}' end
  a, m = judge.decide{ state = "s", questions = Q }
  ok(a == nil and m.message:find("missed: pick"), "an off-enum chat answer is reported missing")
  reset()
  chat_script = function() error("boom") end
  a, m = judge.decide{ state = "s", questions = Q }
  ok(a == nil and m.kind == "transport", "a raising chat impl becomes nil+err")

  -- noul and score shaping, plus the shifted minimum
  reset()
  chat_script = function() return '{"yes":true,"q":3}' end
  a, m = judge.decide{ state = "s", questions = {
    yes = { kind = "noul", instructions = "?" },
    q = { kind = "score", instructions = "?", levels = { "a", "b", "c" }, minimum = 1 } } }
  eq(a and a.yes.noul, 1, "true -> noul 1")
  eq(a and a.q.score, 3, "score kept in the caller's range")
  eq(a and a.q.legend[3], "c", "legend keyed from minimum")
end

-- ---- decide: jev path + confidence cascade -----------------------------------
local function jev_answer(choice, conf)
  return function()
    return { pick = { type = "choice", choice = choice, confidence = conf,
                      probabilities = { a = conf, b = 1 - conf },
                      ranked = { { option = choice, p = conf } } } },
           { model = "jev-1.13.0", usage = { input_tokens = 10, output_tokens = 2 } }
  end
end
do
  reset(); kv = {}; jev_keyed = true
  jev_script = jev_answer("a", 0.95)
  local a, m = judge.decide{ state = "s", questions = Q }
  ok(a and a.pick.choice == "a", "confident jev answer returned")
  eq(m.via, "jev", "via jev")
  eq(m.escalated, false, "not escalated")
  eq(chat_calls, 0, "no chat call when confident")
  eq(m.model, "jev-1.13.0", "jev meta preserved")

  reset(); jev_script = jev_answer("a", 0.3)
  chat_script = function() return '{"pick":"b"}' end
  a, m = judge.decide{ state = "s", questions = Q }
  eq(a and a.pick.choice, "b", "low confidence: chat's answer wins")
  eq(m.via, "chat", "via chat after escalation")
  eq(m.escalated, true, "escalated flag set")
  ok(m.jev and m.jev.answers.pick.choice == "a", "jev's numbers kept for telemetry")
  eq(jev_calls, 1, "jev asked once"); eq(chat_calls, 1, "chat asked once")

  reset(); jev_script = jev_answer("a", 0.3)
  chat_script = function() return "nope" end
  a, m = judge.decide{ state = "s", questions = Q }
  ok(a and a.pick.choice == "a" and m.via == "jev", "low confidence but chat unusable: jev's answer stands")
  ok(m.chat_error ~= nil, "...with the chat failure attached")

  reset(); jev_script = jev_answer("a", 0.3)
  a, m = judge.decide{ state = "s", questions = Q, min_confidence = 0.1 }
  eq(m.via, "jev", "per-call threshold overrides the config")
  eq(chat_calls, 0, "...so no escalation")

  -- jev fails outright: auto falls back, jev insists
  reset(); jev_script = function() return nil, { kind = "overloaded", message = "529" } end
  chat_script = function() return '{"pick":"a"}' end
  a, m = judge.decide{ state = "s", questions = Q }
  ok(a and m.via == "chat" and m.reason:find("jev failed"), "jev failure falls back to chat in auto")
  reset(); judge.set_backend("jev")
  jev_script = function() return nil, { kind = "overloaded", message = "529" } end
  a, m = judge.decide{ state = "s", questions = Q }
  ok(a == nil and m.kind == "overloaded", "backend jev reports the failure instead of falling back")
  eq(chat_calls, 0, "...and never touches chat")
  judge.set_backend("auto")

  -- noul confidence is distance from 0.5
  reset(); jev_script = function()
    return { q = { type = "noul", noul = 0.52 } }, { model = "jev-1.13.0" }
  end
  chat_script = function() return '{"q":false}' end
  local p, ans, meta = judge.yes("s", "?")
  eq(meta.via, "chat", "a 0.52 noul is low confidence -> escalated")
  eq(p, 0, "chat's false -> 0")
  reset(); jev_script = function()
    return { q = { type = "noul", noul = 0.98 } }, { model = "jev-1.13.0" }
  end
  p, ans, meta = judge.yes("s", "?")
  eq(meta.via, "jev", "a 0.98 noul stands"); eq(p, 0.98, "probability returned")

  -- score minimum shift on the jev path
  reset(); jev_script = function()
    return { q = { type = "score", score = 1.5, confidence = 0.9, legend = {}, probabilities = {} } }, {}
  end
  local s = judge.rate("s", "?", { "a", "b", "c" })
  eq(s, 1.5, "rate returns the expected score")
  reset(); jev_script = function()
    return { quality = { type = "score", score = 2, confidence = 0.9, legend = {}, probabilities = {} } }, {}
  end
  a, m = judge.decide{ state = "s", schema = { type = "object", properties = {
    quality = { type = "integer", minimum = 1, maximum = 3 } } } }
  eq(a and a.quality.score, 3, "schema minimum shifts jev's 0-based score")

  -- choose shorthand
  reset(); jev_script = function()
    return { q = { type = "choice", choice = "b", confidence = 0.9, probabilities = { b = 0.9, a = 0.1 } } }, {}
  end
  local name, ans2, m2 = judge.choose("s", "which", { a = "A", b = "B" })
  eq(name, "b", "choose returns the name"); eq(m2.via, "jev", "...via jev")
end

-- ---- the tool ---------------------------------------------------------------
do
  reset(); kv = {}; jev_keyed = true; jev_script = jev_answer("a", 0.9)
  local out = judge.tool.run{ state = "s", questions = Q }
  local obj = json.decode(out)
  ok(obj and obj.answers.pick.choice == "a" and obj.via == "jev", "tool returns JSON with via")
  out = judge.tool.run{ state = "s", questions = { bad = { kind = "essay", instructions = "x" } } }
  ok(out:find("^Tool error"), "tool reports a bad question as a tool error")
  ok(judge.describe():find("backend=auto"), "describe mentions the backend")
end

bog.typesafe.available, bog.typesafe.ask = real_available, real_ask
io.write(string.format("judge: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
