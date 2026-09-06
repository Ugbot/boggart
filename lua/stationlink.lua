-- stationlink.lua -- policy for the native LLM Station ZMQ transport (src/lstation.c).
--
-- C moves bytes; this file decides. The transport rule is binary and absolute
-- (docs/station-zmq.md): when the ZMQ client is built and a daemon answers a
-- ping, EVERYTHING that uses LLM Station goes over ZMQ and the MCP mount is
-- not connected at all. When it is not built, or no daemon is reachable, or a
-- call dies mid-flight, station-backed tools degrade to boggart's native
-- tiers (bm25, grep, no-completion) exactly as if no station existed -- never
-- to MCP. Forcing the MCP path stays possible for testing the MCP adapter:
-- BOGGART_STATION_FORCE_MCP=1.
--
-- Crash tolerance: the daemon's correlation and subscription state is RAM, so
-- this layer treats "down" as a normal state. A failed send, a timed-out call
-- or a failed ping flips the transport down (one "station.down" bus event, no
-- retry storm); reconnection is attempted lazily on the next use, behind a
-- jittered backoff, and success re-issues subscriptions and emits
-- "station.up". A dead daemon costs whoever asked one bounded timeout.
local M = {}

M.PING_TIMEOUT_MS = 1500
M.CALL_TIMEOUT_MS = 30000
M.RETRY_AFTER_S = 2.0          -- base backoff before another connect attempt

M.conn = nil                   -- live boggart.station connection, or nil
M.state = "down"               -- "up" | "down"
M.why = "not yet attempted"    -- last reason for being down
M.topics = { "chat.*" }        -- re-subscribed after every (re)connect
local last_attempt = 0

-- msg_types the daemon answers inline on its poll thread. tool_exec rides
-- "cmd" (ack now, result later, same corr id -- the C layer holds the handle
-- open through the ack).
local QUERY_MSG = { ping = true, list_tools = true, tool_schema = true, status = true }

-- Tools fast enough to ride the query channel: answered inline on the
-- daemon's poll thread, no ack round-trip, no detached thread, no outbound
-- queue, no <=100ms poll tick -- measured ~0.1ms vs 10-110ms for the same
-- call over cmd. The judgement that a tool is fast is OURS (a slow tool here
-- stalls every station client), so the set stays small and index-backed:
-- completions and LSP-quality queries, the as-you-type path.
M.fast_tools = {
  smart_complete = true,
  lsp_query = true,
  symbol_search = true,
  code_search = true,
}

local function emit(topic, why)
  if rawget(_G, "bus") and bus.publish then
    pcall(bus.publish, topic, string.format('{"why":%q}', tostring(why or "")))
  end
end

-- Is the ZMQ transport even a possibility in this binary/session?
function M.enabled()
  local st = rawget(_G, "station")
  if not (st and st.built and st.built()) then return false, "not built" end
  if os.getenv("BOGGART_STATION_FORCE_MCP") == "1" then
    return false, "BOGGART_STATION_FORCE_MCP=1"
  end
  return true
end

function M.up() return M.state == "up" and M.conn ~= nil end

local function mark_down(why)
  local was = M.state
  M.state, M.why = "down", tostring(why or "unknown")
  if M.conn then pcall(function() M.conn:close() end) end
  M.conn = nil
  if was == "up" then
    bog.log("station: transport down (" .. M.why .. ")")
    emit("station.down", M.why)
  end
end

function M.ping(timeout_ms)
  if not M.conn then return false, "no connection" end
  local ok, p, err = pcall(function()
    local h = M.conn:request("query", "ping", nil, {}, timeout_ms or M.PING_TIMEOUT_MS)
    return h:wait()
  end)
  if not ok then return false, tostring(p) end
  if not p then return false, err end
  return true
end

-- Connect + ping, once. Success wires subscriptions and announces station.up.
local function try_connect(workspace)
  local st = rawget(_G, "station")
  -- The C client parks the socket's ZMQ_FD on the interpreter's uv loop so
  -- subscribed events arrive while the program just sits in uv.run -- but
  -- luv only creates that loop when required, so make sure it exists before
  -- the connect that would watch it.
  pcall(require, "uv")
  local conn, err = st.connect(workspace or (sys.cwd and sys.cwd()) or ".")
  if not conn then return nil, err end
  M.conn = conn
  local alive, why = M.ping()
  if not alive then
    pcall(function() conn:close() end)
    M.conn = nil
    return nil, "daemon not answering (" .. tostring(why) .. ")"
  end
  for _, t in ipairs(M.topics) do pcall(function() conn:subscribe(t) end) end
  M.state, M.why = "up", ""
  bog.log("station: ZMQ transport up (" .. conn:endpoint() .. ")")
  emit("station.up", conn:endpoint())
  return conn
end

-- The lazy driver: give me a live transport or a reason. Down states retry at
-- most once per backoff window (jittered), so a missing daemon costs one
-- cheap discovery miss per window, not a storm.
function M.ensure(workspace)
  if M.up() then return M.conn end
  local okd, why = M.enabled()
  if not okd then return nil, why end
  local now = os.time()
  if now - last_attempt < M.RETRY_AFTER_S + math.random() then
    return nil, M.why
  end
  last_attempt = now
  local conn, err = try_connect(workspace)
  if not conn then
    M.why = tostring(err)
    return nil, M.why
  end
  return conn
end

-- One station tool call over ZMQ. Returns the tool's text output, or nil +
-- err. Any transport-shaped failure (send, timeout) flips the state down so
-- the caller's next tier takes over immediately.
--   opts.timeout_ms, opts.channel ("query" forces the inline path once the
--   daemon serves this msg_type there), opts.msg_type (default tool_exec).
function M.call(tool, params, opts)
  opts = opts or {}
  local conn, err = M.ensure()
  if not conn then return nil, err end

  local msg_type = opts.msg_type or "tool_exec"
  local channel = opts.channel
    or (QUERY_MSG[msg_type] and "query")
    or (msg_type == "tool_exec" and tool and M.fast_tools[tool] and "query")
    or "cmd"
  local ok, p, why, ch = pcall(function()
    local h = conn:request(channel, msg_type, tool, params or {},
      opts.timeout_ms or M.CALL_TIMEOUT_MS)
    return h:wait()
  end)
  if not ok then
    mark_down(tostring(p))
    return nil, "station call failed: " .. tostring(p)
  end
  if not p then
    -- Timed out or the send failed. Distinguish "slow tool" from "dead
    -- daemon" with one cheap ping before deciding the transport is gone.
    if not M.ping() then mark_down(why or "timeout") end
    return nil, "station call failed: " .. tostring(why)
  end
  if ch == "error" or p.error then
    return nil, "station error: " .. tostring(p.error or "protocol error")
  end
  if p.ok == "false" then
    return nil, "station tool error: " .. tostring(p.err or "failed")
  end
  return p.data or "", p
end

-- As-you-type completion: query channel, short deadline, nil on any trouble.
-- The caller computes `prefix` from the LIVE buffer (the daemon's index sees
-- the saved file), which is the reference EditorProtocol's compensation for
-- unsaved edits. Never raises; a miss is "no candidates", not an error.
function M.complete(file, line, col, prefix, limit)
  if not M.up() then return nil end
  local ok, out = pcall(M.call, "smart_complete", {
    file = tostring(file), line = tostring(line), column = tostring(col),
    prefix = prefix or "", limit = tostring(limit or 6),
  }, { timeout_ms = 300 })
  if not ok or not out or out == "" then return nil end
  return out
end

-- Raw query-channel access for protocol msg_types (status, tool_schema, ...).
function M.query(msg_type, params, timeout_ms)
  return M.call(nil, params, {
    msg_type = msg_type, channel = "query", timeout_ms = timeout_ms })
end

-- Drive event delivery (subscribed topics -> bus "station.<topic>") when no
-- call is in flight to drain the socket. Cheap; safe to call every frame.
function M.pump()
  if M.conn then pcall(function() M.conn:pump(0) end) end
end

-- The one-line answer doctor and llmstation.autostart need: is the ZMQ
-- transport the active way to reach LLM Station right now? Probes (and so
-- connects) on first ask when enabled.
function M.active()
  if M.up() then return true end
  local okd = M.enabled()
  if not okd then return false end
  return M.ensure() ~= nil
end

return M
