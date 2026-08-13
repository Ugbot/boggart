-- plan.lua -- compiled procedures: a named task decomposes into ordered steps
-- that action themselves one after another, with NO model turn between them.
--
-- This is "a skill minus the per-step tool call". A skill still leans on the
-- model to choose and fire each tool; a task is a decomposition decided once
-- (by a human, or by the agent through define_task) and then executed locally:
-- the model calls run_plan ONCE and the whole sequence runs with no round trip
-- in between. The win is latency, cost and determinism, not intelligence --
-- the intelligence already happened when the task was written.
--
-- It is deliberately Lua, not a C planner: the point is chaining known steps,
-- which is cheap, and staying above the line where define_task can author new
-- procedures at runtime like define_tool authors new tools. Search-based
-- planning (GOAP) is a separate, later question; this is HTN's execution half.
--
-- A step is one of:
--   { tool = "name", args = <table|fn>, when = <fn>?, save = "key"? }
--   { task = "name", args = <table|fn>, when = <fn>? }
-- `args` may be a table (static; what a model-authored task uses) or, for
-- code-authored tasks, a function(ctx) computing them from earlier results.
-- `when(ctx)` gates a step (false -> skip). `save` stashes the result in ctx.

local M = {}

-- Bounded, so a cyclic or pathological task cannot run away. These are the
-- planner's whole safety story at this layer; keep them small and assert them.
M.LIMITS = { depth = 16, steps = 256, steps_per_task = 64 }

M.tasks = {}   -- name -> { description=, steps={...}, scope= }

local function is_error(res)
  return type(res) == "string" and res:sub(1, 11) == "Tool error:"
end

local function head(res, n)
  res = tostring(res)
  local line = res:match("^[^\n]*") or res
  if #line > (n or 80) then line = line:sub(1, (n or 80) - 1) .. "\226\128\166" end
  return line
end

-- The only outward effect: run a registered tool. Lazily required so this
-- module has no load-time dependency on tools.lua (which registers our tools),
-- and so a test can inject its own dispatch instead.
local function default_dispatch(name, input)
  return require("tools").run(name, input)
end

-- ---- validation ------------------------------------------------------------

local function validate_steps(steps)
  if type(steps) ~= "table" then return "steps must be a list" end
  if #steps == 0 then return "a task needs at least one step" end
  if #steps > M.LIMITS.steps_per_task then
    return string.format("too many steps (%d > %d)", #steps, M.LIMITS.steps_per_task)
  end
  for i, s in ipairs(steps) do
    if type(s) ~= "table" then return "step " .. i .. " must be a table" end
    local has_tool = type(s.tool) == "string"
    local has_task = type(s.task) == "string"
    if has_tool == has_task then
      return "step " .. i .. " needs exactly one of 'tool' or 'task'"
    end
    if s.args ~= nil and type(s.args) ~= "table" and type(s.args) ~= "function" then
      return "step " .. i .. " 'args' must be a table or function"
    end
  end
end

function M.define(name, spec, scope)
  if type(name) ~= "string" or not name:match("^[%a_][%w_]*$") then
    return nil, "task name must match [A-Za-z_][A-Za-z0-9_]*"
  end
  if type(spec) ~= "table" then return nil, "task spec must be a table" end
  local err = validate_steps(spec.steps)
  if err then return nil, err end
  M.tasks[name] = {
    description = spec.description or name,
    steps = spec.steps,
    scope = scope or "session",
  }
  return true
end

-- ---- execution -------------------------------------------------------------

local function resolve_args(step, ctx)
  local a = step.args
  if type(a) == "function" then return a(ctx) or {} end
  return a or {}
end

-- Run a task's steps in order. Returns { ok, trace, error, stopped_at }.
-- `trace` is the flat record of what actually ran, across nested tasks.
function M.run_task(name, opts)
  opts = opts or {}
  local dispatch = opts.dispatch or default_dispatch
  local ctx = opts.ctx or { results = {}, args = opts.args or {}, count = 0 }
  local trace = opts.trace or {}
  local depth = opts.depth or 0

  local t = M.tasks[name]
  if not t then
    return { ok = false, trace = trace, error = "unknown task: " .. tostring(name) }
  end
  if depth > M.LIMITS.depth then
    return { ok = false, trace = trace,
             error = string.format("task depth exceeded %d (cycle?)", M.LIMITS.depth) }
  end

  for i, step in ipairs(t.steps) do
    if step.when and not step.when(ctx) then
      trace[#trace + 1] = { kind = "skip", name = step.tool or step.task, task = name }
    else
      ctx.count = ctx.count + 1
      if ctx.count > M.LIMITS.steps then
        return { ok = false, trace = trace,
                 error = string.format("step budget exceeded %d", M.LIMITS.steps) }
      end

      if step.task then
        local sub = M.run_task(step.task, { dispatch = dispatch, ctx = ctx,
          trace = trace, depth = depth + 1, args = resolve_args(step, ctx) })
        if not sub.ok then
          return { ok = false, trace = trace, error = sub.error,
                   stopped_at = sub.stopped_at or (name .. "#" .. i) }
        end
      else
        local res = dispatch(step.tool, resolve_args(step, ctx))
        local failed = is_error(res)
        trace[#trace + 1] = { kind = "tool", name = step.tool, ok = not failed,
                              bytes = #tostring(res), head = head(res) }
        ctx.results[#ctx.results + 1] = res
        ctx.last = res
        if step.save then ctx[step.save] = res end
        if failed then
          return { ok = false, trace = trace, error = res,
                   stopped_at = name .. "#" .. i .. " (" .. step.tool .. ")" }
        end
      end
    end
  end
  return { ok = true, trace = trace }
end

-- ---- presentation ----------------------------------------------------------

local function format_run(name, r)
  local lines = {}
  local ran = 0
  for _, e in ipairs(r.trace) do
    if e.kind == "skip" then
      lines[#lines + 1] = string.format("  - %-6s %-16s skipped (guard)", "", e.name)
    else
      ran = ran + 1
      lines[#lines + 1] = string.format("  %d. %-4s %-16s %s%s", ran, "tool",
        e.name, e.ok and "ok" or "FAIL",
        e.bytes > 0 and string.format("  (%dB) %s", e.bytes, e.head) or "")
    end
  end
  local header = string.format("plan '%s' \226\128\148 %d step(s), %s", name, ran,
    r.ok and "ok" or ("stopped at " .. tostring(r.stopped_at)))
  local body = table.concat(lines, "\n")
  if not r.ok and r.error then body = body .. "\n" .. tostring(r.error) end
  return header .. (body ~= "" and ("\n" .. body) or "")
end

-- ---- the tools the model is offered ----------------------------------------
-- Registered into the tool registry by tools.lua, the same way memory tools are.

M.tools = {
  run_plan = {
    description = "Run a defined task: execute its ordered steps locally, with no "
      .. "model turn between them, and return a trace. This is one tool call that "
      .. "fires a whole known procedure. See 'tasks' for what is defined.",
    input_schema = { type = "object",
      properties = {
        task = { type = "string", description = "name of a defined task" },
        args = { type = "object", description = "inputs available to the task as ctx.args" },
      }, required = { "task" } },
    run = function(a)
      if type(a.task) ~= "string" then
        return "Tool error: [validation_error] run_plan requires 'task'"
      end
      if not M.tasks[a.task] then
        return "Tool error: [tool_not_found] no task named '" .. a.task .. "'"
      end
      local r = M.run_task(a.task, { args = a.args or {} })
      return format_run(a.task, r)
    end,
  },

  define_task = {
    description = "Define a reusable task: a name and an ordered list of steps, each "
      .. "either {tool=,args=} or {task=,args=}. Running it later fires every step "
      .. "with no model round trip between them -- a skill minus the per-step call. "
      .. "Use it when a sequence of tool calls recurs and needs no judgement between "
      .. "them; keep judgement in yourself and promote only the mechanics.",
    input_schema = { type = "object",
      properties = {
        name = { type = "string", description = "[A-Za-z_][A-Za-z0-9_]*" },
        description = { type = "string" },
        steps = { type = "array", description = "ordered [{tool|task, args}]",
          items = { type = "object" } },
      }, required = { "name", "steps" } },
    run = function(a)
      local ok, err = M.define(a.name, { description = a.description, steps = a.steps }, "session")
      if not ok then return "Tool error: [validation_error] " .. tostring(err) end
      return string.format("Defined task '%s' (%d steps, scope=session; will not persist).",
        a.name, #a.steps)
    end,
  },

  tasks = {
    description = "List defined tasks and their step counts.",
    input_schema = { type = "object", properties = {} },
    run = function()
      local names = {}
      for n in pairs(M.tasks) do names[#names + 1] = n end
      table.sort(names)
      if #names == 0 then return "(no tasks defined)" end
      local out = {}
      for _, n in ipairs(names) do
        local t = M.tasks[n]
        out[#out + 1] = string.format("%-20s %d step(s)  %s", n, #t.steps, t.description or "")
      end
      return table.concat(out, "\n")
    end,
  },
}

return M
