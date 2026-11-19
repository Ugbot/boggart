-- stream_timeouts.lua -- a model request ends on silence, not on length.
--
-- http.begin's idle_timeout aborts a transfer only when no byte has arrived for
-- that long (the first byte included); timeout = 0 means no limit on the total.
-- Model requests use exactly that (api.request_timeouts): a slow model that
-- keeps streaming is never cut off, one that goes silent still ends. Skipped
-- without python3 (the test server).
local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local p = io.popen("command -v python3")
local py = p and p:read("l")
if p then p:close() end
if not py or py == "" then io.write("stream_timeouts: skipped (no python3)\n"); return end

bog.store.open()
local sched = require("sched")
bog.sched = bog.sched or sched

-- Run one async request to completion under the scheduler, as api does.
local function fetch(path, opts)
  local srv = io.popen("python3 tests/fixtures/http/drip_server.py 2>/dev/null", "r")
  local port = tonumber(srv:read("l"))
  local req_opts = { url = "http://127.0.0.1:" .. port .. path, method = "GET" }
  for k, v in pairs(opts) do req_opts[k] = v end
  local got, st, extra = {}, nil, nil
  local t0 = os.time()
  sched.drive(function()
    local req = http.begin(req_opts)
    while true do
      coroutine.yield("io", req)
      local c = req:take()
      if c ~= "" then got[#got + 1] = c end
      st, extra = req:status()
      if st == "done" or st == "error" then break end
    end
  end)
  local secs = os.time() - t0   -- before close(): close waits for the server to exit
  srv:close()
  return st, extra, table.concat(got), secs
end

-- 1. A stream that keeps sending, longer than the idle limit in total: it completes.
local st, extra, body, secs = fetch("/drip?n=8&gap=0.5", { timeout = 0, idle_timeout = 2 })
ok(st == "done" and extra == 200, "a live stream longer than the idle limit completes (" .. tostring(st) .. " " .. tostring(extra) .. ")")
ok(body == string.rep("x", 8), "every byte arrived (" .. #body .. ")")
ok(secs >= 3, "it really did outlast the idle limit (" .. secs .. " s)")

-- 2. Silence before the first byte longer than the idle limit: the request ends.
st, extra, body, secs = fetch("/silent?s=8", { timeout = 0, idle_timeout = 2 })
ok(st == "error", "a silent server ends the request (" .. tostring(st) .. ")")
ok(secs <= 6, "it ended near the idle limit, not after the server's 8 s (" .. secs .. " s)")

-- 3. A total limit, when one is given, still applies to a live stream.
st, extra, body, secs = fetch("/drip?n=12&gap=0.5", { timeout = 2 })
ok(st == "error", "a total timeout still ends a long live stream (" .. tostring(st) .. ")")

-- 4. The settings model requests use: no total, idle 600 s, connect 30 s;
-- the environment overrides them and a bad value falls back.
local api = bog.api
local d = api.request_timeouts()
ok(d.total == 0 and d.idle == 600 and d.connect == 30, "defaults: no total, idle 600, connect 30")
local real_getenv = os.getenv
os.getenv = function(k)
  if k == "BOGGART_IDLE_TIMEOUT" then return "1800" end
  if k == "BOGGART_REQUEST_TIMEOUT" then return "7200" end
  if k == "BOGGART_CONNECT_TIMEOUT" then return "soon" end
  return real_getenv(k)
end
local e = api.request_timeouts()
os.getenv = real_getenv
ok(e.idle == 1800 and e.total == 7200, "the environment overrides idle and total")
ok(e.connect == 30, "a value that is not a whole number falls back to the default")

-- 5. The model request itself carries them (http.begin stubbed: no network).
local seen
local real_begin = http.begin
http.begin = function(o)
  seen = o
  local r = {}
  function r:take() return "" end
  function r:status() return "done", 200 end
  return r
end
pcall(sched.drive, function()
  return api.stream_async({ model = "m", max_tokens = 10, messages = {}, stream = true }, nil, nil,
    { url = "http://127.0.0.1:9", wire = "openai", model = "m" })
end)
http.begin = real_begin
ok(seen ~= nil, "the model request went through http.begin")
ok(seen and seen.timeout == 0 and seen.idle_timeout == 600 and seen.connect_timeout == 30,
   "a model request has no total limit, a 600 s idle limit and a 30 s connect limit")

io.write(string.format("stream_timeouts: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
