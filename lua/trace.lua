-- trace.lua -- tail the fabric bus and render every event as one structured
-- line. This is the Phase-1 proof of docs/actors-and-bus.md: "the bus is
-- observability". Subscribing to "*" here also switches ON the events->bus
-- mirror (events.emit only mirrors when bus.has(name) is true), so starting a
-- trace makes the whole event stream flow onto the fabric with no other wiring.
--
-- In-process only, by design: the bus lives in this process (cross-process IPC
-- is a later phase), so a trace watches the turns/tools/swarm running in THIS
-- boggart -- the REPL, a one-shot, or a swarm run -- live.
local M = {}
M._subs = nil
M._n = 0

-- Default sink: stderr, so a piped one-shot (`boggart -p ... 2>trace.log`) keeps
-- the trace off stdout and out of the answer.
local function default_sink(line) io.stderr:write(line, "\n") end

-- Payloads arrive as JSON bytes; show a bounded preview so a fat turn:text delta
-- can't flood a line. The trace is a live glance, not the durable record.
local function preview(payload, max)
  if type(payload) ~= "string" or payload == "" then return "" end
  max = max or 180
  payload = payload:gsub("%s+", " ")
  if #payload <= max then return payload end
  return payload:sub(1, max) .. "..."
end

-- start(opts) -> handle | nil, err
--   opts : a pattern string, or { pattern = ..., sink = fn }
-- The pattern may be a comma/space separated LIST ("turn:*, tool:*"); each is
-- subscribed, so the natural thing a user types works. Idempotent: a second
-- start replaces the first.
function M.start(opts)
  if type(opts) == "string" then opts = { pattern = opts } end
  opts = opts or {}
  local bus = rawget(_G, "bus")
  if not (bus and bus.subscribe) then return nil, "no fabric bus in this build" end
  if M._subs then M.stop() end
  local sink = opts.sink or default_sink
  M._n = 0
  M._pattern = opts.pattern or "*"
  local pats = {}
  for p in M._pattern:gmatch("[^,%s]+") do pats[#pats + 1] = p end
  if #pats == 0 then pats = { "*" } end
  local function on_evt(topic, payload)
    M._n = M._n + 1
    -- pcall: a broken sink (a torn-down studio view) must not kill the publisher.
    pcall(sink, string.format("%6d  %-24s %s", M._n, topic, preview(payload)))
  end
  M._subs = {}
  for _, p in ipairs(pats) do M._subs[#M._subs + 1] = bus.subscribe(p, on_evt) end
  return M._subs[1]
end

-- stop() -> events_seen
function M.stop()
  local bus = rawget(_G, "bus")
  if M._subs and bus and bus.unsubscribe then
    for _, id in ipairs(M._subs) do bus.unsubscribe(id) end
  end
  local n = M._n
  M._subs, M._n, M._pattern = nil, 0, nil
  return n
end

function M.active() return M._subs ~= nil end
function M.pattern() return M._pattern end
function M.count() return M._n end

return M
