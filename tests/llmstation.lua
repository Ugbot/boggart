-- llmstation.lua -- the LLM Station MCP wrapper: it detects a local install and,
-- when present, exposes its tools over boggart's MCP host. These tests exercise
-- detection and the dormant path (no binary -> no-op, never raises); they do not
-- spawn the real MCP adapter.
local ls = require("llmstation")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

eq(ls.SERVER, "llm-station", "server name is stable (tools register as mcp__llm-station__*)")

-- binary()/available() never raise, whatever the machine has installed
local bin = ls.binary()
ok(bin == nil or type(bin) == "string", "binary() returns nil or a path, never errors")
eq(type(ls.available()), "boolean", "available() is a boolean")
eq(ls.available(), bin ~= nil, "available() agrees with binary()")

-- the explicit override is honoured (create a stand-in binary, point at it)
do
  local real = os.getenv
  local fake = os.tmpname()
  local f = io.open(fake, "w"); f:write("#!/bin/sh\n"); f:close()
  os.getenv = function(n) -- luacheck: ignore
    if n == "BOGGART_LLM_STATION" then return fake end
    return real(n)
  end
  eq(ls.binary(), fake, "binary() honours the BOGGART_LLM_STATION override")
  ok(ls.available(), "available() true when the override points at a real file")
  os.getenv = real -- luacheck: ignore
  os.remove(fake)
end

-- autostart is always safe and returns a boolean
do
  local okc, res = pcall(ls.autostart)
  ok(okc, "autostart never raises")
  eq(type(res), "boolean", "autostart returns a boolean")
  local ok2, res2 = pcall(ls.autostart)
  ok(ok2, "a second autostart never raises")
  eq(type(res2), "boolean", "a second autostart still returns a boolean")
  if res then eq(res2, true, "a second autostart is a no-op once connected") end
  -- when LLM Station is not installed here, it must be a dormant no-op
  if not ls.available() then
    eq(res, false, "autostart is a no-op when llm-station is absent")
    local names, err = ls.attach()
    ok(names == nil and type(err) == "string", "attach reports why it could not connect")
  end
end

io.write(string.format("llmstation: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
