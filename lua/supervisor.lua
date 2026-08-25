-- supervisor.lua -- the control plane, over the fabric bus. Every surface (the
-- cTUI, the swarm dashboard, the studio) used to poke bog.sched.pause/kill
-- directly; now they route control through here, so:
--   * control is OBSERVABLE -- every action is a "ctl:*" event on the bus, so
--     /trace, a UI, or the journal sees who paused/killed what;
--   * control is UNIFIED -- one path, one place that knows how to reach both a
--     swarm coroutine (bog.sched) and (later) a pool worker;
--   * control is DECOUPLED and cross-thread -- a command is a byte record on a
--     work queue, so any thread (a worker, eventually a remote) can enqueue one
--     and the main thread executes it in order.
--
-- This is where the two new bus primitives earn their keep together:
--   push/pull  -- the ordered MPMC command channel (bus.push/pull QUEUE)
--   pub/sub    -- the cross-thread wake ("supervisor.wake") + the ctl:* stream
--
-- The rule the whole runtime lives by: only the main thread touches bog.sched /
-- bog.thread. A command from another thread is a byte record; it is executed
-- here, on the main thread, when the wake drains the queue.
local json = require("json")

local M = {}
local QUEUE = "supervisor.cmd"

-- Execute one decoded command. MAIN THREAD ONLY (the pump guarantees it).
local function exec(c)
  local id = c.id
  if c.verb == "kill" then
    -- the operator kill: tells the parent first, so an await() unblocks
    if bog.thread and bog.thread.kill then bog.thread.kill(id)
    elseif bog.sched then bog.sched.kill(id) end
  elseif c.verb == "pause" then
    if bog.sched then bog.sched.pause(id, c.on) end
  elseif c.verb == "resume" then
    if bog.sched then bog.sched.pause(id, false) end
  elseif c.verb == "pause_fleet" then
    for _, a in ipairs((bog.sched and bog.sched.actors) or {}) do
      if a.id ~= c.except then bog.sched.pause(a.id, c.on) end
    end
  elseif c.verb == "kill_all" then
    for _, a in ipairs((bog.sched and bog.sched.actors) or {}) do bog.sched.kill(a.id) end
  elseif c.verb == "kill_worker" then
    -- a pool worker (lworker) by its handle, stashed by the caller
    if c._handle and worker and worker.kill then pcall(worker.kill, c._handle) end
  elseif c.verb == "pause_worker" then
    if c._handle and worker and worker.pause then pcall(worker.pause, c._handle) end
  elseif c.verb == "resume_worker" then
    if c._handle and worker and worker.resume then pcall(worker.resume, c._handle) end
  end
  -- Observability: every executed control action, on the bus.
  pcall(bus.publish, "ctl:" .. tostring(c.verb), json.encode(c))
end

-- Drain and execute every queued command, in order. Returns how many ran.
function M.pump()
  local n = 0
  while true do
    local m = bus.pull(QUEUE)
    if not m then break end
    local ok, c = pcall(json.decode, m)
    if ok and type(c) == "table" and c.verb then exec(c); n = n + 1 end
  end
  return n
end

-- install() -- called once from activate_agents. Subscribes the wake so a
-- command enqueued from any thread gets pumped on the main thread, and drains
-- anything queued before install. Idempotent.
function M.install()
  if M._installed then return end
  M._sub = bus.subscribe("supervisor.wake", function() M.pump() end)
  M._installed = true
  M.pump()
end

-- Enqueue a command and signal the pump. On the main thread the wake dispatches
-- synchronously, so the command executes before this returns; from a worker it
-- is a thread-safe push + a cross-thread wake the main loop drains. A command
-- table may carry non-serializable fields under keys starting with "_"; they
-- ride only the same-thread path (json drops them for a cross-thread record,
-- which is correct -- a handle is meaningless on another thread).
local function command(verb, fields)
  fields = fields or {}
  fields.verb = verb
  bus.push(QUEUE, json.encode(fields))
  pcall(bus.publish, "supervisor.wake", "")
  -- If nobody is installed to pump (a bare mode), execute inline so control
  -- still works; the queue drains here instead of via the wake subscriber.
  if not M._installed then M.pump() end
  return true
end

-- The verbs surfaces call.
function M.kill(id)               return command("kill", { id = id }) end
function M.pause(id, on)          return command("pause", { id = id, on = on ~= false }) end
function M.resume(id)             return command("resume", { id = id }) end
function M.pause_fleet(except, on) return command("pause_fleet", { except = except, on = on ~= false }) end
function M.kill_all()             return command("kill_all") end
function M.kill_worker(handle)    return command("kill_worker", { _handle = handle }) end
function M.pause_worker(handle)   return command("pause_worker", { _handle = handle }) end
function M.resume_worker(handle)  return command("resume_worker", { _handle = handle }) end

return M
