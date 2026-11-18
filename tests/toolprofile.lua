-- toolprofile.lua -- the opt-in lean tool profile (BOGGART_TOOLS=coding).
--
-- A profile narrows what an agent is OFFERED, to keep the fixed prompt prefix
-- small; the rest stays available through load_tools, and what it loads is
-- appended after the profile's tools so the cached prefix survives. With no
-- profile, behaviour is exactly the default.
local json = require("json")
local thread = require("thread")
local prompt = require("prompt")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end

local tools = bog.tools
local function names_of(list)
  local out = {}
  for i, s in ipairs(list) do out[i] = s.name end
  return out
end
local function set_of(list)
  local s = {}
  for _, n in ipairs(list) do s[n] = true end
  return s
end
local function join(list) return table.concat(list, ",") end
local function blocktext(blocks)
  local t = {}
  for _, b in ipairs(blocks) do t[#t + 1] = b.text end
  return table.concat(t, "\n")
end

-- the swarm tools (spawn, await) are registered by the agent runtime
bog.tools_swarm = bog.tools_swarm or require("tools_swarm")
bog.tools_swarm.register()

-- ---- profile off: default behaviour unchanged --------------------------------
local env = os.getenv("BOGGART_TOOLS")
ok(env == nil or env == "", "this suite runs with BOGGART_TOOLS unset")
ok(tools.profile() == nil, "no profile by default")
local default = names_of(tools.schemas())
ok(not set_of(default).load_tools, "load_tools is not offered without a profile")
local sess0 = { id = 9100, messages = {} }
thread.live = 0
local rec0 = thread.session_agent(sess0, {})
ok(join(names_of(rec0.opts.tools())) == join(default),
   "no profile: the agent is offered the full default list")
ok(tools.profile_note(rec0) == nil, "no profile: no profile note")
ok(not blocktext(prompt.agent_system(rec0)):find("load_tools", 1, true),
   "no profile: the system prompt does not mention load_tools")

-- ---- profile on: exactly its set ---------------------------------------------
local okp = tools.set_profile("coding")
ok(okp, "coding is a known profile")
ok(tools.profile() and tools.profile().name == "coding", "profile() reports coding")
local want = { "await", "bash", "code_search", "define_tool", "edit", "list",
               "load_tools", "read", "spawn", "write" }
local sess = { id = 9101, messages = {} }
thread.live = 0
local rec = thread.session_agent(sess, {})
local offered = names_of(rec.opts.tools())
local sorted = {}
for i, n in ipairs(offered) do sorted[i] = n end
table.sort(sorted)
ok(join(sorted) == join(want), "coding offers exactly its set: " .. join(offered))
-- in registry order, so the list is a stable prefix
local reg = {}
for _, n in ipairs(tools.names()) do if set_of(want)[n] then reg[#reg + 1] = n end end
ok(join(offered) == join(reg), "the profile's tools come in registry order")
local note = tools.profile_note(rec)
ok(note and note:find("load_tools", 1, true), "the profile note names load_tools")
ok(blocktext(prompt.agent_system(rec)):find("load_tools", 1, true),
   "the system prompt carries the profile note")

-- an agent whose skills grant an explicit tool set is not narrowed further
local rec_sk = { allow = { sql = true, read = true } }
ok(tools.profile_note(rec_sk) == nil, "a skill-scoped agent gets no profile note")

-- ---- load_tools: listing, loading, appending ----------------------------------
local function call_load(input)
  return tools.load_for(sess, input)
end
local listing = call_load({})
ok(listing:find("sql", 1, true) and listing:find("kv", 1, true),
   "load_tools with no names lists what can be loaded")
ok(listing:find("\n- sql:", 1, true) and not listing:find("\n- read:", 1, true),
   "the listing leaves out tools already offered")

local before = {}
for i, s in ipairs(rec.opts.tools()) do before[i] = json.encode(s) end
local r = call_load({ names = { "sql", "kv" } })
ok(r:find("sql", 1, true) and r:find("kv", 1, true), "load_tools reports what it loaded: " .. r)
local after_list = rec.opts.tools()
local after = {}
for i, s in ipairs(after_list) do after[i] = json.encode(s) end
local prefix_ok = #after == #before + 2
for i = 1, #before do if before[i] ~= after[i] then prefix_ok = false end end
ok(prefix_ok, "loading appends: the earlier schemas are an exact prefix")
ok(after_list[#after_list - 1].name == "sql" and after_list[#after_list].name == "kv",
   "loaded tools come in the order asked for")

-- loading again is a no-op, unknown names are reported
r = call_load({ names = { "sql", "no_such_tool" } })
ok(#rec.opts.tools() == #after_list, "loading an already-loaded tool adds nothing")
ok(r:find("no_such_tool", 1, true), "unknown names are reported")

-- wildcards expand to the matching registered tools, appended in registry order
tools.register("zz_ext__one", { description = "one", run = function() return "" end })
tools.register("zz_ext__two", { description = "two", run = function() return "" end })
call_load({ names = { "zz_ext__*" } })
local l3 = names_of(rec.opts.tools())
ok(l3[#l3 - 1] == "zz_ext__one" and l3[#l3] == "zz_ext__two", "a wildcard loads every match")

-- loads are per agent: a fresh agent starts from the profile again
thread.live = 0
local other = thread.session_agent({ id = 9102, messages = {} }, {})
ok(#other.opts.tools() == #want, "another agent is not affected by this one's loads")

-- a new turn rebuilds the session agent; the loads belong to the session
thread.live = 0
local rec_again = thread.session_agent(sess, {})
ok(#rec_again.opts.tools() == #l3, "loads persist across the session's turns")

-- the load_tools tool resolves the calling agent's session itself
local saved_session = bog.session
bog.session = { id = 9103, messages = {} }
local out = tools.registry.load_tools.run({ names = { "sql" } })
ok(out:find("sql", 1, true) and bog.session.loaded_tools
   and bog.session.loaded_tools[1] == "sql", "load_tools defaults to the current session")
bog.session = saved_session

-- ---- off again: back to the default list ---------------------------------------
tools.set_profile(nil)
thread.live = 0
local rec_off = thread.session_agent(sess, {})
local def2 = names_of(tools.schemas())
ok(join(names_of(rec_off.opts.tools())) == join(def2), "profile off again: full default list")
ok(not tools.set_profile("no-such-profile"), "an unknown profile is refused")
ok(tools.profile() == nil, "a refused profile leaves the profile off")

io.write(string.format("toolprofile: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
