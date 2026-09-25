-- typesafe.lua -- the TypeSafe System One codec (src/ltypesafe.c) and the
-- policy module around it (lua/typesafe.lua), headless. The request the C
-- side builds is checked against the documented quickstart request, and the
-- documented quickstart response is decoded and read back typed. No network:
-- the transport is the same http.begin every wire uses, and ask{} must fail
-- closed (nil + err, never a raise) before it would ever reach it.
local json = require("json")
local ts = bog.typesafe or require("typesafe")

local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local function eq(a, b, n)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", n, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end
local function near(a, b, n) ok(type(a) == "number" and math.abs(a - b) < 1e-9, n .. " (" .. tostring(a) .. ")") end

-- structural equality, order-insensitive on object keys
local function deep_eq(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deep_eq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

ok(type(typesafe) == "table", "typesafe global exists")
ok(type(ts) == "table" and type(ts.ask) == "function", "lua module exposes ask")
eq(typesafe.endpoint(), "https://api.typesafe.ai/v1/systemone", "default endpoint")
eq(typesafe.models_url(), "https://api.typesafe.ai/v1/models", "default models url")
eq(typesafe.DEFAULT_MODEL, "jev-latest", "default model alias")
eq(typesafe.SLOT, "typesafe", "credential slot name")
do
  local lim = typesafe.limits()
  eq(lim.choice_max, 255, "limits: choice_max"); eq(lim.score_min, 2, "limits: score_min")
  eq(lim.score_max, 10, "limits: score_max"); eq(lim.state_tokens, 32000, "limits: state tokens")
end

-- ---- encode: the quickstart request, byte-for-byte in structure ------------
local QUICKSTART_REQ = [[
{
  "state": "Hi, I've been trying to connect my Stripe account for 3 days and the integration keeps failing. I'm losing sales. Please help ASAP.",
  "model": "jev-latest",
  "questions": {
    "department": {
      "type": "choice",
      "instructions": "Which team should handle this",
      "criteria": {
        "billing": "Payment or subscription issues",
        "technical": "Bugs or integration problems",
        "sales": "Pricing or account questions"
      }
    },
    "frustration": {
      "type": "score",
      "instructions": "How frustrated the customer appears",
      "criteria": [
        "Calm, just stating facts",
        "Frustrated but civil",
        "Very angry, strong language"
      ]
    },
    "is_urgent": {
      "type": "noul",
      "instructions": "The message conveys urgency or time-sensitivity"
    }
  }
}]]

do
  local want = json.decode(QUICKSTART_REQ)
  local body, err = typesafe.encode{
    state = want.state,
    questions = {
      department = ts.choice("Which team should handle this", {
        billing = "Payment or subscription issues",
        technical = "Bugs or integration problems",
        sales = "Pricing or account questions",
      }),
      frustration = ts.score("How frustrated the customer appears", {
        "Calm, just stating facts", "Frustrated but civil", "Very angry, strong language",
      }),
      is_urgent = ts.noul("The message conveys urgency or time-sensitivity"),
    },
  }
  ok(type(body) == "string", "encode: returns a JSON string (" .. tostring(err) .. ")")
  local got = body and json.decode(body)
  ok(got and deep_eq(got, want), "encode: matches the documented quickstart request")
  eq(got and got.model, "jev-latest", "encode: model defaults to jev-latest")
  ok(got and got.questions.is_urgent.criteria == nil, "encode: noul without criteria omits the field")
end

-- structured EntryType values pass through verbatim; state may be a table;
-- state_json is used as-is; the model is overridable
do
  local body = typesafe.encode{
    state = { ticket = { id = 7, tags = { "a", "b" } }, text = "hello" },
    model = "jev-1.13.0",
    questions = {
      q = { type = "choice", instructions = { field = { name = "x" }, question = "?" },
            criteria = { a = { what = "A", examples = { "a1" } }, b = json.null } },
      s = ts.score("lvl", { { summary = "low", signals = { "x" } }, "mid", "high" }),
      n = ts.noul("is it", { ["true"] = "yes", ["false"] = "no" }),
      nb = ts.noul("is it", { [true] = { what = "yes" }, [false] = "no" }),
    },
  }
  local got = body and json.decode(body)
  ok(got, "encode: structured request encodes")
  eq(got and got.model, "jev-1.13.0", "encode: explicit model")
  eq(got and got.state.ticket.tags[2], "b", "encode: table state, nested array")
  eq(got and got.questions.q.instructions.field.name, "x", "encode: structured instructions")
  eq(got and got.questions.q.criteria.a.examples[1], "a1", "encode: structured choice description")
  ok(got and got.questions.q.criteria.b == json.null, "encode: null description preserved")
  eq(got and got.questions.s.criteria[1].signals[1], "x", "encode: structured score level")
  eq(got and got.questions.n.criteria["true"], "yes", "encode: noul criteria (string keys)")
  eq(got and got.questions.nb.criteria["true"].what, "yes", "encode: noul criteria (boolean keys)")
  eq(got and got.questions.nb.criteria["false"], "no", "encode: noul false key")

  local b2 = typesafe.encode{ state_json = '{"raw":[1,2,3]}', questions = { n = ts.noul("?") } }
  local g2 = b2 and json.decode(b2)
  eq(g2 and g2.state.raw[3], 3, "encode: state_json is embedded verbatim")
  -- an empty table is an object, as lua/json.lua sends it
  local b3 = typesafe.encode{ state = {}, questions = { n = ts.noul("?") } }
  ok(b3 and b3:find('"state":{}', 1, true), "encode: empty table state is {}")
end

-- ---- encode: validation is local and named -----------------------------------
local function bad(spec, want_sub, name)
  local body, err = typesafe.encode(spec)
  ok(body == nil and type(err) == "table" and err.kind == "validation", name .. ": nil + validation err")
  ok(err and tostring(err):find(want_sub, 1, true) ~= nil, name .. ": message mentions '" .. want_sub .. "' (" .. tostring(err) .. ")")
end
bad({ state = "s", questions = { q = { type = "bogus", instructions = "x" } } }, "noul, choice or score", "bad type")
bad({ state = "s", questions = { q = { type = "score", instructions = "x", criteria = { "only one" } } } }, "2..10 levels", "one score level")
do
  local eleven = {}
  for i = 1, 11 do eleven[i] = "l" .. i end
  bad({ state = "s", questions = { q = ts.score("x", eleven) } }, "2..10 levels", "eleven score levels")
end
do
  local opts = {}
  for i = 1, 256 do opts["o" .. i] = "d" end
  bad({ state = "s", questions = { q = ts.choice("x", opts) } }, "at most 255", "256 choice options")
end
bad({ state = "s", questions = { q = { type = "choice", criteria = { a = "A" } } } }, "instructions are required", "missing instructions")
bad({ state = "s", questions = { q = ts.choice("x", { "a", "b" }) } }, "map of option", "choice criteria as array")
bad({ state = "s", questions = { q = ts.choice("x", {}) } }, "at least one option", "empty choice")
bad({ state = "s", questions = { q = ts.score("x", { a = "b", c = "d" }) } }, "ordered array", "score criteria as map")
bad({ state = "s", questions = { q = ts.noul("x", { maybe = "?" }) } }, "true/false", "noul criteria bad key")
bad({ questions = { q = ts.noul("x") } }, "state is required", "no state")
bad({ state = "s", state_json = "{}", questions = { q = ts.noul("x") } }, "not both", "state and state_json")
bad({ state_json = "{not json", questions = { q = ts.noul("x") } }, "not valid JSON", "bad state_json")
bad({ state = "s", questions = {} }, "at least one question", "no questions")
bad({ state = "s" }, "questions must be", "questions missing")
bad({ state = "s", questions = { ts.noul("x") } }, "question ids must be strings", "numeric question id")
bad({ state = 42, questions = { q = ts.noul("x") } }, "state must be", "numeric state")
do
  local body, err = typesafe.encode{ state = "s", questions = { q = ts.noul("x", { ["true"] = function() end }) } }
  ok(body == nil and err.kind == "validation", "unencodable value: validation err")
end

-- ---- decode: the quickstart response ---------------------------------------
local QUICKSTART_RESP = [[
{
  "model": "jev-1.13.0",
  "answers": {
    "department": {
      "type": "choice",
      "choice": "technical",
      "confidence": 0.78,
      "probabilities": { "technical": 0.85, "sales": 0.0, "billing": 0.15 }
    },
    "frustration": {
      "type": "score",
      "score": 1.0,
      "confidence": 1.0,
      "legend": { "0": "Calm, just stating facts", "1": "Frustrated but civil", "2": "Very angry, strong language" },
      "probabilities": { "0": 0.0, "1": 1.0, "2": 0.0 }
    },
    "is_urgent": { "type": "noul", "noul": 1.0 }
  },
  "usage": { "input_tokens": 392, "output_tokens": 65 }
}]]

do
  local a, meta = typesafe.decode(QUICKSTART_RESP, 200)
  ok(type(a) == "table", "decode: answers table (" .. tostring(meta) .. ")")
  eq(meta and meta.model, "jev-1.13.0", "decode: meta.model")
  eq(meta and meta.usage.input_tokens, 392, "decode: usage.input_tokens")
  eq(meta and meta.usage.output_tokens, 65, "decode: usage.output_tokens")
  eq(meta and meta.status, 200, "decode: meta.status")

  local d = a and a.department
  eq(d and d.type, "choice", "choice: type")
  eq(d and d.choice, "technical", "choice: choice")
  near(d and d.confidence, 0.78, "choice: confidence")
  near(d and d.probabilities.technical, 0.85, "choice: probabilities map")
  near(d and d.probabilities.billing, 0.15, "choice: probabilities map (2)")
  eq(d and #d.ranked, 3, "choice: ranked has every option")
  eq(d and d.ranked[1].option, "technical", "choice: ranked[1] is the top option")
  near(d and d.ranked[1].p, 0.85, "choice: ranked[1].p")
  eq(d and d.ranked[2].option, "billing", "choice: ranked[2]")
  eq(d and d.ranked[3].option, "sales", "choice: ranked[3]")

  local f = a and a.frustration
  eq(f and f.type, "score", "score: type")
  eq(f and f.score, 1.0, "score: score")
  eq(f and f.confidence, 1.0, "score: confidence")
  eq(f and f.legend[1], "Frustrated but civil", "score: legend keyed by INTEGER level")
  eq(f and f.legend["1"], nil, "score: legend has no string keys")
  eq(f and f.legend[0], "Calm, just stating facts", "score: legend level 0")
  eq(f and f.probabilities[1], 1.0, "score: probabilities keyed by integer level")
  eq(f and f.probabilities[0], 0.0, "score: probabilities level 0 present")
  eq(f and f.ranked[1].level, 1, "score: ranked[1].level")
  eq(f and f.ranked[1].p, 1.0, "score: ranked[1].p")
  ok(f and math.type(f.ranked[1].level) == "integer", "score: ranked level is an integer")
  eq(f and #f.ranked, 3, "score: ranked covers every level")

  local u = a and a.is_urgent
  eq(u and u.type, "noul", "noul: type")
  eq(u and u.noul, 1.0, "noul: value")
  ok(u and u.confidence == nil, "noul: no confidence field")
end

-- decode without a status (a cached body) still works; fractional scores and
-- an unknown answer type survive
do
  local a = typesafe.decode('{"model":"m","answers":{"s":{"type":"score","score":1.4,"confidence":0.6,"legend":{"0":"a","1":"b"},"probabilities":{"0":0.6,"1":0.4}},"x":{"type":"future","payload":{"k":1}}},"usage":{"input_tokens":1,"output_tokens":0}}')
  near(a and a.s.score, 1.4, "decode: fractional score")
  eq(a and a.s.ranked[1].level, 0, "decode: ranked by probability, not level")
  eq(a and a.x.type, "future", "decode: unknown type kept")
  eq(a and a.x.payload.k, 1, "decode: unknown type payload passed through")
end

-- ---- decode: error envelopes -------------------------------------------------
do
  local a, e = typesafe.decode('{"detail":[{"loc":["body","questions"],"msg":"field required","type":"value_error.missing"}]}', 422)
  ok(a == nil and type(e) == "table", "422: nil + err table")
  eq(e and e.kind, "validation", "422: kind")
  eq(e and e.status, 422, "422: status")
  ok(e and tostring(e):find("field required", 1, true), "422: message from FastAPI detail (" .. tostring(e) .. ")")
  -- the envelope the live API actually sends (observed from llm-station's smoke)
  a, e = typesafe.decode('{"detail":{"error_type":"authentication_error","message":"Cannot authenticate"}}', 401)
  ok(a == nil and e and e.kind == "auth", "401 detail-object: kind auth")
  ok(e and tostring(e):find("authentication_error: Cannot authenticate", 1, true), "401 detail-object: type + message (" .. tostring(e) .. ")")

  local _, r = typesafe.decode('{"error":{"message":"rate limit exceeded","type":"rate_limit_error"}}', 429)
  eq(r and r.kind, "rate_limit", "429: kind")
  ok(r and tostring(r) == "rate limit exceeded", "429: message from error.message")

  local _, o = typesafe.decode("overloaded", 529)
  eq(o and o.kind, "overloaded", "529: kind")
  eq(o and o.message, "overloaded", "529: raw text as message")

  local _, au = typesafe.decode('{"error":"invalid api key"}', 401)
  eq(au and au.kind, "auth", "401: kind")
  eq(au and au.message, "invalid api key", "401: message from error string")

  local _, h = typesafe.decode("", 500)
  eq(h and h.kind, "http", "500: kind"); eq(h and h.message, "empty response", "500: empty body")

  local _, p = typesafe.decode("{not json", 200)
  eq(p and p.kind, "parse", "200 non-JSON: parse err")
  local _, na = typesafe.decode('{"model":"m"}', 200)
  eq(na and na.kind, "parse", "200 without answers: parse err")
  local _, ee = typesafe.decode('{"error":"nope"}', 200)
  eq(ee and ee.kind, "http", "200 with an error envelope: http err")

  local made = typesafe.error("transport", "boom", 0)
  eq(made.kind, "transport", "error(): kind"); eq(made.status, nil, "error(): status 0 omitted")
  eq(tostring(made), "boom", "error(): tostring")
end

-- ---- ask{} fails closed without a key --------------------------------------
do
  local had = os.getenv("TYPESAFE_API_KEY")
  ok(type(typesafe.has_key()) == "boolean", "has_key returns a boolean")
  if not had and not typesafe.has_key() then
    ok(ts.available() == false, "available() is false with no key")
    local okc, a, e = pcall(ts.ask, { state = "x", questions = { q = ts.noul("?") } })
    ok(okc, "ask never raises")
    ok(a == nil and type(e) == "table" and e.kind == "auth", "ask without a key: nil + auth err (" .. tostring(e) .. ")")
    local okm, m, me = pcall(ts.models)
    ok(okm and m == nil and me.kind == "auth", "models without a key: nil + auth err")
    local ok1, a1, e1 = pcall(ts.one, "x", ts.noul("?"))
    ok(ok1 and a1 == nil and e1.kind == "auth", "one() without a key: nil + auth err")
  else
    io.write("note: TYPESAFE_API_KEY is set; skipping the no-key checks\n")
  end
  local okb, a, e = pcall(ts.ask, "not a table")
  ok(okb and a == nil and e.kind == "validation", "ask(non-table): validation err")
end

-- the provider preset is in the seed, off the chat wires, with no model rows
do
  local seed = json.decode(boggart.embedded("models.json"))
  local p = seed.providers.typesafe
  ok(p ~= nil, "seed: typesafe provider present")
  eq(p and p.key_slot, "typesafe", "seed: key_slot")
  eq(p and p.auth, "bearer", "seed: bearer auth")
  eq(p and p.wire, "systemone", "seed: wire is systemone (not a chat wire)")
  local n = 0
  for _, m in pairs(seed.models) do if m.provider == "typesafe" then n = n + 1 end end
  eq(n, 0, "seed: no chat model rows point at typesafe")
end

io.write(string.format("typesafe: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
