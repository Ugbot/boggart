-- workers.lua -- the friendly face of the C worker registry.
--
-- Tracking lives in C (src/lworker.c): worker.list()/count() walk the same
-- g_workers list the atexit handler uses, so they see every worker regardless
-- of who spawned it -- a worker started from another module, or from C, shows
-- up too. A Lua-side registry could only ever have seen what was spawned
-- through it, which is why the owner was right that this belongs in C.
--
-- This module adds only what the C layer has no reason to carry: a spawn that
-- defaults a label, and list()/count() re-exposed so callers use one table
-- (bog.worker) and never reach past it to the raw module.
local raw = require("worker")  -- the C module

local M = { raw = raw }

-- spawn(source, opts). opts.label and opts.kind are for display and are read by
-- C; on_message strings become the worker's `last` line automatically, so a
-- worker that reports its progress ("reading src/", "3 of 12") is legible in
-- the list with no extra wiring.
function M.spawn(source, opts)
  return raw.spawn(source, opts or {})
end

-- Every live (and recently finished) worker, newest first: the roster a UI or
-- `boggart doctor` draws. The C list is registry order; a stable sort by id
-- keeps rows from jumping as workers come and go.
function M.list()
  local out = raw.list()
  table.sort(out, function(a, b) return a.id > b.id end)
  return out
end

-- running, total -- the status-bar summary.
function M.count() return raw.count() end

-- Pass-throughs, so bog.worker is the whole surface. stop is cooperative; kill
-- preempts a runaway at the next Lua safepoint; pause/resume park it there.
function M.post(h, msg) return raw.post(h, msg) end
function M.recv(h, timeout) return raw.recv(h, timeout) end
function M.stop(h) return raw.stop(h) end
function M.kill(h) return raw.kill(h) end
function M.pause(h) return raw.pause(h) end
function M.resume(h) return raw.resume(h) end
function M.join(h) return raw.join(h) end
function M.status(h) return raw.status(h) end

-- How many workers to run in parallel by default: a local server's slot count if
-- we know it, else a small fixed pool. (Remote models have no such cap.)
function M.default_slots()
  local s = bog.api and bog.api.local_slots and bog.api.local_slots()
  if s and s > 0 then return s end
  return 4
end

-- map(fn_source, items[, opts]) -> results, errors, done
--
-- A real parallel-for over the OS-thread pool: `fn_source` is a Lua source
-- string that RETURNS a function; that function is applied to every item on a
-- pool of `slots` worker threads, and the results come back keyed by the item's
-- position. This is genuine parallelism (N threads, N cores), not the swarm's
-- cooperative one-loop concurrency.
--
-- It is built entirely on the fabric's work queues: items go onto an inbound
-- queue, each worker pulls-computes-pushes to an outbound queue, and this side
-- drains the outbound queue. push/pull are thread-safe FIFOs, so there is no
-- cross-thread callback and no uv loop to pump -- the workers run on their own
-- threads and this side just collects.
--
-- Items and results cross the thread boundary as JSON, so both must be
-- serializable (strings/numbers/plain tables; no functions or userdata).
--
-- Driven from inside a turn (a scheduler coroutine) it PARKS on a latch and lets
-- a uv timer collect the results, so it never stalls the scheduler. Called off
-- the scheduler (a plain script, a REPL one-shot) it blocks the calling thread
-- until every item is done, polling with a 1ms sleep. Either way it returns only
-- when the whole batch is in (or opts.timeout seconds elapse).
function M.map(fn_source, items, opts)
  opts = opts or {}
  assert(type(fn_source) == "string", "workers.map: fn_source must be a Lua source string")
  local n = items and #items or 0
  if n == 0 then return {}, {}, 0 end
  local json = require("json")
  local uv = require("uv")

  local slots = math.max(1, math.min(opts.slots or M.default_slots(), n))
  M._seq = (M._seq or 0) + 1
  local base = "workers.map." .. M._seq
  local inq, outq = base .. ".in", base .. ".out"

  for i, v in ipairs(items) do bus.push(inq, json.encode({ i = i, v = v })) end

  -- Each worker: pull an item, apply f, push the result; stop when the inbound
  -- queue is empty (all items are enqueued before any worker starts, so an empty
  -- pull means "done", never "not yet").
  local wsrc = ([=[
local json = require("json")
local f = (function() %s end)()
while true do
  local m = bus.pull(%q)
  if not m then return "ok" end
  local item = json.decode(m)
  local ok, r = pcall(f, item.v)
  bus.push(%q, json.encode({ i = item.i, ok = ok, r = ok and r or tostring(r) }))
end
]=]):format(fn_source, inq, outq)

  local pool = {}
  for _ = 1, slots do pool[#pool + 1] = raw.spawn(wsrc, { kind = "map", label = "map worker" }) end

  local results, errors, got = {}, {}, 0
  local deadline = os.time() + (opts.timeout or 30)
  local function collect_one()
    local m = bus.pull(outq)
    if not m then return false end
    local r = json.decode(m)
    if r.ok then results[r.i] = r.r else errors[r.i] = r.r end
    got = got + 1
    return true
  end

  if coroutine.isyieldable() and bog.sched then
    -- Scheduler-aware: a uv timer drains the outbound queue while this actor
    -- parks on a latch, so a map from inside a turn yields the scheduler instead
    -- of blocking it. The timer wakes us (sets .decision) once the batch is in.
    local latch = { decision = nil }
    local timer = uv.new_timer()
    timer:start(1, 2, function()
      while collect_one() do end
      if got >= n or os.time() > deadline then
        timer:stop(); timer:close(); latch.decision = true
      end
    end)
    while not latch.decision do coroutine.yield("block", latch) end
  else
    while got < n do
      if not collect_one() then
        if os.time() > deadline then break end
        uv.sleep(1)
      end
    end
  end

  for _, h in ipairs(pool) do raw.join(h) end
  return results, errors, got
end

return M
