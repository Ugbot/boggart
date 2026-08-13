-- plan.lua -- compiled procedures (lua/plan.lua): a defined task chains tool
-- calls with no model turn between them. Two halves: the executor logic, driven
-- with a stubbed dispatcher so it is hermetic and deterministic; and the wiring,
-- which asserts the run_plan/define_task/tasks tools are actually registered and
-- that a task runs through the REAL tool registry.
local plan = require("plan")
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

-- A dispatcher that records call order and returns canned results. "boom"
-- returns a Tool error, to exercise stop-on-error.
local calls = {}
local function dispatch(name, args)
  calls[#calls + 1] = { name = name, args = args }
  if name == "boom" then return "Tool error: [runtime] boom" end
  return "ran " .. name
end

-- ---- executor: ordered chaining, no model turn -----------------------------
assert(plan.define("build_and_test", { steps = {
  { tool = "build" }, { tool = "test" }, { tool = "notify" },
} }))
calls = {}
local r = plan.run_task("build_and_test", { dispatch = dispatch })
ok(r.ok, "chain ok")
eq(#calls, 3, "chain fired three tools")
eq(calls[1].name .. calls[2].name .. calls[3].name, "buildtestnotify", "chain order")

-- ---- task composition (task calling task), flat trace ----------------------
assert(plan.define("publish", { steps = { { tool = "upload" }, { tool = "announce" } } }))
assert(plan.define("release", { steps = {
  { tool = "build" }, { task = "publish" }, { tool = "tag" },
} }))
calls = {}
r = plan.run_task("release", { dispatch = dispatch })
ok(r.ok, "compose ok")
eq(#calls, 4, "compose fired build+upload+announce+tag")
eq(calls[2].name, "upload", "compose descended into the subtask")
eq(calls[4].name, "tag", "compose resumed the parent after the subtask")

-- ---- a guard skips a step --------------------------------------------------
assert(plan.define("guarded", { steps = {
  { tool = "always" },
  { tool = "maybe", when = function(ctx) return ctx.args.do_maybe end },
  { tool = "always2" },
} }))
calls = {}
r = plan.run_task("guarded", { dispatch = dispatch, args = { do_maybe = false } })
eq(#calls, 2, "guard skipped the gated step")
eq(calls[2].name, "always2", "guard: run continued past the skip")

-- ---- stop-on-error halts the rest ------------------------------------------
assert(plan.define("fragile", { steps = {
  { tool = "step1" }, { tool = "boom" }, { tool = "never" },
} }))
calls = {}
r = plan.run_task("fragile", { dispatch = dispatch })
ok(not r.ok, "fragile stops")
eq(#calls, 2, "fragile did not run past the failure")
ok(r.stopped_at and r.stopped_at:find("boom"), "fragile reports where it stopped")

-- ---- a cycle is bounded, not infinite --------------------------------------
assert(plan.define("loop", { steps = { { task = "loop" } } }))
r = plan.run_task("loop", { dispatch = dispatch })
ok(not r.ok, "cycle stops")
ok(r.error and r.error:find("depth"), "cycle reports the depth bound")

-- ---- dynamic args threaded from an earlier result --------------------------
assert(plan.define("pipeline", { steps = {
  { tool = "produce", save = "made" },
  { tool = "consume", args = function(ctx) return { from = ctx.made } end },
} }))
calls = {}
r = plan.run_task("pipeline", { dispatch = dispatch })
ok(r.ok, "pipeline ok")
eq(calls[2].args.from, "ran produce", "pipeline threaded the prior result into args")

-- ---- wiring: the tools exist in the real registry --------------------------
ok(tools.registry.run_plan ~= nil, "run_plan is registered")
ok(tools.registry.define_task ~= nil, "define_task is registered")
ok(tools.registry.tasks ~= nil, "tasks is registered")

-- ---- end to end through the REAL registry ----------------------------------
-- define_task then run_plan, over a real, side-effect-free built-in ('tasks').
local d = tools.run("define_task", { name = "list_tasks", steps = { { tool = "tasks" } } })
ok(d:find("Defined task 'list_tasks'"), "define_task tool defines")
local out = tools.run("run_plan", { task = "list_tasks" })
ok(out:find("plan 'list_tasks'"), "run_plan returns a trace summary")
ok(out:find("1%..-tasks"), "run_plan fired the real 'tasks' tool as its step")

-- ---- define_task validation ------------------------------------------------
ok(tools.run("define_task", { name = "x", steps = { { tool = "a", task = "b" } } })
   :find("exactly one"), "define_task rejects a step with both tool and task")
ok(tools.run("define_task", { name = "1bad", steps = { { tool = "a" } } })
   :find("name must match"), "define_task rejects a bad name")

io.write(string.format("plan: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
