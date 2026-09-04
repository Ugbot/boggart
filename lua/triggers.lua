-- triggers.lua -- what starts work when nobody is typing.
--
-- boggart ran to quiescence and exited, so every turn began with a human. That
-- is the whole "autonomy" gap: a coding agent can live with it, and a process
-- that is supposed to notice an invoice, a push, or 9am cannot. This module is
-- the trigger source -- schedules and event bindings -- and it is Lua on
-- purpose, sitting on top of the two things that are not:
--
--   C   the uv loop (timers), and the inbound socket (src/lserve.c) that turns
--       a webhook into an event. Neither is expressible in Lua.
--   Lua when a schedule fires, what it means, what it runs, how it persists.
--       All of which people will want to change, so none of it is compiled in.
--
-- A trigger is { name, when, run, enabled }:
--   when = { every = 300 }               -- seconds
--   when = { at = "09:00" }              -- local clock, daily
--   when = { on = "hook:push" }          -- an event, including any webhook
--   run  = "a prompt to run"             -- or a function(ctx)
--
-- Firing publishes `trigger:fired` and then does the work. In `boggart serve`
-- that means a queued turn; anywhere else a handler can pick it up. The trigger
-- does not care which -- it names the occasion, not the consumer.
local M = {}

M.list = {}          -- name -> trigger
M.KV_KEY = "triggers"
local timer = nil
local bound = {}     -- name -> events handle, for `on` triggers

-- ---------------------------------------------------------------------------
-- persistence: the kv table, so a schedule survives a restart
-- ---------------------------------------------------------------------------

local function serialise()
  local out = {}
  for name, t in pairs(M.list) do
    -- a function body cannot be persisted; those live only for this process
    if type(t.run) == "string" then
      out[#out + 1] = { name = name, when = t.when, run = t.run, enabled = t.enabled }
    end
  end
  return out
end

function M.save()
  local json = require "json"
  local okj, s = pcall(json.encode, serialise())
  if okj and bog.db then pcall(function() bog.store.kv_set(M.KV_KEY, s) end) end
  return okj
end

function M.load()
  if not bog.db then return 0 end
  local okv, raw = pcall(function() return bog.store.kv_get(M.KV_KEY) end)
  if not okv or type(raw) ~= "string" or raw == "" then return 0 end
  local json = require "json"
  local okj, list = pcall(json.decode, raw)
  if not okj or type(list) ~= "table" then return 0 end
  local n = 0
  for _, t in ipairs(list) do
    if type(t) == "table" and t.name then
      M.add(t.name, t.when, t.run, { enabled = t.enabled ~= false, quiet = true })
      n = n + 1
    end
  end
  return n
end

-- ---------------------------------------------------------------------------
-- the table
-- ---------------------------------------------------------------------------

-- add(name, when, run, opts) -> trigger
function M.add(name, when, run, opts)
  opts = opts or {}
  if type(name) ~= "string" or name == "" then error("triggers.add: a trigger needs a name", 2) end
  if type(when) ~= "table" then error("triggers.add: `when` must be a table", 2) end
  M.remove(name, true)   -- replacing is the common case; do not stack handlers
  local t = {
    name = name, when = when, run = run,
    enabled = opts.enabled ~= false,
    fired = 0, last = nil, next_at = nil,
  }
  if when.every then
    t.next_at = os.time() + math.max(1, math.floor(tonumber(when.every) or 60))
  elseif when.at then
    t.next_at = M.next_clock_time(when.at)
  elseif when.on then
    bound[name] = bog.events.on(when.on, function(_, data)
      M.fire(name, { event = when.on, data = data })
    end, { desc = "trigger " .. name, source = "triggers.lua" })
  end
  M.list[name] = t
  if not opts.quiet then M.save() end
  return t
end

function M.remove(name, quiet)
  if bound[name] then bog.events.off(bound[name]); bound[name] = nil end
  local had = M.list[name] ~= nil
  M.list[name] = nil
  if had and not quiet then M.save() end
  return had
end

function M.enable(name, on)
  local t = M.list[name]
  if not t then return false end
  t.enabled = on ~= false
  M.save()
  return true
end

-- Seconds-since-epoch of the next "HH:MM" in local time, today or tomorrow.
function M.next_clock_time(hhmm, now)
  local h, m = tostring(hhmm):match("^(%d%d?):(%d%d)$")
  if not h then return nil end
  now = now or os.time()
  local d = os.date("*t", now)
  local target = os.time({ year = d.year, month = d.month, day = d.day,
                           hour = tonumber(h), min = tonumber(m), sec = 0 })
  if target <= now then target = target + 24 * 3600 end
  return target
end

-- ---------------------------------------------------------------------------
-- firing
-- ---------------------------------------------------------------------------

function M.fire(name, ctx)
  local t = M.list[name]
  if not t or not t.enabled then return false end
  t.fired = t.fired + 1
  t.last = os.time()
  bog.events.emit("trigger:fired", { name = name, when = t.when, at = t.last })
  if type(t.run) == "function" then
    local okr, err = pcall(t.run, ctx or {})
    if not okr then
      bog.events.emit("trigger:error", { name = name, error = tostring(err) })
    end
  elseif type(t.run) == "string" and t.run ~= "" then
    -- The same door a webhook or a human uses: queue a prompt. Nothing here
    -- runs a turn directly -- a timer callback is not a place to spend minutes.
    bog.events.emit("serve:prompt",
      { id = "trigger-" .. name .. "-" .. tostring(t.fired),
        text = t.run, source = "trigger:" .. name })
  end
  return true
end

-- One pass over the clock-driven triggers. Exposed (rather than hidden in the
-- timer) so a test can advance time without waiting for it.
function M.tick(now)
  now = now or os.time()
  local fired = 0
  for name, t in pairs(M.list) do
    if t.enabled and t.next_at and now >= t.next_at then
      if t.when.every then
        t.next_at = now + math.max(1, math.floor(tonumber(t.when.every) or 60))
      elseif t.when.at then
        t.next_at = M.next_clock_time(t.when.at, now)
      end
      M.fire(name, { scheduled = true })
      fired = fired + 1
    end
  end
  return fired
end

-- ---------------------------------------------------------------------------
-- the clock
-- ---------------------------------------------------------------------------

-- start() puts one uv timer on the loop. One, not one per trigger: a hundred
-- schedules should not be a hundred handles, and a second of resolution is
-- plenty for anything a person writes a schedule for.
function M.start()
  if timer then return timer end
  local uv = require("uv")
  timer = uv.new_timer()
  uv.timer_start(timer, 1000, 1000, function() M.tick() end)
  uv.unref(timer)   -- never hold the process open by itself
  return timer
end

function M.stop()
  if not timer then return false end
  local uv = require("uv")
  pcall(uv.timer_stop, timer)
  pcall(uv.close, timer)
  timer = nil
  return true
end

function M.status()
  local out = {}
  for name, t in pairs(M.list) do
    out[#out + 1] = {
      name = name, when = t.when, enabled = t.enabled, fired = t.fired,
      last = t.last, next_at = t.next_at,
      run = type(t.run) == "string" and t.run or "<function>",
    }
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

return M
