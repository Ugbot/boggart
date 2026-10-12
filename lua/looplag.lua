-- looplag.lua -- how long the event loop is blocked, and by what (BOG-22).
--
-- Everything in boggart shares one libuv loop: model streams, subprocesses,
-- MCP, timers, the TUI's keys and paints. Anything that runs too long on it
-- -- a JSON decode of a big transcript, a full-file read, a slow paint --
-- stalls all of them at once, and until now the only symptom was "it feels
-- janky". This turns that into numbers, so every perf change can show its
-- effect (docs/perf-hardening-plan.md, T4-6):
--
--   * libuv's own idle-time accounting (uv.metrics_idle_time) -> how busy the
--     loop thread was over the last window;
--   * a light probe timer -> how late the loop was to service it (lag);
--   * instrumentation at the places that run Lua on the loop -- every
--     scheduler resume (named by the agent) and the paint sites (perf.time) --
--     so a stall is recorded with WHAT caused it.
--
-- The probe timer is unref'd: it never keeps a finished process alive.
local M = {}

M.THRESHOLD_MS = 50   -- a single run on the loop longer than this is a "block"
M.PROBE_MS = 250
M.KEEP = 64           -- recent blocks remembered

local uv_ok, uv = pcall(require, "uv")
local blocks, head = {}, 0
local state = { started = false, last_probe = nil, max_lag = 0, lag_sum = 0, probes = 0,
                idle0 = 0, t0 = 0, win_idle = 0, win_t = 0, busy_pct = nil }

local function now_ms() return uv_ok and (uv.hrtime() / 1e6) or (os.clock() * 1000) end

-- Record a block: what ran, for how long.
function M.note(what, ms)
  head = head % M.KEEP + 1
  blocks[head] = { what = tostring(what), ms = ms, at = os.time() }
  if bog and bog.events and bog.events.emit then pcall(bog.events.emit, "perf:block", { what = tostring(what), ms = ms }) end
end

-- Run fn on behalf of `what`, noting it if it held the loop too long.
-- -> fn's results
function M.time(what, fn, ...)
  local t0 = now_ms()
  local r = table.pack(fn(...))
  local dt = now_ms() - t0
  if dt >= M.THRESHOLD_MS then M.note(what, dt) end
  return table.unpack(r, 1, r.n)
end

-- Start measuring. Idempotent; a missing uv (a build without it) is a no-op.
function M.start()
  if state.started or not uv_ok then return state.started end
  state.started = true
  pcall(uv.loop_configure, "metrics_idle_time")
  state.t0 = now_ms()
  state.idle0 = (pcall(uv.metrics_idle_time) and uv.metrics_idle_time() or 0) / 1e6
  state.win_t, state.win_idle = state.t0, state.idle0
  local timer = uv.new_timer()
  state.last_probe = now_ms()
  uv.timer_start(timer, M.PROBE_MS, M.PROBE_MS, function()
    local t = now_ms()
    local lag = t - state.last_probe - M.PROBE_MS
    state.last_probe = t
    if lag < 0 then lag = 0 end
    state.probes = state.probes + 1
    state.lag_sum = state.lag_sum + lag
    if lag > state.max_lag then state.max_lag = lag end
    -- busy share over a rolling ~10 s window
    if t - state.win_t >= 10000 then
      local idle = (uv.metrics_idle_time() or 0) / 1e6
      local span = t - state.win_t
      state.busy_pct = math.max(0, math.min(100, 100 * (1 - (idle - state.win_idle) / span)))
      state.win_t, state.win_idle = t, idle
    end
  end)
  uv.unref(timer)
  state.timer = timer
  return true
end

function M.recent(n)
  local out = {}
  for i = 0, M.KEEP - 1 do
    local b = blocks[((head - 1 - i) % M.KEEP) + 1]
    if b then out[#out + 1] = b end
    if #out >= (n or 10) then break end
  end
  return out
end

-- -> numbers for /perf and tests
function M.stats()
  local t = now_ms()
  local idle_ms = uv_ok and ((uv.metrics_idle_time() or 0) / 1e6) or 0
  local span = t - state.t0
  return {
    started = state.started,
    uptime_s = span / 1000,
    busy_pct = state.busy_pct or (span > 0 and math.max(0, math.min(100, 100 * (1 - (idle_ms - state.idle0) / span))) or 0),
    max_lag_ms = state.max_lag,
    avg_lag_ms = state.probes > 0 and state.lag_sum / state.probes or 0,
    blocks = M.recent(10),
    rss = uv_ok and uv.resident_set_memory and uv.resident_set_memory() or nil,
    available = uv_ok and uv.get_available_memory and uv.get_available_memory() or nil,
    constrained = uv_ok and uv.get_constrained_memory and uv.get_constrained_memory() or nil,
  }
end

local function mb(b) return b and string.format("%.1f MB", b / 1048576) or "?" end

function M.report()
  local s = M.stats()
  if not s.started then return "loop metrics are not running (no libuv in this build)" end
  local out = {
    string.format("event loop: %.0f%% busy, lag avg %.1f ms, worst %.0f ms (over %.0f s)", s.busy_pct, s.avg_lag_ms,
      s.max_lag_ms, s.uptime_s),
    string.format("memory: resident %s%s%s, Lua heap %.1f MB", mb(s.rss),
      s.available and (", available " .. mb(s.available)) or "",
      (s.constrained and s.constrained > 0) and (", limit " .. mb(s.constrained)) or "",
      collectgarbage("count") / 1024),
  }
  if sys and sys.membytes then
    local okm, mbytes = pcall(sys.membytes)
    if okm and mbytes then out[#out + 1] = string.format("process memory (sys.membytes): %s", mb(mbytes)) end
  end
  if #s.blocks == 0 then
    out[#out + 1] = string.format("no run held the loop for %d ms or more", M.THRESHOLD_MS)
  else
    out[#out + 1] = string.format("recent runs that held the loop >= %d ms:", M.THRESHOLD_MS)
    for _, b in ipairs(s.blocks) do
      out[#out + 1] = string.format("  %6.0f ms  %s  (%s)", b.ms, b.what, os.date("%H:%M:%S", b.at))
    end
  end
  return table.concat(out, "\n")
end

-- tests
function M._reset()
  blocks, head = {}, 0
  state.max_lag, state.lag_sum, state.probes = 0, 0, 0
end

return M
