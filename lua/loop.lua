-- loop.lua -- a functional fold over a generator, exposed so an agent can kick
-- off the next X things in a row (a count, a list, or a drained source), doing
-- arbitrary work each time, with escape hatches.
--
-- The core is a tail-recursive fold (Lua has proper tail calls, so it runs in
-- constant stack and can recurse open-ended until the source dries up):
--
--   step(gen, ctx):
--     item, idx = gen()                       -- unfold: next item, or nil = done
--     if item == nil or stop(ctx) then return ctx end
--     ok, result = effect(item, idx, sess)    -- kick off anything (agent turn OR tool)
--     ctx.acc = reduce(ctx.acc, result, item) -- fold
--     return step(gen, ctx)                    -- proper tail call
--
--   count / list / source all collapse to one `next(state) -> item, idx | nil`.
--   the effect is any function; the tool wires `task` (a sub-agent turn) or
--   `tool`+args (a direct call). sequential is this fold; parallel is a worker
--   pool of <slots> that pull from the same generator (they simply stop pulling
--   once `until` passes -- that is the parallel early-stop).
local goal = require "goal"

local M = {}
M.DEFAULT_MAX = 20        -- iterations when neither `times` nor a list bounds it
M.HARD_MAX = 50           -- an absolute ceiling nothing may exceed

-- ---- sub-sessions ----------------------------------------------------------
local function sub_session(spec)
  return {
    model = spec.model or (bog.session and bog.session.model),
    messages = {}, max_tokens = 16000,
    effort = spec.effort, token_budget = spec.token_budget,
  }
end

-- ---- interpolation: {item} {i} {prev} in a template ------------------------
local function interp(s, item, idx, prev)
  if type(s) ~= "string" then return s end
  return (s:gsub("{(%w+)}", function(k)
    if k == "item" then return tostring(item)
    elseif k == "i" then return tostring(idx)
    elseif k == "prev" then return tostring(prev or ""):sub(1, 2000)
    else return "{" .. k .. "}" end
  end))
end
local function interp_args(v, item, idx, prev)
  if type(v) == "string" then return interp(v, item, idx, prev) end
  if type(v) == "table" then
    local out = {}
    for k, x in pairs(v) do out[k] = interp_args(x, item, idx, prev) end
    return out
  end
  return v
end

-- ---- generators: next() -> item, idx | nil ---------------------------------
local function make_gen(spec)
  if spec.over ~= nil then
    local items, i = spec.over, 0
    return function() i = i + 1; local v = items[i]; if v == nil then return nil end; return v, i end
  elseif spec.source ~= nil then
    local i = 0
    return function()
      i = i + 1
      local ok, v = pcall(spec.source)
      if not ok or v == nil then return nil end
      return v, i
    end
  else
    local n = math.floor(tonumber(spec.times) or spec.max or M.DEFAULT_MAX)
    local i = 0
    return function() i = i + 1; if i > n then return nil end; return i, i end  -- count: item = index
  end
end

-- ---- the per-item effect: any fn(item, idx, sess) -> ok, result ------------
local function make_effect(spec)
  if spec.iterate then return spec.iterate end            -- test / caller-supplied
  if spec.tool then                                       -- a direct tool call
    -- Gate per-item tool calls the same way run_on gates a normal call, so a
    -- loop over `bash`/`write` is no less governed than calling them directly.
    local runtool = (bog.perm and bog.perm.wrap_run and bog.perm.wrap_run(bog.tools.run, bog.perm.state()))
      or bog.tools.run
    return function(item, idx, _sess, prev)
      local base = spec.args or (type(item) == "table" and item) or { input = item }
      local args = interp_args(base, item, idx, prev)
      local ok, res = pcall(runtool, spec.tool, args)
      local text = tostring(res)
      local bad = (not ok) or (type(res) == "string" and res:find("^Tool error:"))
      return not bad, ok and text or ("tool error: " .. text)
    end
  end
  return function(item, idx, sess, prev)                  -- an agent sub-turn
    local prompt = interp(spec.task, item, idx, prev)
    local note = spec._model_judged
      and ("\n\nWhen the WHOLE task (all items) is complete, end your reply with "
           .. goal.SENTINEL .. " on its own line -- not before.") or ""
    local out = {}
    local ok, err = pcall(bog.api.run_on, sess, prompt .. note, function(c)
      out[#out + 1] = c; if spec.on_text then spec.on_text(c) end
    end, { effort = spec.effort, token_budget = spec.token_budget })
    return ok, ok and table.concat(out) or tostring(err)
  end
end

-- ---- per-item verify + retry ----------------------------------------------
-- verify is a done-check ({shell}/{exists}/{fact}) interpolated per item; a
-- failing item is redone up to max_retries before it counts as a failure.
local function run_item(spec, effect, item, idx, sess, prev)
  local retries = math.max(0, math.floor(tonumber(spec.max_retries) or (spec.verify and 1 or 0)))
  local ok, result
  for _ = 0, retries do
    ok, result = effect(item, idx, sess, prev)
    local passed = ok
    if ok and spec.verify then
      local v = interp_args(spec.verify, item, idx, result)
      local checker = goal.compile(v)
      passed = checker()
    end
    if passed then return true, result end
  end
  return false, result
end

-- ---- reduce: default appends the result ------------------------------------
local function default_reduce(acc, result) acc[#acc + 1] = result; return acc end

-- ---- sequential: the tail-recursive fold -----------------------------------
local function fold_seq(spec, ctx)
  if ctx.met or ctx.count >= ctx.cap then return ctx end
  local item, idx = ctx.gen()
  if item == nil then ctx.detail = ctx.detail or "source exhausted"; return ctx end
  ctx.count = ctx.count + 1
  local sess = spec.fresh and sub_session(spec) or ctx.shared
  -- {prev} is the previous item's result; read it from `results` (always a list)
  -- so a custom `reduce` that folds acc to a non-table can't break it.
  local pr = ctx.count > 1 and ctx.results[ctx.count - 1]
  local prev = pr and pr.text or nil
  local ok, result = run_item(spec, ctx.effect, item, idx, sess, prev)
  ctx.acc = ctx.reduce(ctx.acc, result, item, idx)
  ctx.results[ctx.count] = { ok = ok, item = item, text = tostring(result) }
  if not ok then
    ctx.failures = ctx.failures + 1
    if ctx.failures > ctx.allowed then
      ctx.detail = string.format("stopped after %d failure(s) (%s allowed)", ctx.failures,
        ctx.allowed == math.huge and "unlimited" or tostring(ctx.allowed))
      return ctx
    end
  end
  if ctx.check then ctx.met, ctx.detail = ctx.check()
  elseif spec._model_judged and ok and tostring(result):find(goal.SENTINEL, 1, true) then
    ctx.met, ctx.detail = true, "the agent reported the whole task complete"
  end
  return fold_seq(spec, ctx)   -- proper tail call -> constant stack
end

-- ---- parallel: a worker pool that shares one generator ---------------------
-- <slots> workers each pull the next item and run the effect concurrently on the
-- scheduler; they stop pulling the instant `until` passes (the parallel
-- early-stop) or the failure budget is spent. Independent items only -- there is
-- no ordering or shared memory across a parallel run.
local worker_seq = 0
local function map_par(spec, ctx, slots)
  local latch, alive = { decision = nil }, 0
  local mutex = false   -- cooperative: one worker pulls/reduces at a time (single uv thread)

  local function worker()
    while not ctx.met and ctx.count < ctx.cap do
      -- pull the next item (atomic on the one loop; no real race)
      local item, idx = ctx.gen()
      if item == nil then break end
      ctx.count = ctx.count + 1
      local myidx = ctx.count
      local ok, result = run_item(spec, ctx.effect, item, idx, sub_session(spec), nil)
      ctx.acc = ctx.reduce(ctx.acc, result, item, idx)
      ctx.results[myidx] = { ok = ok, item = item, text = tostring(result) }
      if not ok then
        ctx.failures = ctx.failures + 1
        if ctx.failures > ctx.allowed then ctx.met, ctx.detail = true,
          string.format("stopped after %d failure(s)", ctx.failures); break end
      end
      if ctx.check then ctx.met, ctx.detail = ctx.check() end
    end
    alive = alive - 1
    if alive == 0 then latch.decision = true end
  end

  for _ = 1, math.max(1, slots) do
    alive = alive + 1
    worker_seq = worker_seq + 1
    bog.sched.add(-770000 - worker_seq, coroutine.create(worker))
  end
  -- Park until the pool drains (the scheduler drives the workers meanwhile).
  while alive > 0 do coroutine.yield("block", latch) end
  return ctx
end

-- ---- the supervisor --------------------------------------------------------
-- spec = { times|over|source, max, task|tool|args|iterate, parallel, fresh,
--          until_, stop_on_error, max_failures, verify, max_retries,
--          effort, token_budget, reduce, model, on_text }
function M.run(spec)
  assert(type(spec) == "table", "loop.run needs a spec")
  assert(spec.task or spec.tool or spec.iterate, "loop needs a `task`, a `tool`, or an iterate fn")

  local cap
  if spec.over then cap = #spec.over
  elseif spec.times then cap = math.floor(tonumber(spec.times))
  else cap = math.floor(tonumber(spec.max) or M.DEFAULT_MAX) end
  cap = math.max(1, math.min(M.HARD_MAX, tonumber(spec.max) and math.min(cap, tonumber(spec.max)) or cap))

  local check = spec.until_ ~= nil and goal.compile(spec.until_) or nil
  spec._model_judged = (check == nil) and (spec.task ~= nil) and not spec.tool

  local allowed
  if spec.max_failures ~= nil then allowed = math.max(0, math.floor(tonumber(spec.max_failures) or 0))
  elseif spec.stop_on_error == false then allowed = math.huge
  else allowed = 0 end

  local ctx = {
    gen = make_gen(spec),
    effect = make_effect(spec),
    reduce = spec.reduce or default_reduce,
    check = check, cap = cap, allowed = allowed,
    acc = spec.init ~= nil and spec.init or {},   -- {} for the default collect; any type for a custom reduce
    results = {}, count = 0, failures = 0, met = false, detail = nil,
    shared = (not spec.fresh) and sub_session(spec) or nil,
  }

  if check then ctx.met, ctx.detail = check() end   -- may already hold

  -- Keep an iteration from auto-delegating (the loop IS the orchestration).
  local dsave = bog.dispatch and bog.dispatch.depth
  if bog.dispatch then bog.dispatch.depth = (dsave or 0) + 1 end

  if spec.parallel and not ctx.met then
    local slots = (bog.api and bog.api.local_slots and bog.api.local_slots()) or spec.slots or 4
    map_par(spec, ctx, math.min(slots, cap))
  else
    fold_seq(spec, ctx)
  end

  if bog.dispatch then bog.dispatch.depth = dsave end

  return {
    iterations = ctx.count, met = ctx.met, failures = ctx.failures,
    detail = ctx.detail, acc = ctx.acc, results = ctx.results, cap = cap,
  }
end

return M
