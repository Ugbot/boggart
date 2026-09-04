-- roles.lua -- an agent declares intent; a user binds it to a model.
--
-- The catalog answers "where does this model live". Roles answer the question a
-- person actually has -- "the cheap one for the boring parts, the good one for
-- the hard parts" -- without every agent definition hard-coding a vendor.
--
-- The property under test is portability: `lua/agents/critic.lua` says
-- `role = "critic"`, and what a critic IS differs per machine. A spec written
-- by someone with five providers has to work for someone running one local
-- model, or shared specs are worthless.
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

bog.userdir = os.tmpname() .. "_boggart_roles"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()

local C = require "catalog"
local route = require "route"
local thread = require "thread"
C.seed_if_empty()

-- ---- resolving a role -----------------------------------------------------
C.bind_role("critic", { "grok-4.6", "glm-5.3" })

local r = route.resolve("role:critic")
eq(r.model, "grok-4.6", "role:critic resolves to its first binding")
eq(r.url, "https://api.x.ai/v1", "with that model's endpoint")
eq(r.role, "critic", "and remembers which role asked")

eq(route.resolve("@critic").model, "grok-4.6", "@critic is the same thing")

-- a chain, in order, so a caller can fall through
local chain = route.resolve_chain("role:critic")
eq(#chain, 2, "a bound list yields every candidate")
eq(chain[1].model, "grok-4.6", "first")
eq(chain[2].model, "glm-5.3", "then the fallback")
eq(chain[2].wire, "anthropic", "each candidate carries its own destination")

-- a single binding is still a chain of one
C.bind_role("utility", "glm-5.3-flash")
eq(#route.resolve_chain("role:utility"), 1, "a single binding is a one-entry chain")

-- ---- an unbound role must not fail ----------------------------------------
-- The portability property: an agent asking for a role this machine has never
-- heard of still runs, on the default.
local unbound = route.resolve("role:nobody-bound-this")
eq(unbound.model, "claude-opus-5", "an unbound role falls through to the default")
eq(unbound.role, "nobody-bound-this", "while recording what was asked for")

-- ---- the precedence chain -------------------------------------------------
-- call > agent spec's model > agent spec's role > whatever the parent is on.
local by_role = thread.new_agent{ task = "review", agent = "critic" }
eq(by_role.session.model, "grok-4.6",
   "an agent whose spec declares a role is routed by the user's binding")

local by_call = thread.new_agent{ task = "review", agent = "critic", model = "glm-5.3" }
eq(by_call.session.model, "glm-5.3",
   "an explicit model on the spawn beats the agent's role")

local plain = thread.new_agent{ task = "anything" }
ok(plain.session.model ~= nil, "an agent with neither still has a model")

-- rebinding the role changes where the same agent goes, with no code edit
C.bind_role("critic", "glm-5.3-flash")
local rebound = thread.new_agent{ task = "review", agent = "critic" }
eq(rebound.session.model, "glm-5.3-flash",
   "rebinding a role reroutes the agent that declares it")

-- ---- the utility seat -----------------------------------------------------
-- Compaction is bookkeeping, so it takes the utility role when one is bound.
C.bind_role("utility", "glm-5.3-flash")
local util = route.utility()
eq(util.model, "glm-5.3-flash", "route.utility() takes the bound utility role")

-- ...and falls back rather than failing when nothing is bound
bog.db:run("DELETE FROM roles WHERE name='utility'")
local fallback = route.utility()
ok(fallback ~= nil and fallback.model ~= nil,
   "with no utility role bound, bookkeeping still has somewhere to go")

-- ---- bindings survive a reload -------------------------------------------
-- They are rows, not process state.
package.loaded["catalog"] = nil
local C2 = require "catalog"
eq(C2.role("critic")[1], "glm-5.3-flash", "a binding is in the store, not in memory")

io.write(string.format("roles: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
