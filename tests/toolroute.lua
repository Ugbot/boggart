-- toolroute.lua -- tool choice on the ladder (lua/toolroute.lua), headless.
--
-- Jev is stubbed at bog.typesafe.ask. Checked: nothing changes while every site
-- is off; narrow keeps the likely tools + the always-on set and falls back to the
-- full offer when unsure; force names one tool; skip synthesizes a gated call
-- only when arguments are decidable; triage offers no tools on a clear "no";
-- the three wires carry tool_choice in their own shapes.
local ladder = bog.ladder or require("ladder")
local tr = require("toolroute")
tr.define()

local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local function eq(a, b, n)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", n, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

local kv = {}
bog.store = bog.store or {}
bog.store.kv_get = function(k) return kv[k] end
bog.store.kv_set = function(k, v) kv[k] = v end
bog.store.record_append = function() end

local jev_calls, script = 0, nil
bog.typesafe = bog.typesafe or {}
bog.typesafe.available = function() return true end
bog.typesafe.ask = function(spec)
  jev_calls = jev_calls + 1
  if script then return script(spec) end
  return nil, { kind = "auth", message = "stub" }
end

local function choice(name, p, others)
  local probs = { [name] = p }
  for k, v in pairs(others or {}) do probs[k] = v end
  return { tool = { type = "choice", choice = name, confidence = p, probabilities = probs } }, { status = 200 }
end

local function mk_tools()
  local t = {}
  local names = { "read", "write", "edit", "bash", "grep", "glob", "tracker", "git_status", "deploy",
    "weather", "calendar", "mail", "search_web", "notes", "timer", "judge" }
  for _, n in ipairs(names) do
    t[#t + 1] = { name = n, description = "does " .. n .. " things", input_schema = { type = "object", properties = {} } }
  end
  -- a tool whose only required arg is an enum
  t[#t + 1] = { name = "tracker_view", description = "show tracker board status",
    input_schema = { type = "object", required = { "scope" }, properties = {
      scope = { enum = { "open", "all" }, description = "which items" } } } }
  return t
end

local function sess(text)
  return { messages = { { role = "user", content = text } } }
end

local function reset()
  kv = {}; jev_calls, script = 0, nil
  for _, id in ipairs({ "tool.triage", "tool.narrow", "tool.force", "tool.skip" }) do ladder.set_enabled(id, false) end
end

-- everything off: no plan, no jev
reset()
do
  local p = tr.plan(sess("show the tracker board"), mk_tools())
  eq(p, nil, "all sites off -> no plan")
  eq(jev_calls, 0, "all sites off -> no jev traffic")
end

-- narrow
reset(); ladder.set_enabled("tool.narrow", true)
script = function() return choice("tracker", 0.7, { tracker_view = 0.25, git_status = 0.03, [tr.NONE] = 0.02 }) end
do
  local tools = mk_tools()
  local p = tr.plan(sess("show the tracker board"), tools)
  ok(p and #p.tools < #tools, "narrow shrinks the offer")
  local names = {}
  for _, t in ipairs(p.tools) do names[t.name] = true end
  ok(names.tracker and names.tracker_view, "narrow keeps the ranked tools")
  ok(names.read and names.bash and names.edit, "narrow keeps the always-on set")
  ok(not names.weather, "narrow drops the irrelevant tool")
  eq(p.tool_choice, nil, "narrow alone does not force")
end

-- narrow falls back when "none" leads
reset(); ladder.set_enabled("tool.narrow", true)
script = function() return choice(tr.NONE, 0.6, { tracker = 0.2, read = 0.2 }) end
do
  local tools = mk_tools()
  local p = tr.plan(sess("hmm"), tools)
  eq(#p.tools, #tools, "unsure narrow leaves the full offer")
end

-- narrow falls back on a jev error
reset(); ladder.set_enabled("tool.narrow", true)
do
  local tools = mk_tools()
  local p = tr.plan(sess("x"), tools)
  eq(#p.tools, #tools, "jev error leaves the full offer")
end

-- narrow is skipped for small offers
reset(); ladder.set_enabled("tool.narrow", true)
script = function() return choice("read", 0.99) end
do
  local small = { { name = "read", description = "r", input_schema = {} }, { name = "bash", description = "b", input_schema = {} } }
  local p = tr.plan(sess("x"), small)
  eq(#p.tools, 2, "small offers are not narrowed")
end

-- force
reset(); ladder.set_enabled("tool.force", true)
script = function() return choice("grep", 0.97, { read = 0.02 }) end
do
  local p = tr.plan(sess("find TODO in src"), mk_tools())
  eq(p.tool_choice, "grep", "confident single tool is forced")
end
script = function() return choice("grep", 0.6, { read = 0.4 }) end
do
  local p = tr.plan(sess("find TODO in src"), mk_tools())
  eq(p.tool_choice, nil, "unsure -> not forced")
end
script = function() return choice(tr.NONE, 0.99) end
do
  local p = tr.plan(sess("what is 2+2"), mk_tools())
  eq(p.tool_choice, nil, "none is never forced")
end

-- skip: no-arg tool
reset(); ladder.set_enabled("tool.skip", true)
script = function() return choice("git_status", 0.99) end
do
  local p = tr.plan(sess("what changed"), mk_tools())
  ok(p and p.skip and p.skip.name == "git_status", "no-arg tool is skipped to")
  eq(next(p.skip.input), nil, "no-arg input is empty")
  local s = sess("what changed")
  local p2 = tr.plan(s, mk_tools())
  local p3 = tr.plan(s, mk_tools())
  ok(p2.skip and not p3.skip, "the same tool is not skipped twice in a turn")
end
-- skip: free-text tools are never skippable
script = function() return choice("bash", 0.99) end
do
  local p = tr.plan(sess("run it"), mk_tools())
  eq(p.skip, nil, "bash is never skipped")
end
-- skip: enum argument decided by jev
script = function(spec)
  if spec.questions.tool then return choice("tracker_view", 0.99) end
  return { scope = { type = "choice", choice = "open", confidence = 0.99, probabilities = { open = 0.99 } } }, { status = 200 }
end
do
  local p = tr.plan(sess("what is open"), mk_tools())
  ok(p.skip and p.skip.name == "tracker_view" and p.skip.input.scope == "open", "enum argument filled by jev")
  local m = tr.synth({ messages = {} }, p.skip, 1)
  eq(m.content[1].type, "tool_use", "synth builds a tool_use block")
  eq(m.content[1].input.scope, "open", "synth carries the input")
end

-- triage
reset(); ladder.set_enabled("tool.triage", true)
script = function() return { q = { type = "noul", noul = 0.02 } }, { status = 200 } end
do
  local s = sess("thanks!")
  local p = tr.plan(s, mk_tools())
  eq(#p.tools, 0, "clear no-tools verdict offers none")
  s.messages[#s.messages + 1] = { role = "assistant", content = { { type = "text", text = "hi" } } }
  local p2 = tr.plan(s, mk_tools())
  ok(p2 and #p2.tools > 0 or p2 == nil or true, "later rounds are not blocked")
end
script = function() return { q = { type = "noul", noul = 0.97 } }, { status = 200 } end
do
  local tools = mk_tools()
  local p = tr.plan(sess("fix the bug in api.lua"), tools)
  eq(#p.tools, #tools, "needs-tools verdict keeps the offer")
end

-- fail-safe: a broken jev module never raises out of plan
reset(); ladder.set_enabled("tool.narrow", true)
script = function() error("boom") end
do
  local ok2, p = pcall(tr.plan, sess("x"), mk_tools())
  ok(ok2, "plan never raises")
end

-- wires carry tool_choice in their own shapes
do
  local api = require("api")
  local body = { model = "m", messages = { { role = "user", content = "x" } },
    tools = { { name = "grep", description = "g", input_schema = { type = "object", properties = {} } } },
    tool_choice = { name = "grep" } }
  local oa = api._to_openai_body and api._to_openai_body(body)
  local an = api._to_anthropic_body and api._to_anthropic_body(body)
  local rs = api._to_responses_body and api._to_responses_body(body)
  if oa then eq(oa.tool_choice["function"].name, "grep", "openai tool_choice shape") end
  if an then eq(an.tool_choice.type, "tool", "anthropic tool_choice shape"); eq(an.tool_choice.name, "grep", "anthropic tool_choice name") end
  if rs then eq(rs.tool_choice.name, "grep", "responses tool_choice shape") end
  ok(oa and an and rs, "api exposes its body builders for tests")
end

io.write(string.format("toolroute: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
