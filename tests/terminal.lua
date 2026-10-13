local terminal = require "terminal"
local json = require "json"
local passed = 0
local function check(value, message) assert(value, message); passed = passed + 1 end
local function rejects(fn) check(not pcall(fn), "invalid operation must fail") end
local function cell(t, y, x) return t:row(y).cells[x] end
local t <close> = terminal.new(8, 3, 2)
check(#t:damage() == 3, "new screen is damaged")
t:ack_damage(); check(#t:damage() == 0, "ack clears visible damage")
t:feed("abc\r\n\27[38;2;1;2;3;48;5;9mX")
check(cell(t, 1, 1).codepoint == 97 and cell(t, 2, 1).codepoint == 88, "native cells")
check(cell(t, 2, 1).style.fg == terminal.COLOR_RGB | 0x010203, "truecolor remains tagged")
check(cell(t, 2, 1).style.bg == terminal.COLOR_INDEXED | 9, "palette colour remains tagged")
check(t:state().row == 2 and t:state().col == 2, "coordinates are one-based")
local copied = t:row(2); t:feed("\rY")
check(copied.cells[1].codepoint == 88 and cell(t, 2, 1).codepoint == 89, "rows are independent copies")
t:ack_damage(); t:feed("\27[3;1HZ"); check(t:damage()[1] == 3 and #t:damage() == 1, "only changed row")
t:feed("\27[6n\27[5n")
check(t:replies() == "\27[3;2R\27[0n" and t:replies() == "", "reply queue drains once")
t:feed("\r\n"); check(t:usage().history_rows == 1, "scroll stores history")
check(#t:snapshot().scrollback == 0 and #t:snapshot(true).scrollback == 1, "history copy is opt-in")
check(t:row(1, true).cells[1].codepoint == 97, "history rows use oldest-first indexing")
local snapshot = t:snapshot(true); check(type(json.decode(json.encode(snapshot))) == "table", "JSON snapshot")
t:feed("\27[?1049hALT\27[?2004;1004h")
check(t:state().alternate and t:usage().history_rows == 0, "alternate owns no history")
check(t:state().modes & terminal.BRACKETED_PASTE ~= 0 and t:state().modes & terminal.FOCUS ~= 0, "private modes")
t:feed("\27[?1049l"); check(not t:state().alternate and t:usage().history_rows == 1, "primary restored")
t:reset(); check(t:usage().styles == 1 and t:usage().history_rows == 0, "reset releases styles/history")
t:feed("\xe2"); check(t:snapshot().pending.utf8_need > 0 and cell(t, 1, 1).codepoint == 0, "partial UTF-8 held")
t:finish(); check(cell(t, 1, 1).codepoint == 0xfffd, "EOF emits replacement")
t:reset(); t:feed("\27]0;\xff\0")
check(json.decode(json.encode(t:snapshot())).pending.osc[3] == 255, "raw unfinished payload is JSON-compatible")
t:reset(); t:feed("\27[6n" .. ("\27[6n"):rep(9000))
local capacity = t:usage().reply_capacity
check(t:usage().reply_bytes <= capacity and #t:replies() > 0, "reply queue is bounded")
rejects(function() t:feed(("\27[6n"):rep(12000)) end)
rejects(function() t:feed("x") end)
check(#t:replies() <= capacity, "overflow preserves bounded queued replies")
t:reset(); t:feed("x"); check(cell(t, 1, 1).codepoint == 120, "reset recovers failure")
rejects(function() terminal.new(0, 2) end); rejects(function() terminal.new(2, 4097) end)
rejects(function() terminal.new(2, 2, -1) end); rejects(function() terminal.new(2, 2, 1.5) end)
rejects(function() t:row(0) end); rejects(function() t:row(4) end); rejects(function() t:feed(42) end)
t:close(); t:close(); rejects(function() t:state() end); rejects(function() t:feed("x") end)
for i = 1, 200 do
  local temp <close> = terminal.new(2, 2, 1); temp:feed("\27[31mhello"); temp:feed("\27[?1049hx")
end
collectgarbage("collect")
local weak = setmetatable({}, { __mode = "v" })
for i = 1, 50 do
  weak[i] = terminal.new(2, 2, 1); weak[i]:feed("\27[31mhello\27[?1049hX")
end
collectgarbage("collect"); collectgarbage("collect")
check(next(weak) == nil, "unclosed objects are collected")
io.write(string.format("terminal: %d passed\n", passed))
