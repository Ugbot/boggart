-- goap.lua -- opt-in goal planning (lua/goap.lua) and the per-agent blackboard
-- (lua/blackboard.lua). The search is driven directly for correctness; the tools
-- are then exercised through the REAL registry, including an execute that runs a
-- side-effect-free built-in and writes its effect back to the blackboard.
local goap = require("goap")
local bb = require("blackboard")
local tools = require("tools")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end
local function join(t) return table.concat(t, ",") end

-- ---- search: ordering by precondition, cost, reachability ------------------
local actions = {
  { name = "get_weapon", tool = "grab", pre = {}, effect = { has_weapon = true }, cost = 1 },
  { name = "load",       tool = "load", pre = { has_weapon = true }, effect = { armed = true }, cost = 1 },
}
local plan, cost = goap.search({}, { armed = true }, actions)
eq(join(plan or {}), "get_weapon,load", "search orders by precondition")
eq(cost, 2, "search sums cost")

ok(goap.search({}, { armed = true },
  { { name = "load", tool = "load", pre = { has_weapon = true }, effect = { armed = true } } }) == nil,
  "no plan when a precondition is unreachable")

plan = goap.search({ armed = true }, { armed = true }, actions)
ok(plan and #plan == 0, "already-satisfied goal -> empty plan")

-- optimality
plan, cost = goap.search({}, { done = true }, {
  { name = "cheap",    tool = "c", pre = {}, effect = { done = true }, cost = 1 },
  { name = "pricey_a", tool = "a", pre = {}, effect = { mid = true }, cost = 5 },
  { name = "pricey_b", tool = "b", pre = { mid = true }, effect = { done = true }, cost = 5 },
})
eq(join(plan), "cheap", "A* picks the cheaper route")

-- negative precondition
plan = goap.search({ locked = true }, { open = true }, {
  { name = "open",   tool = "o", pre = { locked = false }, effect = { open = true } },
  { name = "unlock", tool = "u", pre = { locked = true }, effect = { locked = false } },
})
eq(join(plan), "unlock,open", "negative precondition (unlock then open)")

-- ---- blackboard ------------------------------------------------------------
bb.clear("t")
bb.set("ready", true, "t")
ok(bb.get("ready", "t"), "blackboard set/get")
ok(not bb.get("missing", "t"), "closed-world: absent atom is false")
bb.apply({ ready = false, hot = true }, "t")
ok(not bb.get("ready", "t") and bb.get("hot", "t"), "apply sets and clears")
local snap = bb.snapshot("t")
ok(snap.hot and snap.ready == nil, "snapshot is the true-atom set")

-- ---- wiring: tools registered in the real registry -------------------------
ok(tools.registry.goap ~= nil, "goap is registered")
ok(tools.registry.define_action ~= nil, "define_action is registered")
ok(tools.registry.blackboard ~= nil, "blackboard is registered")

-- ---- end to end through the real registry ----------------------------------
-- 'tasks' is a real, side-effect-free built-in; use it as the action's tool.
goap.actions = {}
bb.clear()
local d = tools.run("define_action", { name = "probe", tool = "tasks", effect = { probed = true } })
ok(d:find("Declared action 'probe'"), "define_action tool declares")

local shown = tools.run("goap", { goal = { probed = true } })
ok(shown:find("Plan") and shown:find("probe"), "goap tool returns a plan (no execution)")
ok(not bb.get("probed"), "plan-only did not touch the blackboard")

local done = tools.run("goap", { goal = { probed = true }, execute = true })
ok(done:find("Executed plan"), "goap execute runs the plan through the registry")
ok(bb.get("probed"), "execute applied the effect to the blackboard")

ok(tools.run("goap", { goal = { probed = true } }):find("Already satisfied"),
  "re-planning sees the goal already met on the blackboard")

-- ---- validation ------------------------------------------------------------
ok(tools.run("define_action", { name = "1bad", tool = "x" }):find("name must match"),
  "define_action rejects a bad name")
ok(tools.run("goap", { goal = "nope" }):find("requires a 'goal'"),
  "goap rejects a non-object goal")

io.write(string.format("goap: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
