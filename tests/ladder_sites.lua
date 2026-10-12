-- ladder_sites.lua -- the non-tool ladder sites (lua/ladder_sites.lua), headless:
-- swarm.supervise (watchdog), coding.verify (verify_cmd), tracker.classify
-- (tracker_core) and story.judge (story.draft). Jev is stubbed at
-- bog.typesafe.ask. Every site must leave behaviour untouched while off.
for _, t in ipairs{ "trk_projects", "trk_tasks", "trk_criteria", "trk_deps", "trk_tags", "trk_tag_rules", "trk_commits", "trk_issues" } do
  bog.db:run("DROP TABLE IF EXISTS " .. t)
end
local ladder = bog.ladder or require("ladder")
local sites = require("ladder_sites")
bog.ladder_sites = sites
sites.define()
local tc = require("tracker_core")

local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local function eq(a, b, n)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", n, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

local real_get, real_set = bog.store.kv_get, bog.store.kv_set
local kv = {}
bog.store.kv_get = function(k) return kv[k] end
bog.store.kv_set = function(k, v) kv[k] = v end

local script
bog.typesafe = bog.typesafe or {}
bog.typesafe.available = function() return true end
bog.typesafe.ask = function(spec)
  if script then return script(spec) end
  return nil, { kind = "auth", message = "stub" }
end
local function choice(q, name, p)
  return { [q] = { type = "choice", choice = name, confidence = p, probabilities = { [name] = p } } }, { status = 200 }
end
local function reset()
  kv = {}; script = nil
  for _, id in ipairs({ "swarm.supervise", "coding.verify", "tracker.classify", "story.judge" }) do
    ladder.set_enabled(id, false)
  end
end

-- ---- swarm.supervise ----------------------------------------------------------
local wd = require("watchdog")
local function stalled_agent()
  return { session = { _turns = 10, _tools = 0, usage = { output = 5000 }, inbox = {},
    messages = { { role = "user", content = "do it" }, { role = "assistant", content = "let me think" } } } }
end
local function tick(rec)
  bog.thread = bog.thread or {}
  bog.thread.live_recs = { [7] = rec }
  wd.tick()
end

reset()
do
  local rec = stalled_agent(); tick(rec)
  eq(#rec.session.inbox, 1, "off: a stalled agent is nudged as before")
  ok(rec.session.inbox[1]:find("ACT"), "off: the original nudge text")
end
reset(); ladder.set_enabled("swarm.supervise", true)
script = function() return choice("s", "progressing", 0.95) end
do
  local rec = stalled_agent(); tick(rec)
  eq(#rec.session.inbox, 0, "progressing agent is not nudged")
  ok(not rec._wd_nudged, "and stays armed")
end
script = function() return choice("s", "needs_human", 0.95) end
do
  local rec = stalled_agent(); tick(rec)
  ok(rec.session.inbox[1] and rec.session.inbox[1]:find("only a person"), "needs_human gets its own message")
end
script = function() return choice("s", "looping", 0.95) end
do
  local rec = stalled_agent(); tick(rec)
  ok(rec.session.inbox[1] and rec.session.inbox[1]:find("repeating"), "looping gets its own message")
end
script = function() return choice("s", "done", 0.5) end
do
  local rec = stalled_agent(); tick(rec)
  ok(rec.session.inbox[1] and rec.session.inbox[1]:find("ACT"), "low confidence falls back to the original nudge")
end
script = nil
do
  local rec = stalled_agent(); rec.done = true; tick(rec)
  eq(#rec.session.inbox, 0, "code stage: a finished agent is not nudged")
end

-- ---- coding.verify ------------------------------------------------------------
local vcmd = require("verify_cmd")
local out_text
bog.C = function() return function() return out_text end end
reset()
out_text = "[exit=1]\nFAILED test_x"
do
  local r = vcmd.green("run-tests")
  ok(type(r) == "string" and r:find("verification failed", 1, true), "off: red message as before")
  ok(not r:find("failure class", 1, true), "off: no class added")
end
reset(); ladder.set_enabled("coding.verify", true)
out_text = "[exit=127]\nsh: ctest: command not found"
do
  local r = vcmd.green("ctest")
  ok(r:find("failure class: environment", 1, true), "code patterns name an environment failure")
end
out_text = "[exit=1]\nninja: build stopped: subcommand failed."
do
  ok(vcmd.green("ninja"):find("failure class: build_error", 1, true), "code patterns name a build error")
end
out_text = "[exit=1]\nassertion failed: expected 3 got 4"
script = function() return choice("f", "code_bug", 0.97) end
do
  ok(vcmd.green("t"):find("failure class: code_bug", 1, true), "jev names a code bug when patterns abstain")
end
script = nil
do
  local r = vcmd.green("t")
  ok(not r:find("failure class", 1, true), "unclassified failure leaves the message alone")
end
out_text = "[exit=0]\nok"
eq(vcmd.green("t"), true, "green stays green")

-- ---- tracker.classify ---------------------------------------------------------
reset()
tc.native{ noun = "project", action = "create", key = "LAD", name = "Ladder" }
do
  local r = tc.native{ noun = "task", action = "create", project = "LAD", title = "Spike: try jev" }
  ok(r:find("[task/open] P3", 1, true), "off: defaults apply")
end
reset(); ladder.set_enabled("tracker.classify", true)
do
  local r = tc.native{ noun = "task", action = "create", project = "LAD", title = "Spike: try jev" }
  ok(r:find("[spike/open]", 1, true), "title rule picks kind")
end
script = function(spec)
  local out = {}
  if spec.questions.kind then out.kind = { type = "choice", choice = "story", confidence = 0.95, probabilities = { story = 0.95 } } end
  if spec.questions.priority then out.priority = { type = "score", score = 1, confidence = 0.95, probabilities = { [1] = 0.95 } } end
  return out, { status = 200 }
end
do
  local r = tc.native{ noun = "task", action = "create", project = "LAD", title = "Users can export boards" }
  ok(r:find("[story/open] P2", 1, true) or r:find("[story/open] P1", 1, true), "jev fills kind and priority: " .. tostring(r))
  local r2 = tc.native{ noun = "task", action = "create", project = "LAD", title = "Explicit", kind = "task", priority = 4 }
  ok(r2:find("[task/open] P4", 1, true), "an explicit kind and priority always win")
end

-- ---- story.judge --------------------------------------------------------------
reset()
local draft = require("story.draft")
do
  eq(draft.judge("some prose", nil), nil, "off, no call: nil as before")
  eq(draft.judge("some prose", function() return "7" end), 7, "off: the model's rating")
end
ladder.set_enabled("story.judge", true)
script = function() return { r = { type = "score", score = 5, confidence = 0.9, probabilities = { [5] = 0.9 } } }, { status = 200 } end
do
  local called = false
  local v = draft.judge("some prose", function() called = true; return "3" end)
  eq(v, 6, "jev rubric: score 5 on a 1-based scale is 6")
  ok(not called, "the model is not asked")
end
script = nil
do
  eq(draft.judge("some prose", function() return "4" end), 4, "jev unavailable falls back to the model")
end

bog.store.kv_get, bog.store.kv_set = real_get, real_set
io.write(string.format("ladder_sites: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
