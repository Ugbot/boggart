-- trace.lua -- the fabric tracer (lua/trace.lua). Subscribing to the bus tails
-- the event stream, and because events.emit only mirrors when bus.has(name),
-- starting a trace is what switches the events->bus mirror ON. A custom sink
-- makes the whole thing deterministic with no terminal. Run with
-- `boggart --eval tests/trace.lua`.
local events = require("events")
local trace = require("trace")

local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local function eq(a, b, n)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", n, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

events.clear()

-- ---- lifecycle ------------------------------------------------------------
ok(not trace.active(), "trace starts inactive")
local lines = {}
local h = trace.start{ pattern = "turn:*", sink = function(l) lines[#lines + 1] = l end }
ok(h ~= nil, "start returns a handle")
ok(trace.active(), "active after start")
eq(trace.pattern(), "turn:*", "records its pattern")

-- ---- only matching topics are traced; the mirror is switched on -----------
events.emit("turn:end", { session = 3, stop = "end_turn" })
events.emit("tool:before", { name = "bash" })   -- not matched by turn:*
eq(#lines, 1, "only the matching topic reaches the sink")
ok(lines[1]:find("turn:end", 1, true) ~= nil, "the line names the topic")
ok(lines[1]:find("end_turn", 1, true) ~= nil, "the line carries a payload preview")
eq(trace.count(), 1, "count tracks events seen")

-- ---- stop unsubscribes and the mirror goes quiet --------------------------
local seen = trace.stop()
eq(seen, 1, "stop reports the count")
ok(not trace.active(), "inactive after stop")
events.emit("turn:end", { session = 4 })
eq(#lines, 1, "no more lines after stop")

-- ---- a second start replaces the first ------------------------------------
local a = {}; trace.start{ pattern = "*", sink = function(l) a[#a + 1] = l end }
local b = {}; trace.start{ pattern = "*", sink = function(l) b[#b + 1] = l end }  -- replaces a
events.emit("anything:here", { v = 1 })
eq(#a, 0, "the replaced subscription is silent")
eq(#b, 1, "the live subscription receives the event")
trace.stop()

-- ---- a comma/space separated pattern LIST subscribes to each --------------
do
  local got = {}
  trace.start{ pattern = "turn:*, file:write", sink = function(l) got[#got + 1] = l end }
  events.emit("turn:end", {})       -- matches turn:*
  events.emit("file:write", {})     -- matches the second pattern
  events.emit("tool:before", {})    -- matches neither
  eq(#got, 2, "pattern list: both listed patterns match, the unlisted one does not")
  trace.stop()
end
events.clear()

io.write(failed == 0 and ("trace: all " .. passed .. " passed\n")
                      or ("trace: " .. failed .. " FAILED, " .. passed .. " passed\n"))
os.exit(failed == 0 and 0 or 1)
