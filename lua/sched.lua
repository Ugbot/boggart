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

-- One scheduler iteration: advance the engines, resume whoever can, notice
-- quiescence. Split out of M.run so something that already owns a frame loop
-- can drive the swarm a slice at a time -- studio/data/core/swarmview.lua
-- calls step(false) once per frame and must never block, while the CLI calls
-- step(true) and is allowed to sleep inside libuv until something happens.
--
-- Returns false when stepping again would be pointless: the actor set has
-- drained, a fatal condition was diagnosed, or everything left is wedged.
function M.step(block)
  if #M.actors == 0 then return false end

  -- Two things can be in flight: HTTP (curl_multi, via http.pump) and
  -- anything on the libuv loop -- subprocesses from lua/proc.lua, MCP stdio
  -- pipes, timers. Both must be advanced every iteration, or an actor
  -- waiting on one starves while the other is serviced.
  local io_wait, proc_wait, runnable, paused = false, false, false, false
  for _, a in ipairs(M.actors) do
    if a.paused then paused = true
    elseif a.status == "io" then io_wait = true
    elseif a.status == "proc" then proc_wait = true
    elseif a.status == "runnable" then runnable = true
    elseif a.status == "recv" and swarm.pending(a.id) > 0 then runnable = true end
  end

  -- Whether we may *block* here is the whole question. If any actor can make
  -- progress right now, blocking would starve it -- so advance both engines
  -- without waiting. Only when every actor is parked on something external
  -- is it correct to sleep, and then we let the wait happen inside libuv
  -- (uv.run("once") returns the instant a handle fires) rather than burning
  -- a fixed 50ms, so a child's output is picked up immediately.
  --
  -- A caller that owns a frame loop never gets to make that trade: a 50ms
  -- http.pump is three dropped frames and uv.run("once") is unbounded, so it
  -- polls both engines and comes back next frame.
  if not block then
    if proc_wait then uv.run("nowait") end
    if io_wait then http.pump(0) end
  elseif runnable then
    if proc_wait then uv.run("nowait") end
    if io_wait then http.pump(0) end
  elseif proc_wait then
    uv.run("once")
    if io_wait then http.pump(0) end
  elseif io_wait then
    http.pump(50)
    uv.run("nowait")
  end

  local did = false
  local snap = {}
  for _, a in ipairs(M.actors) do snap[#snap + 1] = a end
  for _, a in ipairs(snap) do
    if M.by_id[a.id] and not a.paused then
      if a.status == "runnable" or a.status == "io" or a.status == "proc" then
        resume(a); did = true
      elseif a.status == "recv" and swarm.pending(a.id) > 0 then
        a.status = "runnable"; resume(a); did = true
      end
    end
  end

  -- Quiescence guard: if nothing progressed and nothing is in flight, every
  -- remaining actor is blocked on mail that will never come. Bail rather than
  -- spin forever. A paused actor is not evidence of that -- it is a human
  -- holding the swarm still, and it can be resumed.
  if not did and not io_wait and not proc_wait and not paused then
    M.idle = M.idle + 1
    if M.idle > 3 then
      bog.log("scheduler idle with " .. #M.actors .. " blocked agent(s); stopping")
      return false
    end
  else
    M.idle = 0
  end

  return not M.fatal and #M.actors > 0
end

-- Run until every actor has finished (one-shot / per-turn drain), or should_stop.
function M.run(opts)
  opts = opts or {}
  M.fatal, M.idle = nil, 0
  while #M.actors > 0 do
    if opts.should_stop and opts.should_stop() then break end
    if M.fatal then break end
    if not M.step(true) then break end
  end
end

return M
