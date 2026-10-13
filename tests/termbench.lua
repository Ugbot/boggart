-- Headless measurements must exercise the real parser and must fail honestly.
package.path = "tools/?.lua;tools/?/init.lua;" .. package.path
local runner = require "termbench.runner"
local scenarios = require "termbench.scenarios"
local backend = require "termbench.backends.lua"
local native = require "termbench.backends.native"
local json = require "json"
local passed = 0
local function check(c, name) assert(c, name); passed = passed + 1 end
local function rejects(fn, name) check(not pcall(fn), name) end

local cases = scenarios.generate(2048)
check(#cases == 5, "all five workloads")
for i, case in ipairs(cases) do
  check(case.data == scenarios.generate(2048)[i].data, "deterministic " .. case.name)
  check(#case.data >= 2048, "complete units reach the byte target")
  check(utf8.len(case.data) ~= nil, "corpus does not truncate UTF-8")
  check(runner.check_stream(backend, case, { cols = 80, rows = 24 }, 7),
    "fragmentation preserves all state: " .. case.name)
end
for _, case in ipairs(cases) do
  check(runner.check_stream(native, case, { cols = 80, rows = 24 }, 1), "native stream: " .. case.name)
end
check(native.features.alt_screen and native.features.truecolor and native.features.wide and native.features.graphemes,
  "native feature boundary is explicit")
local identified = {}
for _, file in ipairs(native.source.files) do
  check(not identified[file.path], "source identities are unique: " .. file.path)
  identified[file.path] = true
end
for _, path in ipairs({ "src/lvt.c", "src/bunicode_data.h", "src/lgrapheme.c",
  "src/lpage_resize.c", "src/lpage_layout.c", "src/lpage_layout.h", "src/lterminal.c" }) do
  check(identified[path], "native identifies compiled terminal source: " .. path)
end
local terminal = require "terminal"
local saved_source = terminal.source
terminal.source = function()
  return { files = { { path = "src/lvt.c", sha256 = ("0"):rep(64) } } }
end
package.loaded["termbench.backends.native"] = nil
rejects(function() require "termbench.backends.native" end, "stale executable must not produce a speed claim")
terminal.source = saved_source
package.loaded["termbench.backends.native"] = native
local t = backend.new { cols = 8, rows = 3 }
t:feed("abc\r\n\27[31mX\27[0m\27[1;2HZ")
local s = t:snapshot()
check(s.screen[1][1].ch == "a" and s.screen[1][2].ch == "Z", "cursor addressing changes the grid")
check(s.screen[2][1].ch == "X" and s.screen[2][1].fg == 1, "real parser keeps colour")
check(s.cursor.row == 1 and s.cursor.col == 3, "cursor is screen-relative")
t:feed("\27[3;1H" .. ("line\r\n"):rep(2200))
s = t:snapshot()
check(#s.scrollback == 2000 and #s.screen == 3, "scrollback remains bounded")
t:close()
check(not backend.features.alt_screen and not backend.features.truecolor,
  "toy limitations are reported")
check(#backend.source.sha256 == 64, "report identifies exact parser source")
check(package.loaded["core.terminalview"] == nil, "adapter does not pollute studio module cache")

-- A fake clock/backend isolates accounting from machine speed. The runner
-- still has to feed every byte, reject a broken stream, and enforce budgets.
local tick, feeds, closes = 0, 0, 0
local fake = { name = "counter", features = {} }
function fake.new()
  local count = 0
  return {
    feed = function(_, bytes) count = count + #bytes; feeds = feeds + #bytes end,
    snapshot = function() return { bytes = count } end,
    close = function() closes = closes + 1 end,
  }
end
local report = runner.run(fake, {
  bytes = 100, samples = 3, chunk = 7, scenario = "plain",
  clock = function() tick = tick + 1000000; return tick end,
})
local r = report.results[1]
check(r.bytes >= 100 and r.samples_ns[1] == 1000000, "timing and byte accounting")
check(math.abs(r.mbps - r.bytes / 1000) < 1e-9, "decimal MB/s")
check(feeds == r.bytes * 6 and closes == 6, "two validation runs, warmup and three samples close")
check(json.decode(json.encode(report)).schema == 1, "report round-trips as JSON")
check(#r.corpus_sha256 == 64, "report identifies the measured corpus")
rejects(function() runner.run(fake, { bytes = 100, samples = 1,
  scenario = "plain", clock = function() tick = tick + 1000000; return tick end,
  budgets = { plain = { min_mbps = 1e9 } } }) end, "budget regression fails")
rejects(function() runner.run(fake, { samples = 0 }) end, "zero samples rejected")
rejects(function() runner.run(fake, { chunk = 0 }) end, "zero chunk rejected")
rejects(function() runner.run(fake, { bytes = -1 }) end, "negative byte target rejected")
rejects(function() runner.run(fake, { scenario = "missing" }) end, "unknown scenario rejected")
rejects(function() runner.run(fake, { budgets = { typo = { min_mbps = 1 } } }) end,
  "misspelled budget cannot silently pass")
rejects(function() runner.run(fake, { scenario = "plain",
  budgets = { scroll = { min_mbps = 1 } } }) end, "excluded budget cannot silently pass")
rejects(function() runner.check_stream(fake, cases[1], {}, 0) end, "zero validation chunk rejected")
rejects(function() runner.run(backend, { bytes = 100, samples = 1,
  scenario = "alt-screen", require_features = true }) end, "conformance requirement refuses toy")
local broken = { name = "broken", features = {} }
function broken.new()
  local calls = 0
  return { feed = function() calls = calls + 1 end,
    snapshot = function() return { calls = calls } end, close = function() end }
end
rejects(function() runner.check_stream(broken, cases[1], {}, 7) end,
  "chunk-dependent state fails before any timing")
io.write(string.format("termbench: %d passed\n", passed))
