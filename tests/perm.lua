-- perm.lua -- the permission policy engine: rules, guards, agent narrowing.
--
-- The mode enum (auto/smart/manual/chat) answers "how much should it ask?" and
-- nothing else, which is why "git is fine, never touch ~/.ssh" had nowhere to
-- live. These tests pin the layer that answers WHICH call: glob rules over the
-- tool's subject, three guards everyone else ships (secrets, outside the
-- workspace, doom loops), and the rule that an agent may narrow what it
-- inherited but never widen it -- the property that makes a sub-agent profile
-- a safety statement instead of a suggestion.
--
-- The most important test in here is the last one: with no rules configured,
-- every decision must be exactly what the mode enum said before this existed.
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

local perm = require "perm"

-- ---- glob ----------------------------------------------------------------
ok(perm.glob("*", "anything"), "* matches anything")
ok(perm.glob("git *", "git status"), "prefix glob matches")
ok(not perm.glob("git *", "npm install"), "prefix glob rejects another command")
ok(perm.glob("src/**", "src/a/b/c.lua"), "** crosses separators")
ok(not perm.glob("src/*", "src/a/b.lua"), "single * does not cross a separator")
ok(perm.glob("src/*", "src/a.lua"), "single * matches within a segment")
ok(perm.glob("**/.env", "/deep/path/.env"), "leading ** matches a deep path")
ok(perm.glob("?.lua", "a.lua"), "? matches exactly one character")
ok(not perm.glob("?.lua", "ab.lua"), "? does not match two")
-- a dot in the pattern is a literal dot, not "any character"
ok(not perm.glob("a.lua", "axlua"), "pattern metacharacters are escaped")

-- ---- subjects ------------------------------------------------------------
eq(perm.subject("bash", { command = "ls -l" }), "ls -l", "bash matches on its command")
eq(perm.subject("edit", { path = "src/x.lua" }), "src/x.lua", "edit matches on its path")
eq(perm.subject("web_search", { query = "acp spec" }), "acp spec", "an unknown tool still has a subject")

-- ---- rules ---------------------------------------------------------------
local rules = {
  ["*"] = "ask",
  bash = { ["*"] = "ask", ["git *"] = "allow", ["sudo *"] = "deny" },
  edit = { ["src/**"] = "allow" },
}
eq(perm.rule_for("bash", { command = "git status" }, rules), "allow", "a rule allows git")
eq(perm.rule_for("bash", { command = "sudo rmdir /" }, rules), "deny", "a rule denies sudo")
eq(perm.rule_for("bash", { command = "make" }, rules), "ask", "the tool catch-all applies")
eq(perm.rule_for("edit", { path = "src/a.lua" }, rules), "allow", "a path rule allows in-tree edits")
eq(perm.rule_for("read", { path = "README.md" }, rules), "ask", "the global catch-all applies")
eq(perm.rule_for("read", { path = "README.md" }, {}), nil, "an empty rule table has no opinion")

-- The tool's own table outranks the "*" catch-all even when the catch-all is
-- stricter -- otherwise "* = ask" would make every specific allow unreachable.
eq(perm.rule_for("bash", { command = "git log" }, { ["*"] = "deny", bash = { ["git *"] = "allow" } }),
   "allow", "a tool rule beats the catch-all")

-- ---- guards --------------------------------------------------------------
local st = { mode = "auto", tool_policy = {} }
local v, why = perm.guard("read", { path = "/home/x/project/.env" }, st)
eq(v, "deny", "reading a .env is denied by the secret guard")
ok(why and why:find("credential"), "the secret guard says why")
eq((perm.guard("read", { path = "src/a.lua" }, st)), nil, "an ordinary file passes the guards")

local st2 = { mode = "auto", tool_policy = {} }
v, why = perm.guard("read", { path = "/etc/passwd" }, st2)
eq(v, "ask", "a path outside the workspace asks")
ok(why and why:find("workspace"), "the workspace guard says why")

ok(perm.outside_workspace("../../etc/passwd"), "a relative path that climbs out is outside")
ok(not perm.outside_workspace("src/a.lua"), "an in-tree relative path is inside")
ok(not perm.outside_workspace("./a/../b.lua"), "climbing back inside is still inside")

-- doom loop: the same call three times running
local st3 = { mode = "auto", tool_policy = {} }
eq((perm.guard("bash", { command = "make" }, st3)), nil, "first identical call is fine")
eq((perm.guard("bash", { command = "make" }, st3)), nil, "second identical call is fine")
v, why = perm.guard("bash", { command = "make" }, st3)
eq(v, "ask", "the third identical call in a row asks")
ok(why and why:find("times running"), "the loop guard says why")
-- a different call in between resets it
local st4 = { mode = "auto", tool_policy = {} }
perm.guard("bash", { command = "make" }, st4)
perm.guard("bash", { command = "ls" }, st4)
eq((perm.guard("bash", { command = "make" }, st4)), nil, "a different call breaks the streak")

-- guards are a default, not a law
local st5 = { mode = "auto", tool_policy = {}, guards = false }
eq((perm.guard("read", { path = "/home/x/.env" }, st5)), nil, "guards can be turned off")

-- ---- decide: precedence ---------------------------------------------------
local d = { mode = "smart", tool_policy = {}, rules = rules }
eq((perm.decide("bash", { command = "git status" }, d)), "allow",
   "a rule allows what smart mode would have asked about")
eq((perm.decide("bash", { command = "sudo x" }, d)), "deny", "a rule denies")
eq((perm.decide("read", { path = "README.md" }, { mode = "smart", tool_policy = {} })), "allow",
   "with no rules, read follows the mode enum")

-- an explicit runtime "always allow" beats everything else
eq((perm.decide("bash", { command = "sudo x" }, { mode = "smart", tool_policy = { bash = "allow" } })),
   "allow", "an explicit tool_policy entry wins")

-- a rule cannot un-deny a credential file
eq((perm.decide("read", { path = "/home/x/.ssh/id_rsa" },
     { mode = "auto", tool_policy = {}, rules = { read = { ["**"] = "allow" } } })),
   "deny", "no rule can open a credential file")

-- chat mode still refuses everything
eq((perm.decide("read", { path = "a.lua" }, { mode = "chat", tool_policy = {}, rules = rules })),
   "deny", "chat mode denies regardless of rules")

-- ---- agent narrowing ------------------------------------------------------
local base = { mode = "auto", tool_policy = {},
               agent_rules = { bash = { ["*"] = "deny" }, read = { ["**"] = "ask" } } }
eq((perm.decide("bash", { command = "ls" }, base)), "deny", "an agent profile can deny what the mode allowed")
eq((perm.decide("read", { path = "a.lua" }, base)), "ask", "an agent profile can downgrade allow to ask")
-- and the other direction must NOT work
local narrow = { mode = "manual", tool_policy = {},
                 agent_rules = { bash = { ["*"] = "allow" } } }
eq((perm.decide("bash", { command = "ls" }, narrow)), "ask",
   "an agent profile cannot widen what it inherited")
local denied = { mode = "auto", tool_policy = {}, rules = { bash = { ["*"] = "deny" } },
                 agent_rules = { bash = { ["*"] = "allow" } } }
eq((perm.decide("bash", { command = "ls" }, denied)), "deny",
   "an agent profile cannot overturn a deny rule")

eq(perm.stricter("allow", "ask"), "ask", "stricter picks ask over allow")
eq(perm.stricter("deny", "ask"), "deny", "stricter picks deny over ask")
eq(perm.stricter(nil, "allow"), "allow", "stricter tolerates a missing side")

-- ---- the veto hook --------------------------------------------------------
-- events could watch a tool call but never stop one. A handler that returns
-- {deny=true} refuses it, and its reason reaches the model.
local seen = nil
-- handlers are called fn(event_name, data), the same as every other subscriber
local handle = bog.events.on("tool:before", function(_, ev)
  seen = ev
  if ev.tool == "bash" and tostring(ev.input.command):find("push %-%-force") then
    return { deny = true, reason = "this repo forbids force-push" }
  end
end)
local ran = {}
local run = perm.wrap_run(function(name, input) ran[#ran + 1] = name; return "ok" end,
                          { mode = "auto", tool_policy = {} })
eq(run("bash", { command = "git status" }), "ok", "an un-vetoed call runs")
ok(seen and seen.tool == "bash", "the hook sees the call")
local refused = run("bash", { command = "git push --force" })
ok(tostring(refused):find("permission_error"), "a vetoed call is refused")
ok(tostring(refused):find("forbids force%-push"), "the veto reason reaches the model")
eq(#ran, 1, "the vetoed call never reached the tool")
bog.events.off(handle)

-- ---- the invariant: no rules means no change ------------------------------
-- Every mode, every gated and ungated tool, with an empty rule table: the
-- answer must be identical to the mode enum's own. This is what makes the
-- engine additive rather than a behaviour change.
for _, mode in ipairs({ "auto", "smart", "manual", "chat" }) do
  for _, tool in ipairs({ "read", "list", "write", "edit", "bash" }) do
    local plain = { mode = mode, tool_policy = {} }
    local before = perm.policy_for(tool, plain)
    local after = perm.decide(tool, { path = "src/in_tree.lua", command = "make" },
                              { mode = mode, tool_policy = {} })
    eq(after, before, string.format("%s/%s unchanged with no rules", mode, tool))
  end
end

io.write(string.format("perm: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
