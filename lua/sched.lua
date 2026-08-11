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

local M = {}

M.actors = {}        -- array of { id, co, status, req }
M.by_id = {}
local current_id = nil

function M.current() return current_id end
function M.alive(id) return M.by_id[id] ~= nil end
function M.count() return #M.actors end

function M.add(id, co)
  local a = { id = id, co = co, status = "runnable", req = nil }
  M.actors[#M.actors + 1] = a
  M.by_id[id] = a
  return a
end

local function remove(a)
  M.by_id[a.id] = nil
  for i, x in ipairs(M.actors) do
    if x == a then table.remove(M.actors, i); break end
  end
end

local function resume(a)
  current_id = a.id
  local ok, kind, arg = coroutine.resume(a.co)
  current_id = nil
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
    remove(a)
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

-- Run until every actor has finished (one-shot / per-turn drain), or should_stop.
function M.run(opts)
  opts = opts or {}
  local idle = 0
  M.fatal = nil
  while #M.actors > 0 do
    if opts.should_stop and opts.should_stop() then break end
    if M.fatal then break end

    -- Two things can be in flight: HTTP (curl_multi, via http.pump) and
    -- anything on the libuv loop -- subprocesses from lua/proc.lua, MCP stdio
    -- pipes, timers. Both must be advanced every iteration, or an actor
    -- waiting on one starves while the other is serviced.
    local io_wait, proc_wait, runnable = false, false, false
    for _, a in ipairs(M.actors) do
      if a.status == "io" then io_wait = true
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
    if runnable then
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
      if M.by_id[a.id] then
        if a.status == "runnable" or a.status == "io" or a.status == "proc" then
          resume(a); did = true
        elseif a.status == "recv" and swarm.pending(a.id) > 0 then
          a.status = "runnable"; resume(a); did = true
        end
      end
    end

    -- Quiescence guard: if nothing progressed and nothing is in flight, every
    -- remaining actor is blocked on mail that will never come. Bail rather than
    -- spin forever.
    if not did and not io_wait and not proc_wait then
      idle = idle + 1
      if idle > 3 then
        bog.log("scheduler idle with " .. #M.actors .. " blocked agent(s); stopping")
        break
      end
    else
      idle = 0
    end
  end
end

return M
