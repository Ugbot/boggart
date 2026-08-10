-- sched.lua -- the cooperative scheduler (the only non-C scheduling code).
-- Drives agent coroutines: resume them, inspect why they yielded, pump async
-- HTTP, and deliver mail (via the C swarm bus) until the actor set drains.
--
-- Yield protocol (from lua/thread.lua + lua/api.lua stream_async / await):
--   coroutine.yield("recv")       -- blocked until this agent has mail
--   coroutine.yield("io", req)    -- blocked until an http request progresses
--   (return)                      -- the agent finished
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
    bog.log(string.format("agent %s crashed: %s", tostring(a.id), tostring(kind)))
    remove(a)
    return
  end
  if coroutine.status(a.co) == "dead" then
    remove(a)
    return
  end
  if kind == "recv" then a.status = "recv"; a.req = nil
  elseif kind == "io" then a.status = "io"; a.req = arg
  else a.status = "runnable"; a.req = nil end
end

-- Run until every actor has finished (one-shot / per-turn drain), or should_stop.
function M.run(opts)
  opts = opts or {}
  local idle = 0
  while #M.actors > 0 do
    if opts.should_stop and opts.should_stop() then break end

    local io_wait = false
    for _, a in ipairs(M.actors) do if a.status == "io" then io_wait = true; break end end
    if io_wait then http.pump(50) end -- advance all in-flight transfers (throttles the loop)

    local did = false
    local snap = {}
    for _, a in ipairs(M.actors) do snap[#snap + 1] = a end
    for _, a in ipairs(snap) do
      if M.by_id[a.id] then
        if a.status == "runnable" or a.status == "io" then
          resume(a); did = true
        elseif a.status == "recv" and swarm.pending(a.id) > 0 then
          a.status = "runnable"; resume(a); did = true
        end
      end
    end

    -- Quiescence guard: if nothing progressed and nothing is in flight, every
    -- remaining actor is blocked on mail that will never come. Bail rather than
    -- spin forever.
    if not did and not io_wait then
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
