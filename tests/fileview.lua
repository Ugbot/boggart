-- fileview.lua -- lazy file views (src/lview.c, BOG-23): a 200 MB file opens
-- instantly, any line reads without loading the rest, memory stays near the
-- index size, the loop stays responsive while it indexes, truncation is
-- refused (not a SIGBUS), and line splitting matches the old read tool.
local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local uv = require("uv")
ok(type(sys.view) == "function", "sys.view exists")
local dir = os.getenv("HOME") .. "/fv-" .. tostring(os.time())
sys.mkdir_p(dir)
local function now() return uv.hrtime() / 1e6 end

-- small-file semantics match tools.lua's old gmatch split
local small = dir .. "/small.txt"
local cases = { "", "a", "a\n", "a\nb", "a\nb\n", "\n", "\n\n", "x\r\ny\r\n", "no newline at end" }
local same = true
for _, c in ipairs(cases) do
  local f = io.open(small, "wb"); f:write(c); f:close()
  local old = {}
  for line in (c .. "\n"):gmatch("(.-)\n") do old[#old + 1] = line end
  if old[#old] == "" then old[#old] = nil end
  local v = assert(sys.view(small))
  local n = v:wait()
  local got = v:lines(1, n)
  if n ~= #old then same = false; io.write("  count ", string.format("%q", c), " ", n, " vs ", #old, "\n") end
  for i = 1, #old do if got[i] ~= old[i] then same = false; io.write("  line ", i, " of ", string.format("%q", c), "\n") end end
  v:close()
end
ok(same, "line splitting identical to the read tool's for edge cases (empty, CRLF, trailing newline)")
local f0 = io.open(small, "wb"); f0:write("alpha\nbeta\ngamma\n"); f0:close()
ok(bog.tools.run("read", { path = small, start_line = 2, max_lines = 1 }) == small .. " lines 2-2 of 3 (continue_offset=3)\n2\tbeta",
  "small-file read output unchanged")
ok(bog.tools.run("read", { path = small, start_line = 9 }) == small .. " lines 9-3 of 3\n", "past-the-end output unchanged")

-- a 200 MB file
local big = dir .. "/big.log"
local LINE = 0
do
  local f = assert(io.open(big, "wb"))
  local block = {}
  for i = 1, 4096 do block[i] = string.format("%09d some log text here to pad the line out a little bit ok\n", i) end
  LINE = #block[1]                            -- bytes per line, newline included
  local chunk = table.concat(block)
  local lines = 0
  while lines * LINE < 200 * 1024 * 1024 do
    -- renumber cheaply: only the first line of each chunk carries the global number
    f:write(string.format("%09d", lines + 1), chunk:sub(10))
    lines = lines + 4096
  end
  f:close()
end
local mem0 = sys.membytes and sys.membytes() or 0
local t0 = now()
local v = assert(sys.view(big))
local topen = now() - t0
ok(topen < 50, string.format("a 200 MB file opens in under 50 ms (%.1f ms)", topen))
ok(v:size() >= 200 * 1024 * 1024, "size is right")
t0 = now()
local l1 = v:line(1)
local lm = v:line(1000000)
local tline = now() - t0
ok(l1 and l1:sub(1, 9) == "000000001", "line 1")
ok(lm and #lm == LINE - 1 and lm:find("some log text", 1, true), "line 1,000,000 read directly")
io.write(string.format("  open %.1f ms, line 1,000,000 in %.1f ms\n", topen, tline))
-- the loop stays responsive while the background index runs
local ll = require("looplag"); ll.start(); ll._reset()
local ticks, done = 0, false
local tm = uv.new_timer()
uv.timer_start(tm, 5, 5, function() ticks = ticks + 1 end)
local t1 = now()
while not done do
  uv.run("once")
  local n, complete = v:count()
  if complete or now() - t1 > 20000 then done = true end
end
uv.close(tm)
local n, complete = v:count()
ok(complete, "the background index completes (" .. n .. " lines)")
ok(ll.stats().max_lag_ms < 50, string.format("the loop stayed responsive while indexing (worst lag %.0f ms)", ll.stats().max_lag_ms))
local mem1 = sys.membytes and sys.membytes() or 0
ok(mem1 - mem0 < 64 * 1048576, string.format("memory grew by %.1f MB for a 200 MB file (the index), not the file", (mem1 - mem0) / 1048576))
-- the read tool on the big file: only the requested lines, quickly
local tr0 = now()
local out = bog.tools.run("read", { path = big, start_line = 2000000, max_lines = 3 })
local trt = now() - tr0
ok(type(out) == "string" and out:find("lines 2000000-2000002 of", 1, true) and out:find("\n2000001\t", 1, true),
  "read tool returns the requested range of a 200 MB file: " .. tostring(out):sub(1, 120))
ok(trt < 500, string.format("in %.0f ms", trt))
local whole = bog.tools.run("read", { path = big, whole = true })
ok(type(whole) ~= "string" or whole:find("too large", 1, true), "whole=true on a huge file is refused before reading")
local tl = v:tail(3)
ok(#tl == 3 and #tl[3] == LINE - 1, "tail(3) from the end, without the index")
local fl, fc = v:find("000004097")
ok(fl == 4097 and fc == 1, "find gives line and column: " .. tostring(fl) .. ":" .. tostring(fc))
v:close()
ok(not pcall(v.line, v, 1), "a closed view refuses reads")

-- truncation after open is refused, not a fault
local tf = dir .. "/trunc.txt"
local f = io.open(tf, "wb"); f:write(string.rep("line of text\n", 100000)); f:close()
local tv = assert(sys.view(tf))
ok(tv:line(50000) == "line of text", "before truncation")
f = io.open(tf, "r+b"); f:write("x"); f:close()       -- same size: fine
f = io.open(tf, "wb"); f:write("short\n"); f:close()  -- truncate in place
local okr, err = pcall(tv.line, tv, 90000)
ok(not okr and tostring(err):find("changed since it was opened", 1, true), "a shrunk file is refused: " .. tostring(err))
tv:close()
-- replaced by rename (how editors save): the old view keeps working
local rf = dir .. "/renamed.txt"
f = io.open(rf, "wb"); f:write("one\ntwo\n"); f:close()
local rv = assert(sys.view(rf))
f = io.open(rf .. ".new", "wb"); f:write("x\n"); f:close()
os.rename(rf .. ".new", rf)
ok(rv:line(2) == "two", "a file replaced by rename keeps its old view")
rv:close()
ok(sys.view(dir .. "/nope") == nil, "a missing file is nil, err")
os.remove(big); os.remove(small); os.remove(tf); os.remove(rf)
io.write(string.format("fileview: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
