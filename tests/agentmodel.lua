-- agentmodel.lua -- one agent model: everything is a swarm, and a lone agent is
-- a swarm whose fanout is capped at one.
--
-- What this pins down is that there is no longer a separate "single-agent path":
-- skills resolve, tools filter and the prompt assembles through the same code
-- for the session's own agent as for a spawned child, and the ONLY structural
-- difference is the cap. (There is one transport now -- every turn is an async
-- scheduler coroutine on the unified loop -- so it is not even a difference.)
local thread = require("thread")
local skills = require("skills")
local prompt = require("prompt")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function blocktext(blocks)
  local t = {}
  for _, b in ipairs(blocks) do t[#t + 1] = b.text end
  return table.concat(t, "\n")
end

local saved_userdir, saved_cap, saved_live = bog.userdir, thread.max_agents, thread.live
bog.userdir = os.tmpname() .. "_agentmodel"
sys.mkdir_p(bog.userdir .. "/lua/skills")
package.path = bog.userdir .. "/lua/?.lua;" .. package.path

assert(skills.save("reviewer", { description = "review",
  instructions = "Only real defects.", tools = { "read", "bash" } }))

-- ---- skills work in single-agent mode --------------------------------------
thread.max_agents, thread.live = 1, 0
local sess = { id = 9001, model = bog.session.model, messages = {} }
local rec = thread.session_agent(sess, { "reviewer" })
ok(rec.instructions:find("Only real defects"), "single agent resolves skill instructions")
ok(rec.allow.read and rec.allow.bash and not rec.allow.write, "single agent gets the allowlist")
ok(sess.agent == rec, "record attaches to the session")
ok(rec.opts.async == nil, "no per-agent transport flag -- one async transport for all")

-- the tool surface is genuinely narrowed
local names = {}
for _, s in ipairs(rec.opts.tools()) do names[s.name] = true end
ok(names.read and names.bash and not names.write, "tool list filtered by the skill")
ok(rec.opts.run_tool("write", {}):find("not permitted"), "a tool outside the skill is refused")

-- ---- the capped agent is not told it can delegate --------------------------
local sys1 = blocktext(rec.opts.system())
ok(sys1:find("# Skills") and sys1:find("Only real defects"), "prompt carries skill instructions")
ok(not sys1:find("boggart swarm"), "a capped agent is NOT told it can spawn")
ok(rec.may_spawn == false, "cap of 1 means the root agent may not spawn")

-- ---- raising the cap is the whole difference -------------------------------
ok(thread.at_capacity(), "at capacity with cap 1 and the root agent live")
thread.max_agents = 16
ok(not thread.at_capacity(), "raising the cap allows fanout")
ok(blocktext(prompt.agent_system({ may_spawn = true })):find("boggart swarm"),
   "an agent that may spawn is told about the swarm")

-- ---- no skills means the full registry (default behaviour preserved) -------
thread.live = 0
local plain = thread.session_agent({ id = 9002, messages = {} }, {})
ok(#plain.opts.tools() == #bog.tools.schemas(), "no skills -> every tool offered")
ok(plain.opts.run_tool("read", { path = "/nonexistent-xyz" }) ~= nil, "no skills -> nothing refused")

-- ---- unknown skills refuse loudly here too ---------------------------------
local okc, err = pcall(thread.session_agent, { id = 9003, messages = {} }, { "nope" })
ok(not okc and tostring(err):find("unknown skill"), "unknown skill refuses the single agent")

-- ---- prompt.system() routes through the same builder -----------------------
local saved_sess_agent = bog.session.agent
bog.session.agent = rec
ok(blocktext(prompt.system()):find("Only real defects"),
   "prompt.system() uses the session agent's skills")
bog.session.agent = saved_sess_agent

sys.rmtree(bog.userdir)
bog.userdir, thread.max_agents, thread.live = saved_userdir, saved_cap, saved_live

io.write(string.format("agentmodel: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
