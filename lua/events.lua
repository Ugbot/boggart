-- events.lua -- autocommands: named events, glob patterns, and handlers the
-- harness calls. Taken from Neovim's autocmd system (:h autocmd,
-- nvim_create_autocmd) and its vim.notify.
--
-- Everything else in boggart runs one way round: the agent calls a tool, the
-- agent draws a panel, the agent writes a file. This is the inversion -- user
-- or generated Lua registers interest in something and the harness calls *it*.
-- That is the difference between a scriptable program and a program with a
-- plugin folder, and it is the first extension point generated Lua can use to
-- react rather than only act.
--
-- Two deliberate simplifications against nvim's model:
--   * one glob namespace ("tool:*") rather than event + pattern pairs. nvim
--     keys its patterns on file names; boggart has nothing comparable to key
--     on, so the event name carries the whole hierarchy itself.
--   * no augroups. on() returns a handle you keep and hand to off(), which is
--     the only lifecycle anything here has wanted.
local M = {}

-- The messaging-fabric bridge (src/lbus.c, the global `bus`). Every emit is
-- mirrored onto the C bus as bytes so a trace, the journal, or (later) a
-- cross-thread subscriber sees ONE unified stream -- "the bus is observability"
-- from docs/actors-and-bus.md. The mirror is guarded by bus.has(name): when
-- nobody is subscribed on the fabric it costs a single C call and serializes
-- nothing. Captured with rawget so a state without the module (a stubbed worker)
-- simply skips the mirror.
local json = require("json")
local _bus = rawget(_G, "bus")
local function bus_wants(name)
  return _bus ~= nil and _bus.has(name)
end
local function bus_mirror(name, data)
  local ok, enc = pcall(json.encode, data == nil and {} or data)
  if ok then pcall(_bus.publish, name, enc) end
end

-- ---------------------------------------------------------------------------
-- Registrations outlive a harness reload
--
-- They hang off `bog` rather than off this module because /reload (and the
-- `reload` tool) re-requires every core module: a reload that silently
-- unsubscribed everything registered three turns ago would be a trap, not a
-- feature. Files under ~/.boggart/lua/events/ are the deliberate exception --
-- those are re-read on every load, because re-reading edited overlay files is
-- exactly what reload is for.
local state = bog.__events
if not state then
  state = { handlers = {}, next_id = 1, count = 0, depth = 0 }
  bog.__events = state
end
-- A reload can happen from inside a handler (the `reload` tool is a tool like
-- any other), which would otherwise leave the recursion guard armed forever.
state.depth = 0

-- Resolution cache: event name -> ordered list of matching handlers. Wildcards
-- are matched once per name, not once per emit. Cleared whenever the
-- registration set changes, which is rare; emits are not.
local cache = {}

-- Depth cap for handlers that emit (or notify) their way back into themselves.
-- Small on purpose: a legitimate chain is one or two deep, and anything longer
-- is a loop nobody wants to debug from inside a turn.
local MAX_DEPTH = 8
-- A handler that has thrown this many times is broken, not unlucky. Keeping it
-- subscribed to something like turn:text would mean one traceback per streamed
-- token for the rest of the session.
local MAX_ERRORS = 5
M.HANDLER_INSTRUCTIONS = 5e6
local HANDLER_CHECK_EVERY = 10000
local HANDLER_LIMIT = "event handler instruction budget exceeded"

-- Compose a handler limit with the emitter's active hook. Hooks are per
-- coroutine and Lua provides one slot, so replacing it would disable an outer
-- tool/workflow budget while the callback runs.
local function handler_hook(thread)
  local parent, mask, count = debug.gethook()
  local ticks, parent_ticks = 0, 0
  local control = { outer_failure = nil, handler_failure = nil }
  local quantum = HANDLER_CHECK_EVERY
  if parent and count and count > 0 then
    local a, b = quantum, count
    while b ~= 0 do a, b = b, a % b end
    quantum = a
  end
  local function call_parent(event, line)
    if control.outer_failure ~= nil then
      error({ boggart_outer_hook = true, error = control.outer_failure }, 0)
    end
    local ok, err = pcall(parent, event, line)
    if not ok then
      if type(err) == "table" and err.boggart_outer_hook then err = err.error end
      if type(err) == "table" and err.error ~= nil and err.marker ~= nil then err = err.error end
      control.outer_failure = err
      error({ boggart_outer_hook = true, error = err }, 0)
    end
  end
  local function hook(event, line)
    if event == "count" then
      ticks = ticks + quantum
      if ticks > M.HANDLER_INSTRUCTIONS then
        control.handler_failure = control.handler_failure or HANDLER_LIMIT
        error(control.handler_failure, 0)
      end
      if parent and count > 0 then
        parent_ticks = parent_ticks + quantum
        if parent_ticks >= count then
          parent_ticks = parent_ticks - count
          call_parent(event, line)
        end
      end
    elseif parent then
      call_parent(event, line)
    end
  end
  if thread then debug.sethook(thread, hook, mask or "", quantum)
  else debug.sethook(hook, mask or "", quantum) end
  return control
end

-- ---------------------------------------------------------------------------
-- The events the harness emits, and what rides on them.
--
-- Payloads are small on purpose. An event carrying a whole transcript is one
-- nobody can afford to subscribe to, so handlers get identifiers and sizes and
-- fetch the rest themselves (bog.session, bog.store) if they really want it.
M.EVENTS = {
  ["store:created"]    = "{ path }  the local store did not exist and was created (first run)",
  ["store:recovered"]  = "{ path, moved_to }  a damaged store was moved aside and recreated -- sessions and memory in it are gone",
  ["session:new"]      = "{}      a conversation was started (no row yet)",
  ["session:created"]  = "{ id }  a fresh session row exists",
  ["session:resumed"]  = "{ id, count }  count = messages restored",
  ["session:saved"]    = "{ id, count }  transcript persisted to the store",
  ["turn:start"]       = "{ session, preview, chars }  preview = first 200 chars of the user text",
  ["turn:text"]        = "{ session, text }  one streamed assistant text delta (hot: fires per SSE chunk)",
  ["turn:end"]         = "{ session, stop }  stop = end_turn/max_tokens/refusal/...",
  ["turn:error"]       = "{ session, message, kind }  kind is set for typed api errors (api.ERR.*)",
  ["tool:before"]      = "{ name, input, invocation_id }  observation; input is an isolated copy",
  ["tool:authorize"]   = "{ name, input, invocation_id }  return deny to veto; distinct from observation",
  ["tool:after"]       = "{ name, error, bytes }  error = the tool returned a 'Tool error:' result",
  ["tool:refused"]     = "{ name, reason }  a permission gate refused the call; it never ran",
  ["context:compacted"] = "{ session, before, after }  chars of transcript before, chars of summary",
  ["file:write"]       = "{ path, bytes, lines }  the write tool created/overwrote a file",
  ["file:edit"]        = "{ path, bytes }  the edit tool replaced a span; bytes = the new file size",
  ["swarm:actor_started"] = "{ id }  an actor joined the scheduler (id = its thread/session id)",
  ["swarm:actor_stopped"] = "{ id, reason }  reason = done | crashed | killed",
  ["notify"]           = "{ msg, level }  something wants a human to see it (see events.notify)",
}

-- ---------------------------------------------------------------------------
-- Patterns
--
-- Globs, not Lua patterns: `*` is the only metacharacter and everything else is
-- literal. "tool:*" is what a user will type, and "%w+:%w+" is not.
local function compile(pattern)
  local lit = (pattern:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"))
  return "^" .. (lit:gsub("%*", ".*")) .. "$"
end

local function resolve(name)
  local hs = {}
  for _, h in ipairs(state.handlers) do
    if name:match(h.rx) then hs[#hs + 1] = h end
  end
  cache[name] = hs
  return hs
end

-- ---------------------------------------------------------------------------
-- Running one handler
--
-- Handlers are isolated two ways, and the second is the one that matters here.
--
-- Throwing: a handler that raises must not break the emitter or stop the
-- handlers behind it. bog.try would cover that on its own.
--
-- Yielding: bog.try would NOT cover it. xpcall is yieldable in 5.4/5.5, so a
-- handler that reached sys.exec (or coroutine.yield directly) under the swarm
-- scheduler would suspend the *emitter's* coroutine and hand sched.lua a yield
-- it would attribute to the agent -- the agent's turn would then resume inside
-- the handler, halfway through an emit, with the scheduler's idea of that
-- actor's state now wrong. Since api.lua's turn loop and tools.lua's M.run both
-- run in the scheduler's world and outside it, that is a live hazard rather
-- than a theoretical one.
--
-- So a handler runs in its own coroutine and is resumed exactly once. If it
-- yields, it is closed and dropped with a notification: handlers are for
-- reacting, not for doing I/O. The cost is one coroutine per handler per emit,
-- paid only when something is actually subscribed.
--
-- A count hook also bounds a handler that loops without yielding. It composes
-- with an existing tool/workflow hook and restores that enclosing hook on exit,
-- so callback isolation cannot remove the caller's execution budget.
local function report(h, err, co)
  local msg = tostring(err)
  if not (type(err) == "table" and err.boggart_error) then
    msg = msg .. "\n" .. debug.traceback(co, nil, 1)
  end
  h.errors = h.errors + 1
  local why = string.format("event handler #%d (%s) failed: %s", h.id, h.pattern, msg)
  if h.errors >= MAX_ERRORS then
    M.off(h)
    why = why .. string.format("\n(unsubscribed after %d failures)", h.errors)
  end
  M.notify(why, "error")
end

local function invoke(h, name, data)
  local co = coroutine.create(h.fn)
  require("invoke").inherit(co)
  local hook_control = handler_hook(co)
  h.calls = h.calls + 1
  local ok, err = coroutine.resume(co, name, data)
  if hook_control.outer_failure ~= nil then return hook_control.outer_failure end
  if hook_control.handler_failure ~= nil then
    report(h, hook_control.handler_failure, co)
    return
  end
  if not ok then
    if type(err) == "table" and err.boggart_outer_hook then return err.error end
    report(h, err, co)
  elseif coroutine.status(co) == "suspended" then
    coroutine.close(co)
    h.errors = h.errors + 1
    M.notify(string.format(
      "event handler #%d (%s) yielded and was dropped -- handlers must not "
      .. "block or shell out", h.id, h.pattern), "warn")
    if h.errors >= MAX_ERRORS then M.off(h) end
  end
end

-- ---------------------------------------------------------------------------
-- The bus

-- on(pattern, fn, opts) -> handle
--   pattern  event name, `*` wildcards ("tool:*", "*")
--   fn       function(event_name, data)
--   opts     { once = true, desc = "shown by events.list()", source = "..." }
function M.on(pattern, fn, opts)
  if type(pattern) ~= "string" or pattern == "" then error("events.on: pattern must be a string", 2) end
  if type(fn) ~= "function" then error("events.on: fn must be a function", 2) end
  opts = opts or {}
  local h = {
    id = state.next_id, pattern = pattern, rx = compile(pattern), fn = fn,
    once = opts.once or nil, desc = opts.desc, source = opts.source or "runtime",
    calls = 0, errors = 0,
  }
  state.next_id = state.next_id + 1
  state.handlers[#state.handlers + 1] = h
  state.count = state.count + 1
  cache = {}
  return h
end

-- off(handle) -- accepts the handle from on(), or its .id.
function M.off(handle)
  local id = type(handle) == "table" and handle.id or handle
  for i, h in ipairs(state.handlers) do
    if h.id == id then
      table.remove(state.handlers, i)
      state.count = state.count - 1
      h.dead = true
      cache = {}
      return true
    end
  end
  return false
end

-- Every registration, in firing order.
function M.list()
  local out = {}
  for _, h in ipairs(state.handlers) do
    out[#out + 1] = { id = h.id, pattern = h.pattern, desc = h.desc, once = h.once or false,
                      source = h.source, calls = h.calls, errors = h.errors }
  end
  return out
end

-- Drop every handler (tests, and anything that wants a clean slate).
function M.clear()
  state.handlers, state.count = {}, 0
  cache = {}
end

-- Is anyone listening? One table lookup once a name has been resolved. Call
-- sites use this to skip building a payload they would only throw away.
function M.any(name)
  if state.count == 0 then return bus_wants(name) end
  local hs = cache[name] or resolve(name)
  return #hs > 0 or bus_wants(name)
end

-- emit(name, data) -> number of handlers run.
--
-- The no-subscriber path is one comparison and a return: that is the whole
-- reason `count` is maintained rather than derived. Callers still allocate the
-- payload table before calling, so the hot emits (turn:text, once per
-- streamed token) guard with events.any() first; `data` may also be a function,
-- which is only called if someone is listening.
function M.emit(name, data)
  local to_bus = bus_wants(name)
  local hs = state.count > 0 and (cache[name] or resolve(name)) or nil
  local n = hs and #hs or 0
  if n == 0 and not to_bus then return 0 end
  if type(data) == "function" then data = data() end

  -- Mirror onto the fabric independent of the Lua-handler path: an observer must
  -- see the event even when no handler is registered, and even if handler
  -- recursion (below) would drop the in-process dispatch.
  if to_bus then bus_mirror(name, data) end

  if n == 0 then return 0 end
  if state.depth >= MAX_DEPTH then
    -- Do not notify here: notify emits, and this is the one place that is
    -- certainly already in a loop.
    bog.log("events: dropping '" .. name .. "' at depth " .. state.depth .. " (handler recursion)")
    return 0
  end

  state.depth = state.depth + 1
  local fired = 0
  local outer_error
  -- `hs` is the list as it stood at entry, so a handler that *subscribes*
  -- during dispatch is called from the next emit rather than this one. An
  -- unsubscribe is honoured immediately (the `dead` check): after off()
  -- returns, the handler does not run again, which is the guarantee anything
  -- tearing itself down actually needs.
  for i = 1, n do
    local h = hs[i]
    if not h.dead then
      if h.once then M.off(h) end
      outer_error = invoke(h, name, data)
      fired = fired + 1
      if outer_error ~= nil then break end
    end
  end
  state.depth = state.depth - 1
  if outer_error ~= nil then error(outer_error, 0) end
  return fired
end

-- ask(name, data) -> answer | nil
--
-- The query half of the bus. `emit` notifies and throws every return value
-- away, which is right for an observer and useless for a gate: a handler that
-- wants to REFUSE something has no way to say so. `ask` dispatches the same
-- handlers in registration order and returns the FIRST non-nil answer, stopping
-- there -- so a hook can veto a tool call, supply a value, or (by returning
-- nothing, like every existing handler) decline to have an opinion.
--
-- Handlers run directly rather than through invoke's coroutine wrapper because
-- an answer has to come back on the stack. The same rule as emit still applies:
-- a handler must not block or yield. One that errors is reported and skipped,
-- never allowed to take down the call it was asked about.
function M.ask(name, data, opts)
  local hs = state.count > 0 and (cache[name] or resolve(name)) or nil
  local n = hs and #hs or 0
  if n == 0 then return nil end
  if state.depth >= MAX_DEPTH then return nil end
  state.depth = state.depth + 1
  local answer = nil
  for i = 1, n do
    local h = hs[i]
    if not h.dead then
      if h.once then M.off(h) end
      h.calls = h.calls + 1
      local old, old_mask, old_count = debug.gethook()
      local hook_control = handler_hook()
      local ok, res = pcall(h.fn, name, data)
      debug.sethook(old, old_mask, old_count)
      if hook_control.outer_failure ~= nil then
        state.depth = state.depth - 1
        error(hook_control.outer_failure, 0)
      end
      if hook_control.handler_failure ~= nil then
        report(h, hook_control.handler_failure)
        ok, res = true, nil
        if opts and opts.fail_closed then
          state.depth=state.depth-1
          return {deny=true,reason="authorization handler exceeded its budget"}
        end
      end
      if not ok then
        if type(res) == "table" and res.boggart_outer_hook then
          state.depth = state.depth - 1
          error(res.error, 0)
        end
        report(h, res)
        if opts and opts.fail_closed then
          state.depth=state.depth-1
          return {deny=true,reason="authorization handler failed"}
        end
      elseif res ~= nil then
        if not (opts and opts.fail_closed) or res=="deny" or type(res)=="table" and res.deny then
          answer = res
          break
        end
      end
    end
  end
  state.depth = state.depth - 1
  return answer
end

-- ---------------------------------------------------------------------------
-- notify -- one function, both worlds (vim.notify)
--
-- The event goes out first so a panel can render it, then the default sink
-- writes it where a human will actually see it: the studio's log/status line
-- when embedded (core.log/core.error), stderr via bog.log otherwise. Replace
-- events.sink to take over entirely.
--
-- rawget rather than a bare `core`: strict.lua is armed in every mode except
-- embedded, and reading an undefined global there is an error by design.
M.LEVELS = { debug = true, info = true, warn = true, error = true }

function M.sink(msg, level)
  local core = rawget(_G, "core")
  if type(core) == "table" and type(core.log) == "function" then
    if level == "error" then core.error("%s", msg) else core.log("%s", msg) end
    return
  end
  if level == "info" or level == "debug" then bog.log(msg)
  else bog.log(string.upper(level) .. ": " .. msg) end
end

function M.notify(msg, level)
  msg = tostring(msg)
  level = M.LEVELS[level] and level or "info"
  M.emit("notify", { msg = msg, level = level })
  -- pcall: a broken sink (a studio view torn down mid-frame) must not take the
  -- caller down, and notify is called from the failure path of invoke().
  pcall(M.sink, msg, level)
end

-- ---------------------------------------------------------------------------
-- User registrations: ~/.boggart/lua/events/*.lua
--
-- One file per concern, each returning nothing and calling events.on(). The
-- module is passed as the chunk's only argument, so a file starts:
--
--   local events = ...
--   events.on("file:write", function(_, d) events.notify("wrote " .. d.path) end,
--             { desc = "announce writes" })
--
-- NOT ~/.boggart/lua/events.lua -- that path is the overlay copy of *this*
-- module and would replace it. The subdirectory is the registration point.
--
-- These load with the real _G (they are the user's own overlay, the same trust
-- as ~/.boggart/lua/boot.lua), unlike generated tool bodies, which get the
-- capability environment because the model wrote them.
local function load_user_files()
  local dir = bog.userdir .. "/lua/events"
  if sys.stat(dir) ~= "dir" then return end
  local names = sys.listdir(dir) or {}
  table.sort(names) -- deterministic registration order across platforms
  for _, fname in ipairs(names) do
    if fname:match("%.lua$") and fname ~= "init.lua" then
      local chunk, err = loadfile(dir .. "/" .. fname)
      if not chunk then
        bog.log("events: skipping " .. fname .. ": " .. tostring(err))
      else
        local ok, ferr = bog.try(chunk, M)
        if not ok then bog.log("events: " .. fname .. " failed: " .. tostring(ferr)) end
      end
    end
  end
end

-- On (re)load, drop what the last pass read off disk and read it again; leave
-- everything registered at runtime alone. See the note on `state` at the top.
do
  local keep = {}
  for _, h in ipairs(state.handlers) do
    if not (h.source and h.source:sub(1, 5) == "user:") then keep[#keep + 1] = h end
  end
  state.handlers, state.count = keep, #keep
  cache = {}

  local n0 = state.next_id
  load_user_files()
  -- Tag what the scan added so the next reload can find it again. Doing it here
  -- rather than in each file keeps the user's API to just events.on().
  for _, h in ipairs(state.handlers) do
    if h.id >= n0 then h.source = "user:" .. (h.source == "runtime" and "file" or h.source) end
  end
end

return M
