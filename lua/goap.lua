-- goap.lua -- opt-in goal-oriented action planning: the search half of planning.
--
-- The model (or a human) declares actions -- a real tool plus its boolean
-- preconditions, effects and a cost -- and asks for a GOAL world-state. A* over
-- the declared actions, from the agent's blackboard to the goal, returns an
-- ordered plan; lua/plan.lua then executes whatever it finds. This is the smart,
-- opt-in half: nothing runs it unless the model chooses the `goap` tool, and the
-- whole point is that "our tools are the actions" -- among the declared actions
-- (each mapping to a tool) the planner works out which ones, in what order,
-- reach the goal, so the model states an intent instead of an ordering.
--
-- Closed-world: an atom absent from a state is false. Bounded on every axis so a
-- pathological domain cannot hang the agent.
local plan = require("plan")
local bb = require("blackboard")

local M = {}

M.LIMITS = { expansions = 5000, plan_len = 64 }
M.actions = {}   -- name -> { tool=, args=, pre={}, effect={}, cost= }

-- ---- search ----------------------------------------------------------------

local function satisfies(state, cond)
  for atom, want in pairs(cond) do
    if (state[atom] == true) ~= (want == true) then return false end
  end
  return true
end

local function apply_effect(state, effect)
  local s = {}
  for atom in pairs(state) do s[atom] = true end
  for atom, val in pairs(effect) do
    if val then s[atom] = true else s[atom] = nil end
  end
  return s
end

local function state_key(state)
  local ks = {}
  for atom in pairs(state) do ks[#ks + 1] = atom end
  table.sort(ks)
  return table.concat(ks, "\1")
end

local function heuristic(state, goal)
  local h = 0
  for atom, want in pairs(goal) do
    if (state[atom] == true) ~= (want == true) then h = h + 1 end
  end
  return h
end

-- start, goal: { atom = bool }. actions: an ordered list (sorted by the caller
-- for determinism). Returns { action_name, ... }, cost  |  nil, reason.
function M.search(start, goal, actions, limits)
  limits = limits or M.LIMITS
  local startset = {}
  for atom, val in pairs(start) do if val then startset[atom] = true end end
  if satisfies(startset, goal) then return {}, 0 end

  local open = { { state = startset, g = 0, f = heuristic(startset, goal), plan = {} } }
  local best = { [state_key(startset)] = 0 }
  local expansions = 0

  while #open > 0 do
    -- lowest f, then lowest g; a linear scan, bounded by the expansion budget.
    local bi = 1
    for i = 2, #open do
      local o, b = open[i], open[bi]
      if o.f < b.f or (o.f == b.f and o.g < b.g) then bi = i end
    end
    local node = table.remove(open, bi)

    if satisfies(node.state, goal) then return node.plan, node.g end

    expansions = expansions + 1
    if expansions > limits.expansions then return nil, "search budget exhausted" end

    if #node.plan < limits.plan_len then
      for _, act in ipairs(actions) do
        if satisfies(node.state, act.pre or {}) then
          local ns = apply_effect(node.state, act.effect or {})
          local ng = node.g + (act.cost or 1)
          local nk = state_key(ns)
          if not best[nk] or ng < best[nk] then
            best[nk] = ng
            local np = {}
            for i = 1, #node.plan do np[i] = node.plan[i] end
            np[#np + 1] = act.name
            open[#open + 1] = { state = ns, g = ng, f = ng + heuristic(ns, goal), plan = np }
          end
        end
      end
    end
  end
  return nil, "no plan reaches the goal"
end

-- ---- action registry -------------------------------------------------------

local function validate_action(name, spec)
  if type(name) ~= "string" or not name:match("^[%a_][%w_]*$") then
    return "action name must match [A-Za-z_][A-Za-z0-9_]*"
  end
  if type(spec.tool) ~= "string" then return "action '" .. name .. "' needs a 'tool'" end
  for _, k in ipairs({ "pre", "effect" }) do
    if spec[k] ~= nil and type(spec[k]) ~= "table" then
      return "action '" .. name .. "' " .. k .. " must be an object of atom=bool"
    end
  end
  if spec.cost ~= nil and type(spec.cost) ~= "number" then
    return "action '" .. name .. "' cost must be a number"
  end
end

function M.define(name, spec)
  local err = validate_action(name, spec or {})
  if err then return nil, err end
  M.actions[name] = { name = name, tool = spec.tool, args = spec.args,
    pre = spec.pre or {}, effect = spec.effect or {}, cost = spec.cost or 1 }
  return true
end

-- The action list to plan over: inline actions if given, else the registry,
-- always sorted by name so the search is deterministic.
local function action_list(inline)
  local list = {}
  if inline then
    for _, a in ipairs(inline) do list[#list + 1] = a end
  else
    for _, a in pairs(M.actions) do list[#list + 1] = a end
  end
  table.sort(list, function(x, y) return (x.name or "") < (y.name or "") end)
  return list
end

-- ---- the tools the model is offered ----------------------------------------

M.tools = {
  goap = {
    description = "Opt-in goal planner. Give a GOAL world-state as {atom=bool}; A* "
      .. "over declared actions (see define_action) finds an ordered plan of tools "
      .. "from the agent's blackboard to that goal. Returns the plan for you to "
      .. "inspect; pass execute=true to run it (each action's effects update the "
      .. "blackboard). State the intent, not the ordering.",
    input_schema = { type = "object",
      properties = {
        goal  = { type = "object", description = "desired world-state, {atom: bool}" },
        state = { type = "object", description = "start override; defaults to the blackboard" },
        actions = { type = "array", description = "inline actions [{name,tool,args,pre,effect,cost}]; "
          .. "defaults to the registered ones", items = { type = "object" } },
        execute = { type = "boolean", description = "run the plan (default false: just return it)" },
      }, required = { "goal" } },
    run = function(a)
      if type(a.goal) ~= "table" then
        return "Tool error: [validation_error] goap requires a 'goal' object of atom=bool"
      end
      local list = action_list(a.actions)
      if #list == 0 then
        return "Tool error: [validation_error] no actions to plan over (declare some with define_action)"
      end
      local by_name = {}
      for _, act in ipairs(list) do by_name[act.name] = act end
      local start = a.state
      if type(start) ~= "table" then start = bb.snapshot() end

      local names, cost = M.search(start, a.goal, list)
      if not names then return "No plan found: " .. tostring(cost) end
      if #names == 0 then return "Already satisfied: the goal holds in the current state." end

      if a.execute then
        local trace = {}
        for _, nm in ipairs(names) do
          local act = by_name[nm]
          local res = require("tools").run(act.tool, act.args or {})
          local failed = type(res) == "string" and res:sub(1, 11) == "Tool error:"
          trace[#trace + 1] = string.format("  %s (%s) %s", nm, act.tool, failed and "FAIL" or "ok")
          if failed then
            return "Executed partially, stopped at " .. nm .. ":\n"
              .. table.concat(trace, "\n") .. "\n" .. res
          end
          bb.apply(act.effect)
        end
        return string.format("Executed plan (cost %d):\n%s", cost, table.concat(trace, "\n"))
      end

      local steps = {}
      for i, nm in ipairs(names) do
        steps[i] = string.format("  %d. %s (%s)", i, nm, by_name[nm].tool)
      end
      return string.format("Plan (cost %d, %d steps):\n%s\n(pass execute=true to run it)",
        cost, #names, table.concat(steps, "\n"))
    end,
  },

  define_action = {
    description = "Declare a GOAP action: a name, the 'tool' it runs, optional 'args', "
      .. "and its boolean 'pre'conditions and 'effect's ({atom: bool}) plus a 'cost'. "
      .. "The planner composes these into plans. Effects are your model of what the "
      .. "tool achieves; keep them honest, since a wrong model plans confidently wrong.",
    input_schema = { type = "object",
      properties = {
        name = { type = "string" }, tool = { type = "string" },
        args = { type = "object" },
        pre = { type = "object", description = "{atom: bool} required to run" },
        effect = { type = "object", description = "{atom: bool} true after it runs" },
        cost = { type = "number" },
      }, required = { "name", "tool" } },
    run = function(a)
      local ok, err = M.define(a.name, { tool = a.tool, args = a.args,
        pre = a.pre, effect = a.effect, cost = a.cost })
      if not ok then return "Tool error: [validation_error] " .. tostring(err) end
      return string.format("Declared action '%s' -> tool '%s'.", a.name, a.tool)
    end,
  },

  blackboard = {
    description = "Inspect or set the agent's world-state (boolean facts the planner "
      .. "reads). op=list shows the true atoms; op=set atom=<name> value=<bool> asserts "
      .. "or retracts one; op=get atom=<name> reads one.",
    input_schema = { type = "object",
      properties = {
        op = { type = "string", description = "list | set | get" },
        atom = { type = "string" }, value = { type = "boolean" },
      } },
    run = function(a)
      local op = a.op or "list"
      if op == "set" then
        if type(a.atom) ~= "string" then return "Tool error: [validation_error] set needs 'atom'" end
        bb.set(a.atom, a.value ~= false)
        return string.format("%s := %s", a.atom, tostring(a.value ~= false))
      elseif op == "get" then
        if type(a.atom) ~= "string" then return "Tool error: [validation_error] get needs 'atom'" end
        return string.format("%s = %s", a.atom, tostring(bb.get(a.atom)))
      else
        local f = bb.facts()
        return #f > 0 and ("true atoms: " .. table.concat(f, ", ")) or "(blackboard empty)"
      end
    end,
  },
}

return M
