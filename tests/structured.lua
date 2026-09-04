-- structured.lua -- structured returns and per-child budgets for the fleet.
--
-- A sub-agent that answers in prose is a sub-agent whose coordinator has to
-- re-read English to decide anything, which is why fan-out so often stops at a
-- demo. `spawn{ schema = ... }` makes the child answer with a JSON object, and
-- -- the part that matters -- makes a non-answer a failure of the EXIT
-- CONTRACT, so the existing bounded retry feeds it back and asks again.
--
-- The extractor is deliberately last-object-wins rather than
-- whole-reply-must-be-JSON: models narrate before they answer, and demanding
-- otherwise fails honest work.
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

local thread = require "thread"

-- ---- extracting the answer ----------------------------------------------
local j = thread.extract_json('{"verdict":"ship","score":7}')
eq(type(j), "table", "a bare object parses")
eq(j and j.verdict, "ship", "with its fields")

j = thread.extract_json('I looked at the diff and it is fine.\n{"verdict":"ship"}')
eq(j and j.verdict, "ship", "prose before the object is fine")

j = thread.extract_json('{"verdict":"draft"}\nActually, on reflection:\n{"verdict":"ship"}')
eq(j and j.verdict, "ship", "the LAST object wins when a model revises itself")

j = thread.extract_json('{"outer":{"inner":1},"n":2}')
eq(j and j.n, 2, "a nested object parses as one value")
eq(type(j and j.outer), "table", "and keeps its nesting")

-- The three cases that make this a scanner rather than a pattern match: a
-- brace inside a string value, deep nesting, and an escaped quote before a
-- brace. Each of these ends an object early under a naive implementation.
j = thread.extract_json('{"cmd":"echo {not json}","ok":true}')
eq(j and j.cmd, "echo {not json}", "a brace inside a string does not end the object")
eq(j and j.ok, true, "and the rest of the object survives it")
j = thread.extract_json('prose {"a":{"b":{"c":3}}} more prose')
eq(j and j.a and j.a.b and j.a.b.c, 3, "deep nesting parses")
j = thread.extract_json('{"esc":"a \\" }"}')
eq(j and j.esc, 'a " }', "an escaped quote does not open a string")

eq(thread.extract_json("no json here at all"), nil, "prose alone yields nothing")
eq(thread.extract_json(""), nil, "empty text yields nothing")
eq(thread.extract_json('{"broken": '), nil, "a truncated object is not accepted")

-- ---- the shallow schema check -------------------------------------------
local schema = { type = "object", required = { "verdict", "score" } }
eq(thread.schema_miss(schema, { verdict = "ship", score = 7 }), nil,
   "a complete answer passes")
ok(tostring(thread.schema_miss(schema, { verdict = "ship" })):find("score"),
   "a missing field is named")
ok(tostring(thread.schema_miss(schema, nil)):find("no JSON object"),
   "no object at all says so plainly")
eq(thread.schema_miss(nil, { anything = true }), nil,
   "no schema means no opinion")
-- extra fields are fine: the contract is a floor, not a straitjacket
eq(thread.schema_miss(schema, { verdict = "ship", score = 7, notes = "x" }), nil,
   "extra fields are allowed")

-- ---- the record carries what was asked for -------------------------------
-- new_agent is the seam where a spawn's options become an agent; check the two
-- new ones land, including the budget the turn loop enforces.
bog.userdir = os.tmpname() .. "_boggart_structured"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()

local rec = thread.new_agent{ task = "check the build", schema = schema, budget = 1234 }
eq(type(rec.schema), "table", "the agent record carries the schema")
eq(rec.schema.required[1], "verdict", "and it is the one that was asked for")
eq(rec.session.token_budget, 1234, "a per-child budget reaches the turn loop")

local plain = thread.new_agent{ task = "no contract" }
eq(plain.schema, nil, "an agent spawned without a schema has none")
eq(plain.session.token_budget, thread.default_token_budget,
   "and keeps the default budget")

-- ---- per-agent permission profiles ---------------------------------------
-- The skill allowlist answers "may this agent use this TOOL"; a profile
-- answers "may it make THIS CALL". A profile may only narrow.
local scoped = thread.new_agent{ task = "review only",
  perms = { bash = { ["*"] = "deny" }, read = { ["**"] = "allow" } } }
eq(type(scoped.perms), "table", "the agent record carries its profile")

local perm = require "perm"
local run_state = { mode = "auto", tool_policy = {}, agent_rules = scoped.perms }
eq(perm.decide("bash", { command = "ls" }, run_state), "deny",
   "a read-only profile denies the shell even when the run is autonomous")
eq(perm.decide("read", { path = "src/a.lua" }, run_state), "allow",
   "and still permits what it was given")

-- the direction that must not work: a child cannot grant itself more than the
-- run permits, whatever its profile says
local strict_run = { mode = "manual", tool_policy = {},
                     agent_rules = { bash = { ["*"] = "allow" } } }
eq(perm.decide("bash", { command = "ls" }, strict_run), "ask",
   "a profile cannot widen the authority it inherited")

io.write(string.format("structured: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
