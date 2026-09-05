-- station.lua -- the LLM Station ZMQ client's dormant contract, plus the
-- envelope codec, which works in every build because it needs no libzmq.
--
-- The opt-in rule under test (docs/station-zmq.md): a default build carries
-- station.built() == false and every entry point degrades to nil + an
-- explanatory error -- never a raise, never a hang. The msgpack codec and
-- endpoint discovery are unconditional, so they are exercised for real here;
-- the socket layer needs a live daemon and is covered by the manual smoke in
-- a -DBOGGART_STATION=ON build.
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end

ok(type(station) == "table", "station global exists")
ok(type(station.built()) == "boolean", "built() returns a boolean")
ok(type(station.available()) == "boolean", "available() returns a boolean")

-- connect never raises: either a connection (flag build, workspace known) or
-- nil + a reason. Point it at a directory that cannot be registered.
do
  local conn, err = station.connect("/nonexistent/path/for/station/test")
  ok(conn == nil and type(err) == "string", "connect on a bogus workspace: nil, err")
end

-- endpoint discovery never raises either; on this bogus path it must miss.
do
  local ep, why = station.endpoint("/nonexistent/path/for/station/test")
  ok(ep == nil and type(why) == "string", "endpoint miss: nil, why")
end

-- ---- envelope codec round trip ---------------------------------------------

do
  local payload = {
    file = "src/main.c", line = "42", column = "7",
    prefix = "do_th", empty = "",
    long = string.rep("x", 300),               -- forces str16
  }
  local bytes = station._encode("tool_exec", "smart_complete", payload)
  ok(type(bytes) == "string" and #bytes > 0, "encode produces bytes")
  ok(bytes:byte(1) == 0x83, "envelope is a 3-field fixmap")

  local mt, tool, p = station._decode(bytes)
  ok(mt == "tool_exec", "msg_type round-trips")
  ok(tool == "smart_complete", "tool rides its own slot (STATION-138)")
  ok(type(p) == "table", "payload decodes to a table")
  local n = 0
  for _ in pairs(p or {}) do n = n + 1 end
  ok(n == 6, "payload pair count survives (" .. tostring(n) .. ")")
  ok(p.file == "src/main.c" and p.line == "42", "flat string values survive")
  ok(p.empty == "", "empty string value survives")
  ok(p.long == string.rep("x", 300), "str16-sized value survives")
end

-- Numbers are stringified on encode: the wire is flat strings by design.
do
  local bytes = station._encode("ping", nil, { n = 7 })
  local _, _, p = station._decode(bytes)
  ok(p and p.n == "7", "number payload value becomes a string")
end

-- No tool, no payload: both default rather than erroring.
do
  local bytes = station._encode("ping")
  local mt, tool, p = station._decode(bytes)
  ok(mt == "ping" and tool == "" and type(p) == "table" and next(p) == nil,
    "minimal envelope round-trips")
end

-- Garbage in: a clean nil, err -- decode must never raise on wire noise.
do
  local a, b = station._decode("not msgpack at all")
  ok(a == nil and type(b) == "string", "garbage decodes to nil, err")
  local c, d = station._decode(string.char(0x83, 0xa8) .. "msg_typ") -- truncated
  ok(c == nil and type(d) == "string", "truncated envelope: nil, err")
end

-- Forward compatibility: an envelope with an unknown extra field (here an
-- int, which the flat-strings wire never uses today) still decodes.
do
  -- fixmap(4): msg_type:"x", tool:"", payload:{}, extra:7
  local bytes = string.char(0x84)
    .. string.char(0xa8) .. "msg_type" .. string.char(0xa1) .. "x"
    .. string.char(0xa4) .. "tool" .. string.char(0xa0)
    .. string.char(0xa7) .. "payload" .. string.char(0x80)
    .. string.char(0xa5) .. "extra" .. string.char(0x07)
  local mt, tool, p = station._decode(bytes)
  ok(mt == "x" and tool == "" and type(p) == "table",
    "unknown top-level field is skipped, not fatal")
end

io.write(string.format("station: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
