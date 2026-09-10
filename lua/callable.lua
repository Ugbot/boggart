-- callable.lua -- skills and tools as GameObjects.
--
-- A Callable is an entity with attached components, on the Unity model. The
-- entity has a name and shared state; components attach behavior; boggart is
-- the engine that calls their lifecycle hooks at defined moments. You extend a
-- skill by ATTACHING a component that owns one deterministic slice, not by
-- rewriting the skill.
--
-- Lifecycle, per invocation, across all attached components:
--   before(ctx)        deterministic setup, in attach order. A component may
--                      return { done = value } to short-circuit the whole
--                      invocation (the model is never called), or
--                      { set = {...} } to thread facts into ctx.
--   run(ctx)           the body. The first component with a run produces the
--                      value; a model-backed skill's run IS the model turn.
--   finally(ctx, res)  teardown/verify, in REVERSE order, ALWAYS runs (the
--                      finally of try/finally). May rewrite the result.
--
-- The entity is callable: node(args) runs the lifecycle. So the model invokes
-- a skill by name and any Lua invokes it identically; both go through one
-- path. Entities compose two ways, exactly as Unity does: components on one
-- object (aggregation), and objects in a pipeline (chain / then_).
--
-- get(name) is GetComponent; send(msg, ...) is SendMessage (broadcast to every
-- component that implements the message). Trust is the caller's: a component's
-- run crosses the permission gate through the same tools it calls, so "more
-- code, fewer model calls" is never "fewer safety checks".
local M = {}

local methods = {}
local mt = { __index = methods, __name = "callable" }

function M.is(v) return type(v) == "table" and getmetatable(v) == mt end

-- new{ name=, run=, before=, finally=, model=, ... } -> a Callable.
-- Any of run/before/finally given inline become the entity's first component.
function M.new(spec)
  spec = spec or {}
  local node = setmetatable({
    name = spec.name or "callable",
    components = {},
    state = {},
  }, mt)
  if spec.before or spec.run or spec.finally or spec.model then
    node:attach({
      name = spec.name or "main",
      before = spec.before, run = spec.run,
      finally = spec.finally, model = spec.model,
    })
  end
  return node
end

-- Attach a component (Unity AddComponent). A component is a table carrying any
-- of before/run/finally plus its own methods and message handlers. Returns the
-- node for chaining attaches.
function methods:attach(component)
  assert(type(component) == "table", "a component must be a table")
  component.name = component.name or ("component" .. (#self.components + 1))
  self.components[#self.components + 1] = component
  return self
end

-- GetComponent by name, or nil.
function methods:get(name)
  for _, c in ipairs(self.components) do
    if c.name == name then return c end
  end
end

-- SendMessage: call `msg` on every component that implements it, in attach
-- order, passing the node first so a handler can reach siblings. Returns the
-- last non-nil result.
function methods:send(msg, ...)
  local out
  for _, c in ipairs(self.components) do
    if type(c[msg]) == "function" then
      local r = c[msg](c, self, ...)
      if r ~= nil then out = r end
    end
  end
  return out
end

-- Normalize the invocation context. A plain args table or scalar is wrapped so
-- ctx.args is the input and ctx itself threads state between components.
local function as_ctx(input)
  if type(input) == "table" and input.__ctx then return input end
  local ctx = { __ctx = true, args = input, node = nil }
  if type(input) ~= "table" then ctx.args = input end
  return ctx
end

-- Invoke the lifecycle. before* (order) -> run (first that has one) -> finally*
-- (reverse). finally always runs, even on a raised error, then the error is
-- re-raised unless a finally replaced the result.
function methods:invoke(input)
  local ctx = as_ctx(input)
  ctx.node = self

  local function phase_before()
    for _, c in ipairs(self.components) do
      if c.before then
        local pre = c.before(ctx)
        if type(pre) == "table" then
          if pre.done ~= nil then return true, pre.done end   -- short-circuit
          if type(pre.set) == "table" then
            for k, v in pairs(pre.set) do ctx[k] = v end
          end
        end
      end
    end
    return false
  end

  local function phase_run()
    for _, c in ipairs(self.components) do
      if c.run then return c.run(ctx.args, ctx) end
    end
    return ctx.args   -- a node with only lifecycle passes its input through
  end

  local ok, res = pcall(function()
    local shorted, value = phase_before()
    if shorted then return value end
    return phase_run()
  end)

  -- finally runs in reverse, always, and sees (result, err).
  for i = #self.components, 1, -1 do
    local c = self.components[i]
    if c.finally then
      local fok, fres = pcall(c.finally, ctx, ok and res or nil, ok and nil or res)
      if fok and fres ~= nil then res, ok = fres, true end
    end
  end

  if not ok then error(res, 0) end
  return res
end

mt.__call = function(self, input) return self:invoke(input) end

-- ---- the interpreter: model as eval ---------------------------------------
--
-- Read this file as a small combinator language, Scheme-shaped: Callables are
-- values, and chain/first/cond/loop/then_/catch are the special forms. The
-- model call is `eval` -- the interpreter of last resort. Prose is quoted
-- intent; a Callable is compiled; every combinator you write is one more thing
-- that never reaches the interpreter. "More code, fewer model calls" is
-- compiling more of the language.
--
-- evaluator(prompt, opts) is the default eval, wired by the runtime to a real
-- model turn. Left nil in a headless test so model steps are injected and the
-- pure combinators stay testable without a model.
M.evaluator = nil

-- model(spec) -> the eval primitive: a Callable whose run evaluates intent with
-- the model. spec.prompt may be a string or function(args, ctx); spec.tools
-- scopes the turn; spec.evaluator overrides the default (for tests).
function M.model(spec)
  spec = spec or {}
  return M.new({
    name = spec.name or "model",
    model = true,
    run = function(args, ctx)
      local prompt = spec.prompt
      if type(prompt) == "function" then prompt = prompt(args, ctx) end
      prompt = prompt or (type(args) == "string" and args) or ""
      local ev = spec.evaluator or M.evaluator
      if not ev then error("no model evaluator wired (callable.evaluator is nil)", 0) end
      return ev(prompt, { tools = spec.tools, model = spec.model })
    end,
  })
end

-- cond{ {test, body}, ..., {else_body} } -> evaluate the body of the first
-- test that passes. Tests are CODE predicates over the input; only the chosen
-- body evaluates, so a body that is a model step spends a turn only when its
-- branch is taken. Routing with no model call. A one-element final clause is
-- the else.
function M.cond(clauses)
  return M.new({
    name = "cond",
    run = function(input)
      for _, clause in ipairs(clauses) do
        local test, body = clause[1], clause[2]
        if body == nil then return M.coerce(test)(input) end       -- else
        if M.coerce(test)(input) then return M.coerce(body)(input) end
      end
      return nil
    end,
  })
end

-- ---- composition (pipelines) ----------------------------------------------

-- self then next: run self, feed its result as next's input. Returns a new
-- Callable so chains are values you can pass around and call from anywhere.
function methods:then_(nxt)
  local a, b = self, M.coerce(nxt)
  return M.new({
    name = a.name .. ">" .. b.name,
    run = function(input) return b(a(input)) end,
  })
end

-- On a raised error in self, call handler(err, input) instead of propagating.
function methods:catch(handler)
  local a = self
  return M.new({
    name = a.name .. "?",
    run = function(input)
      local ok, res = pcall(a.invoke, a, input)
      if ok then return res end
      return handler(res, input)
    end,
  })
end

-- ---- verifiers: checking a result is real, with code ----------------------

-- verify(node, check) -> run node, then assert check(result) with CODE. check
-- returns true (ok), or false/nil/"reason" (fail). On failure it raises
-- "verify failed: <reason>", so an enclosing retry/catch/loop can react. This
-- is how a skill or tool result is checked for real -- a compiled contract, not
-- a model asking itself whether the output looks right. check gets a ctx whose
-- args and result are the produced value.
function M.verify(node, check)
  node, check = M.coerce(node), M.coerce(check)
  return M.new({
    name = node.name .. "#verified",
    run = function(input)
      local res = node(input)
      local ok = check({ result = res })
      if ok == true then return res end
      error("verify failed: " ..
        (type(ok) == "string" and ok or "check returned " .. tostring(ok)), 0)
    end,
  })
end

-- self:verify(check) -- method form.
function methods:verify(check) return M.verify(self, check) end

-- retry{ node, check?, max?, repair? } -> run node until it succeeds and (if
-- given) its result passes `check`, up to `max` times. A raise or a failed
-- check counts as a miss; `repair` (a Callable) runs between attempts with the
-- error/last result to fix state. Raises the last error if it never passes.
-- loop + verify + catch, as one contract: the retry decision is code, so a
-- flaky tool is re-driven without a model turn deciding to.
function M.retry(opts)
  local node = M.coerce(opts.node or opts.body or opts[1])
  local check = opts.check and M.coerce(opts.check)
  local repair = opts.repair and M.coerce(opts.repair)
  local max = opts.max or 3
  return M.new({
    name = node.name .. "*",
    run = function(input)
      local last_err
      for i = 1, max do
        local ok, res = pcall(node.invoke, node, input)
        if ok and check then
          local v = check({ result = res })
          if v ~= true then
            ok, res = false, "verify failed: " ..
              (type(v) == "string" and v or tostring(v))
          end
        end
        if ok then return res end
        last_err = res
        if repair and i < max then
          pcall(repair, { error = res, attempt = i, input = input })
        end
      end
      error(last_err or "retry exhausted", 0)
    end,
  })
end

-- Anything -> a Callable: pass a Callable through, wrap a function as its run,
-- wrap a spec table via new.
function M.coerce(v)
  if M.is(v) then return v end
  if type(v) == "function" then return M.new({ run = function(a) return v(a) end }) end
  if type(v) == "table" then return M.new(v) end
  error("cannot coerce " .. type(v) .. " to a callable")
end

-- chain(a, b, c, ...) -> a Callable running each in turn, threading results.
function M.chain(...)
  local nodes = { ... }
  local acc = M.coerce(nodes[1])
  for i = 2, #nodes do acc = acc:then_(nodes[i]) end
  return acc
end

-- loop{ body=, until_=, max=, on_stop= } -> a Callable that runs `body`
-- repeatedly, calling the stop-evaluation `until_` after each pass. `until_`
-- is CODE: it decides termination with no model call, which is the point.
-- Agentic loops (react-until-goal, ralph, swarm rounds) ask the model "are we
-- done?" every pass; a code stop-evaluation answers for free when it can, and
-- only a body that itself needs the model spends a turn. Stops on the first
-- truthy `until_`, or `max` passes (default 100, the runaway backstop).
--
-- until_ receives { i = pass number, last = the last result }, so a
-- stop-evaluation is a plain predicate over the loop state. Function or
-- Callable.
function M.loop(opts)
  local body = M.coerce(opts.body)
  local stop = opts.until_ and M.coerce(opts.until_)
  local max = opts.max or 100
  return M.new({
    name = "loop",
    run = function(input)
      local last = input
      for i = 1, max do
        last = body(last)
        if stop then
          local done = stop({ i = i, last = last })
          if done then return last end
        end
      end
      return last   -- hit the backstop; return the last result rather than hang
    end,
  })
end

-- first(a, b, c, ...) -> the fallback combinator (register_fallback, general).
-- Try each; a nil return or a "Tool error:" string is a miss and moves on; the
-- first real value wins. This is the tool-fallback pattern at the node layer.
function M.first(...)
  local nodes = { ... }
  return M.new({
    name = "first",
    run = function(input)
      local last
      for _, n in ipairs(nodes) do
        local c = M.coerce(n)
        local ok, res = pcall(c.invoke, c, input)
        if ok and res ~= nil
           and not (type(res) == "string" and res:find("^Tool error:")) then
          return res
        end
        last = ok and res or nil
      end
      return last
    end,
  })
end

return M
