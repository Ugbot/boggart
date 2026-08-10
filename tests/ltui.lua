-- ltui.lua -- verifies the vendored ltui terminal-UI tree (Apache-2.0, tboox)
-- loads inside boggart: all 37 Lua modules resolve through the embedded
-- searcher, the C curses binding registers via package.preload, and the object
-- system works headlessly. No terminal is initialised (curses.init() is never
-- called), so this runs fine under ctest with no tty.
--
-- Also guards the two real bugs found while vendoring, both of which would be
-- silent and miserable to debug in the field. See src/vendor/ltui/PATCHES.md.
local strict = require("strict")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

-- ---- loading ----
-- ltui's module idiom is `local view = view or object()` in every file, which
-- reads an undefined global. strict.without lifts the guard for trusted
-- vendored code rather than forking 32 files.
local lok, ltui = pcall(strict.without, require, "ltui")
ok(lok, "require('ltui') succeeds: " .. (lok and "" or tostring(ltui)))
if not lok then
  io.write(string.format("\n%d passed, %d failed\n", passed, failed))
  return 1
end
eq(type(ltui), "table", "ltui is a table")

-- ---- the C binding (package.preload['ltui.lcurses'], set in boggart.c) ----
eq(type(ltui.curses), "table", "curses binding loaded")
eq(type(package.loaded["ltui.lcurses"]), "table", "lcurses registered via preload")

-- ---- widget surface a swarm dashboard needs ----
for _, m in ipairs({ "application", "program", "window", "panel", "desktop",
                     "textarea", "textedit", "label", "button", "border",
                     "event", "rect", "point", "canvas", "view", "object",
                     "statusbar", "menubar", "scrollbar", "dialog" }) do
  ok(ltui[m] ~= nil, "ltui." .. m .. " present")
end

-- ---- object system works headlessly (pure geometry, no terminal) ----
local r = ltui.rect{1, 2, 11, 10}
eq(r:width(), 10, "rect width")
eq(r:height(), 8, "rect height")
local p = ltui.point{3, 4}
eq(p.x, 3, "point x")
eq(p.y, 4, "point y")

-- ---- regression: ltui must not destroy stock table.unpack ----
-- ltui/base/table.lua carried `table.unpack = unpack` as a Lua 5.1 polyfill.
-- The global `unpack` was removed in 5.2, so on our vendored 5.4 that assigned
-- nil and broke table.unpack for the whole process.
eq(type(table.unpack), "function", "stock table.unpack survives ltui load")
eq(select(2, table.unpack({"a", "b"})), "b", "table.unpack still works")
eq(table.pack(1, 2, 3).n, 3, "table.pack still reports n")

-- ---- regression: curses setlocale must not move the decimal separator ----
-- luaopen_ltui_lcurses calls setlocale(LC_ALL, ""). In a comma-decimal locale
-- that makes string.format("%.14g", 1.5) yield "1,5"; lua/json.lua formats
-- numbers exactly that way, so every API request body would be corrupt.
eq(string.format("%.14g", 1.5), "1.5", "LC_NUMERIC pinned to C after curses load")
eq(tostring(0.5), "0.5", "tostring uses '.' decimal separator")
ok(json ~= nil and json.encode({ x = 1.5 }):find("1.5", 1, true) ~= nil,
   "json.encode emits a dot decimal separator")

-- ---- strict must be restored after the without() window ----
ok(not pcall(function() return _G.definitely_not_a_global_xyz end),
   "strict global guard restored after strict.without")

-- ---------------------------------------------------------------------------
-- lua/dash.lua -- the swarm dashboard built on ltui. Only the terminal-free
-- half is exercised here: layout maths, row/statusline formatting, truncation
-- and the per-agent line buffers. Nothing below initialises curses, and
-- require("dash") must not drag ltui in by itself.
-- ---------------------------------------------------------------------------
package.loaded["ltui"] = nil -- prove dash does not need ltui at load time
local dok, dash = pcall(require, "dash")
ok(dok, "require('dash') succeeds: " .. (dok and "" or tostring(dash)))
eq(package.loaded["ltui"], nil, "require('dash') does not load ltui")
package.loaded["ltui"] = ltui
ok(not dash.active(), "dashboard is inert until started")

-- clipping / padding (byte-safe, must not split a UTF-8 sequence)
eq(dash.clip("hello", 10), "hello", "clip leaves short text alone")
eq(dash.clip("hello world", 8), "hello ..", "clip marks truncation")
eq(#dash.clip("abcdefghij", 6), 6, "clip result is exactly the width")
eq(dash.clip("abc", 0), "", "clip to zero width")
ok(not dash.clip("\u{2588}\u{2588}\u{2588}\u{2588}", 5):find("\239\191\189"),
   "clip does not emit a replacement char")
eq(#dash.pad("ab", 6), 6, "pad fills to the width")
eq(dash.pad("abcdef", 3), "abcdef", "pad never shortens")

-- escape stripping: agent output carries ANSI from bog.log_tool
eq(dash.strip("\27[36m> bash\27[0m"), "> bash", "strip removes CSI sequences")
eq(dash.strip("a\tb"), "a  b", "strip expands tabs")
eq(dash.strip("a\r\nb"), "a\nb", "strip normalises CRLF")

-- wrapping and tailing
eq(#dash.wrap("abcdefgh", 3), 3, "wrap splits long lines")
eq(dash.wrap("ab\ncd", 10)[2], "cd", "wrap keeps existing newlines")
eq(table.concat(dash.tail({ "a", "b", "c" }, 2), ""), "bc", "tail takes the last n")
eq(#dash.tail({ "a" }, 5), 1, "tail copes with n > #lines")

-- formatting helpers
eq(dash.human(512), "512", "human bytes")
eq(dash.human(2048), "2.0k", "human kilobytes")
eq(dash.mmss(0), "00:00", "mmss zero")
eq(dash.mmss(125), "02:05", "mmss minutes")
eq(dash.mmss(3661), "1:01:01", "mmss hours")

-- layout: 80x24 gets a header, a roster and a detail pane; it degrades down
local L = dash.layout(80, 24, 4)
eq(L.header, 1, "80x24 has a header row")
eq(L.rows, 4, "80x24 shows all 4 agents")
eq(L.roster_y + L.rows, L.divider_y, "divider sits under the roster")
eq(L.divider_y + 1, L.detail_y, "detail sits under the divider")
eq(L.header + L.rows + 1 + L.detail_h, 23, "body fills every row but the status bar")
ok(not L.compact, "80 columns is not compact")

local Lsmall = dash.layout(40, 8, 2)
ok(Lsmall.compact, "40 columns switches to the compact row format")
eq(Lsmall.header + Lsmall.rows + (Lsmall.detail_h > 0 and 1 + Lsmall.detail_h or 0), 7,
   "8-line body still adds up")

local Ltiny = dash.layout(30, 6, 3)
eq(Ltiny.detail_h, 0, "6 lines drops the detail pane")
ok(Ltiny.rows >= 1, "6 lines still shows at least one agent")

local Lmany = dash.layout(80, 24, 40)
ok(Lmany.rows < 40, "more agents than rows are clamped")
eq(Lmany.more, 40 - Lmany.rows, "the overflow count is reported")

-- status mapping: the scheduler's yield kinds become the displayed state
eq(dash.status_word{ sched = "runnable" }, "run", "runnable -> run")
eq(dash.status_word{ sched = "io" }, "io", "io -> io (waiting on http)")
eq(dash.status_word{ sched = "recv" }, "mail", "recv -> mail (waiting on mail)")
eq(dash.status_word{ seen_sched = true }, "done", "gone from the scheduler -> done")
eq(dash.status_word{ db = "error" }, "err", "store error -> err")
eq(dash.status_word{}, "new", "never scheduled -> new")
eq(dash.attr_for("err", false), "red", "errors are red")
eq(dash.attr_for("run", true), "black onwhite", "the selected row is inverted")

-- row / header / status bar are all exactly one screen line wide
local rec = { id = 7, kind = "researcher", sched = "io", bytes = 4096, tools = 2,
              t0 = 100, lines = { "reading the vendor patches" }, partial = "" }
local line = dash.row(rec, 80, false, 142, false)
eq(#line, 80, "a roster row is exactly the terminal width")
ok(line:find("researcher", 1, true) ~= nil, "row shows the agent kind")
ok(line:find("io", 1, true) ~= nil, "row shows the state")
ok(line:find("00:42", 1, true) ~= nil, "row shows elapsed time")
ok(line:find("reading the vendor", 1, true) ~= nil, "row tails recent activity")
eq(#dash.row(rec, 40, true, 142, true), 40, "compact row is exactly the width")
ok(dash.row(rec, 40, true, 142, true):sub(1, 1) == ">", "selected rows are marked")
eq(#dash.header_text(80, false), 80, "header is exactly the width")
eq(#dash.header_text(38, true), 38, "compact header is exactly the width")

local tot = dash.totals({
  { sched = "runnable", bytes = 10 }, { sched = "io", bytes = 20 },
  { sched = "recv", bytes = 0 }, { seen_sched = true, bytes = 5 }, { db = "error" },
})
eq(tot.n, 5, "totals count every agent")
eq(tot.run, 1, "totals count runnable agents")
eq(tot.io, 1, "totals count io-blocked agents")
eq(tot.mail, 1, "totals count mail-blocked agents")
eq(tot.done, 1, "totals count finished agents")
eq(tot.err, 1, "totals count failed agents")
eq(tot.bytes, 35, "totals sum output bytes")
eq(#dash.statusline(tot, 80, 61), 80, "status bar is exactly the width")
ok(dash.statusline(tot, 80, 61):find("01:01", 1, true) ~= nil, "status bar shows elapsed")
eq(#dash.statusline(tot, 30, 61), 30, "status bar clips on a narrow terminal")

-- per-agent line buffers: feed() splits streamed chunks, emit() adds whole lines
dash.agents, dash.order = {}, {}
dash.feed(3, "hello ")
dash.feed(3, "world\nsecond ")
local a3 = dash.agents[3]
eq(#a3.lines, 1, "feed only completes a line at the newline")
eq(a3.lines[1], "hello world", "feed joins chunks")
eq(a3.partial, "second ", "feed holds the incomplete tail")
eq(a3.bytes, 19, "feed counts raw bytes")
eq(dash.activity(a3), "second ", "activity prefers the in-flight partial line")
dash.emit(3, "> bash: ls")
eq(a3.lines[3], "> bash: ls", "emit flushes the partial then appends")
eq(a3.partial, "", "emit clears the partial")
eq(dash.activity(a3), "> bash: ls", "activity falls back to the last full line")
eq(#dash.order, 1, "feed registers the agent once")
dash.feed(4, "x")
eq(#dash.order, 2, "a second agent is registered")
eq(dash.selected(), 4, "selection auto-follows the newest output")
dash.select_delta(-1)
eq(dash.selected(), 3, "up moves the selection")
dash.select_delta(-5)
eq(dash.selected(), 3, "selection clamps at the top")

local saved = dash.MAXLINES
dash.MAXLINES = 3
for i = 1, 10 do dash.emit(3, "line " .. i) end
eq(#dash.agents[3].lines, 3, "the per-agent buffer is bounded")
eq(dash.agents[3].lines[3], "line 10", "the newest line is kept")
dash.MAXLINES = saved

local det = dash.detail_text(dash.agents[3], 40, 4)
eq(#(det:gsub("[^\n]", "")), 3, "detail pane fills exactly its height")
ok(det:find("agent 3", 1, true) == 1, "detail pane starts with an agent header")
eq(dash.detail_text(nil, 40, 4), "(no agents yet)", "detail pane copes with no agents")
dash.agents, dash.order = {}, {}

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
return failed == 0 and 0 or 1
