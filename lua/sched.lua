-- sched.lua -- the cooperative scheduler (the only non-C scheduling code).
-- Drives agent coroutines: resume them, inspect why they yielded, pump async
-- HTTP, and deliver mail (via the C swarm bus) until the actor set drains.
--
-- Yield protocol (from lua/thread.lua + lua/api.lua stream_async / await):
--   coroutine.yield("recv")       -- blocked until this agent has mail
--   coroutine.yield("io", req)    -- blocked until an http request progresses
--   coroutine.yield("proc", h)    -- blocked until a child process progresses
--   (return)                      -- the agent finished
local uv = require("uv")
local events = require("events")

local M = {}

M.actors = {}        -- array of { id, co, status, req, paused }
M.by_id = {}
M.idle = 0           -- consecutive iterations in which nothing progressed
local current_id = nil

function M.current() return current_id end
function M.alive(id) return M.by_id[id] ~= nil end
function M.count() return #M.actors end

-- The actor lifecycle events are emitted here rather than in thread.lua
-- because this is where the lifecycle actually is: every actor arrives through
-- add() (the coordinator included, which thread.spawn never sees) and every
-- way of leaving -- finished, crashed, killed -- goes through remove(). The
-- payload is just the id, which is also the thread/session row id, so a
-- handler that wants the agent's name or transcript can ask bog.store for it.
function M.add(id, co)
  local a = { id = id, co = co, status = "runnable", req = nil }
  M.actors[#M.actors + 1] = a
  M.by_id[id] = a
  events.emit("swarm:actor_started", { id = id })
  return a
end

local function remove(a, reason)
  M.by_id[a.id] = nil
  for i, x in ipairs(M.actors) do
    if x == a then table.remove(M.actors, i); break end
  end
  -- Every exit path runs through here, so this is the one place an agent's
  -- file claims are guaranteed to be let go -- finished, crashed or killed
  -- alike. Without it a crashed agent would hold a file forever and its peers
  -- would route around a claim nobody is honouring.
  if bog and bog.claims then pcall(bog.claims.release_all, a.id) end
  events.emit("swarm:actor_stopped", { id = a.id, reason = reason or "done" })
end

local function resume(a)
  current_id = a.id
  -- The acting agent's identity, for anything that asks "who am I" without a
  -- handle on the scheduler -- claims and the blackboard, so a file one agent
  -- edits is attributed to that agent and not to whatever session id happened
  -- to be lying around. Set around the resume only; nil between actors so
  -- work outside a turn has no false owner.
  if bog then bog.current_agent = a.id end
  local ok, kind, arg = coroutine.resume(a.co)
  current_id = nil
  if bog then bog.current_agent = nil end
  if not ok then
    local err = kind -- on failure the second return value is the error
    if type(err) == "table" and err.boggart_error then
      -- A diagnosed condition rather than a crash. Say so in those terms, and
      -- if it is fatal (no credentials, unreachable endpoint) stop the whole
      -- run: every other agent is about to fail identically, and N copies of
      -- the same explanation helps nobody.
      bog.log(string.format("agent %s: %s", tostring(a.id), err.message))
      if err.fatal and not M.fatal then
        M.fatal = err
        for _, other in ipairs(M.actors) do other.status = "stopping" end
      end
    else
      bog.log(string.format("agent %s crashed: %s", tostring(a.id), tostring(err)))
    end
    remove(a, "crashed")
    return
  end
  if coroutine.status(a.co) == "dead" then
    remove(a)
    return
  end
  if kind == "recv" then a.status = "recv"; a.req = nil
  elseif kind == "io" then a.status = "io"; a.req = arg
  elseif kind == "proc" then a.status = "proc"; a.req = arg
  else a.status = "runnable"; a.req = nil end
end

-- Stop resuming one actor without discarding it. Its coroutine keeps whatever
-- it was in the middle of; anything already in flight for it (an HTTP request,
-- a child process) still completes, because those engines are shared and are
-- pumped for everybody. So "paused" means exactly "the scheduler will not
-- resume this one", and nothing stronger.
function M.pause(id, on)
  local a = M.by_id[id]
  if not a then return false end
  a.paused = (on ~= false) or nil
  return true
end

-- Drop an actor. Its coroutine is never resumed again and is collected with
-- the rest of its frame; there is no way to unwind a suspended coroutine in
-- Lua, so this is as close to "kill" as the language gets. Persisted state
-- (the thread row's status) is the caller's business -- the scheduler has no
-- opinion about what a killed agent should look like in the store.
function M.kill(id)
  local a = M.by_id[id]
  if not a then return false end
  remove(a, "killed")
  return true
end

-- Resume every actor that can move *right now*: a runnable one, a recv-blocked
-- one that has mail waiting, and every io/proc actor (each drains whatever the
-- loop has already buffered for it, then re-parks if there is no more). This
-- touches only coroutines -- it never runs the uv loop. Advancing the loop
-- (draining ready IO, or sleeping until the next event) is the driver's job,
-- because only the driver knows whether it is allowed to block. Returns whether
-- any actor ran.
local function resume_sweep()
  local snap = {}
  for _, a in ipairs(M.actors) do snap[#snap + 1] = a end
  local did = false
  for _, a in ipairs(snap) do
    if M.by_id[a.id] and not a.paused then
      if a.status == "runnable" or a.status == "io" or a.status == "proc" then
        resume(a); did = true
      elseif a.status == "recv" and swarm.pending(a.id) > 0 then
        a.status = "runnable"; resume(a); did = true
      end
    end
  end
  return did
end

-- What is the actor set waiting on, after a sweep? runnable => someone can run
-- without any new IO (a fresh coroutine, or recv with mail already queued);
-- in_flight => someone is parked on a live uv handle (an http socket, a child, an
-- MCP pipe) that will fire a callback when it progresses.
local function classify()
  local runnable, in_flight, paused = false, false, false
  for _, a in ipairs(M.actors) do
    if a.paused then paused = true
    elseif a.status == "io" or a.status == "proc" then in_flight = true
    elseif a.status == "runnable" then runnable = true
    elseif a.status == "recv" and swarm.pending(a.id) > 0 then runnable = true end
  end
  return runnable, in_flight, paused
end
M.classify = classify

-- One scheduler iteration. The whole point is the *order*: resume first, decide
-- to sleep second. Draining a just-completed request before we ever consider
-- blocking is what stops us from sleeping forever on a socket that already
-- closed. Then:
--   * someone still runnable  -> drain ready IO without sleeping and come back
--     (so a CPU-bound actor never starves an io peer of loop time);
--   * nobody runnable, IO in flight -> sleep in ONE unbounded uv.run("once"):
--     it returns the instant any handle fires, so a stream flows at full socket
--     speed with zero CPU while idle -- no fixed quantum, no polling;
--   * nobody runnable, nothing in flight -> the set is wedged on mail that will
--     never come; count it and bail.
-- block=false is for a caller that owns its own loop/frame (the studio's SDL
-- clock, the cTUI's uv.run): never sleep here, just drain what is ready.
--
-- All IO -- http (curl-on-uv), subprocesses, MCP, timers -- lives on the one
-- loop, so "advance IO" is simply running that loop; there is no separate pump.
function M.step(block)
  if #M.actors == 0 then return false end

  if not block then
    -- The caller will block elsewhere. Drain whatever the loop has ready, then
    -- resume, so this frame's arrivals reach their actors this frame.
    uv.run("nowait")
    if resume_sweep() then M.idle = 0 end
    return not M.fatal and #M.actors > 0
  end

  resume_sweep()
  if #M.actors == 0 or M.fatal then return false end

  local runnable, in_flight, paused = classify()
  if runnable then
    uv.run("nowait")   -- someone can run; service IO without sleeping, loop again
    M.idle = 0
  elseif in_flight then
    uv.run("once")     -- nothing runnable; sleep until a uv handle wakes us
    M.idle = 0
  elseif not paused then
    M.idle = M.idle + 1
    if M.idle > 3 then
      bog.log("scheduler idle with " .. #M.actors .. " blocked agent(s); stopping")
      return false
    end
  end

  return not M.fatal and #M.actors > 0
end

-- Run until every actor has finished (one-shot / per-turn drain), or should_stop.
-- The blocking drive: step(true) sleeps in the unified loop until IO. Right for
-- any caller that owns no frame -- the CLI one-shot, --headless, the between-turns
-- REPL, swarm mode. A caller that must also paint or read keys drives its own
-- loop instead (see lua/tui.lua): same resume_sweep, its own uv.run.
function M.run(opts)
  opts = opts or {}
  M.fatal, M.idle = nil, 0
  while #M.actors > 0 do
    if opts.should_stop and opts.should_stop() then break end
    if M.fatal then break end
    if not M.step(true) then break end
  end
end

-- Resume all ready actors without touching the loop -- the primitive a caller
-- that owns the loop (the cTUI) uses between its own uv.run and its paint.
function M.resume_ready() return resume_sweep() end

return M
