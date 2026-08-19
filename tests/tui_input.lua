-- tests/tui_input.lua -- the cTUI input-line widget, exercised with no terminal.
--
-- tui/input.lua is pure state + logic (it does no terminal control), so every
-- branch is checkable here by feeding scripted key events and asserting on the
-- fields and the styled runs. Run with `./boggart --eval tests/tui_input.lua`:
-- no tty, no model call. It terminates itself and exits non-zero on any failure.
--
-- The events are the Contract A shape the real front end feeds -- { key=, char= }
-- -- built by the tiny constructors below. bog.complete / bog.repl_style are the
-- real policy globals in this binary; a couple of cases stub them on `bog` to
-- pin an exact completion / colouring without depending on the live registry.
local Input = require("tui.input")

local fails = 0
local function check(ok, msg)
  if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end
end

-- ---- event constructors (Contract A) ---------------------------------------
local function chars(s)                       -- one "char" event per codepoint
  local evs = {}
  for _, cp in utf8.codes(s) do evs[#evs + 1] = { key = "char", char = utf8.char(cp) } end
  return evs
end
local function K(name) return { key = name } end
local ENTER = { key = "enter" }
local TAB   = { key = "tab" }
local CTRLC = { key = "ctrl", char = "c" }
local ESC   = { key = "esc" }

-- Feed a list of events into a box, returning the last (action, value).
local function feed(box, evs)
  local a, v
  for _, ev in ipairs(evs) do a, v = box:key(ev) end
  return a, v
end
-- Concatenate the text of every run except the prompt (run 1).
local function body(runs)
  local t = {}
  for i = 2, #runs do t[#t + 1] = runs[i].text end
  return table.concat(t)
end

-- ---- typing inserts, Enter submits -----------------------------------------
do
  local box = Input.new()
  local a, v = feed(box, chars("hello world"))
  check(a == nil, "typing returns nil (edited in place)")
  check(box.line == "hello world", "typed text accumulates in .line")
  check(box.cursor == 11, "cursor sits at end after typing (" .. box.cursor .. ")")

  a, v = box:key(ENTER)
  check(a == "submit", "Enter -> submit")
  check(v == "hello world", "submit value is the line")
  check(box.line == "" and box.cursor == 0, "line clears after submit")
end

-- ---- backspace and cursor movement -----------------------------------------
do
  local box = Input.new()
  feed(box, chars("abcd"))
  box:key(K("backspace"))
  check(box.line == "abc", "backspace deletes the char before the cursor")
  check(box.cursor == 3, "backspace moves the cursor left")

  box:key(K("home"))
  check(box.cursor == 0, "home moves to column 0")
  box:key(K("right"))
  check(box.cursor == 1, "right moves one column")
  box:key({ key = "char", char = "X" })          -- insert mid-line
  check(box.line == "aXbc", "insert happens at the cursor, not the end")
  check(box.cursor == 2, "cursor advances past the inserted char")
  box:key(K("end"))
  check(box.cursor == 4, "end moves past the last char")
  box:key(K("left"))
  box:key(K("delete"))
  check(box.line == "aXb", "delete removes the char at the cursor")
  check(box.cursor == 3, "delete leaves the cursor in place")
end

-- ---- history: up recalls the last submission -------------------------------
do
  local box = Input.new{ history = { "seeded one" } }
  feed(box, chars("first"));  box:key(ENTER)
  feed(box, chars("second")); box:key(ENTER)
  check(box.line == "", "line empty before history recall")

  box:key(K("up"))
  check(box.line == "second", "up recalls the last submission")
  check(box.cursor == 6, "recalled line puts the cursor at its end")
  box:key(K("up"))
  check(box.line == "first", "up again recalls the earlier submission")
  box:key(K("up"))
  check(box.line == "seeded one", "up reaches the seeded history")
  box:key(K("down"))
  check(box.line == "first", "down walks back toward newer entries")
end

-- ---- Ctrl-C and Esc cancel -------------------------------------------------
do
  local box = Input.new()
  local a = box:key(CTRLC)
  check(a == "cancel", "Ctrl-C -> cancel")

  box = Input.new()
  a = box:key(ESC)
  check(a == "cancel", "Esc on an empty line -> cancel")

  box = Input.new()
  feed(box, chars("draft"))
  a = box:key(ESC)
  check(a == nil, "Esc on a non-empty line does not cancel")
  check(box.line == "", "Esc clears a non-empty line")
end

-- ---- Tab completion (stubbed bog.complete) ---------------------------------
do
  local saved = bog.complete
  -- Exactly one candidate: the trailing word is replaced outright.
  bog.complete = function() return { { text = "/model" } } end
  local box = Input.new()
  feed(box, chars("/mod"))
  box:key(TAB)
  check(box.line == "/model", "Tab with one candidate completes the word")
  check(box.cursor == 6, "cursor lands at the end of the completion")

  -- Several candidates: the longest common prefix is inserted.
  bog.complete = function() return { { text = "reset" }, { text = "resume" } } end
  box = Input.new()
  feed(box, chars("re"))
  box:key(TAB)
  check(box.line == "res", "Tab with several candidates inserts the common prefix")

  -- No candidate: nothing changes.
  bog.complete = function() return {} end
  box = Input.new()
  feed(box, chars("xyz"))
  box:key(TAB)
  check(box.line == "xyz", "Tab with no candidate is a no-op")

  bog.complete = saved
end

-- ---- Tab preserves the tail to the right of the cursor ---------------------
do
  local saved = bog.complete
  bog.complete = function() return { { text = "/model" } } end
  local box = Input.new()
  feed(box, chars("/mod tail"))
  for _ = 1, 5 do box:key(K("left")) end        -- cursor back to just after "/mod"
  box:key(TAB)
  check(box.line == "/model tail", "completion rewrites the word, keeps the tail")
  bog.complete = saved
end

-- ---- runs(): colour + cursor column (real bog.repl_style) ------------------
do
  -- /model is a known command -> command hex; /nope is unknown -> error hex.
  local CMD  = "#7fb77e"
  local BAD  = "#f77483"

  local box = Input.new()
  feed(box, chars("/model"))
  local runs, col = box:runs(80)
  check(body(runs) == box.line, "concat of runs (minus prompt) == .line")
  check(runs[1].text == "> ", "first run is the prompt")
  local saw_cmd = false
  for i = 2, #runs do if runs[i].fg == CMD then saw_cmd = true end end
  check(saw_cmd, "/model is coloured with the command hex")
  check(col == 2 + 6, "cursor_col is prompt width + chars before cursor (" .. col .. ")")

  box = Input.new()
  feed(box, chars("/nope"))
  runs = box:runs(80)
  local saw_bad = false
  for i = 2, #runs do if runs[i].fg == BAD then saw_bad = true end end
  check(saw_bad, "/nope (unknown command) is coloured with the error hex")
  check(body(runs) == "/nope", "unknown-command runs still join to the line")
end

-- ---- cursor_col tracks moves -----------------------------------------------
do
  local box = Input.new()
  feed(box, chars("abcdef"))
  local _, col = box:runs(80)
  check(col == 2 + 6, "cursor_col at end of a 6-char line")
  box:key(K("home"))
  _, col = box:runs(80)
  check(col == 2, "cursor_col at home is the prompt width")
  box:key(K("right")); box:key(K("right"))
  _, col = box:runs(80)
  check(col == 2 + 2, "cursor_col after two rights")
end

-- ---- multiline: Shift-Enter / Ctrl-Enter insert a newline, Enter submits ----
do
  local box = Input.new()
  feed(box, chars("one"))
  local a = box:key({ key = "enter", shift = true })
  check(a == nil, "Shift-Enter does not submit")
  check(box.line == "one\n", "Shift-Enter inserts a newline")
  feed(box, chars("two"))
  a = box:key({ key = "enter", ctrl = true })
  check(box.line == "one\ntwo\n", "Ctrl-Enter inserts a newline")
  local vis, row, col = box:visual(80)
  check(#vis >= 2, "visual() has a row per physical line")
  check(type(vis[1][1].text) == "string", "visual rows are Contract B run-lines")
  a = box:key(ENTER)
  check(a == "submit", "plain Enter still submits a multiline buffer")
end

-- ---- readline: Ctrl-A/E/K/U/W/Y -------------------------------------------
do
  local box = Input.new()
  feed(box, chars("hello world"))
  box:key({ key = "ctrl", char = "a" })
  check(box.cursor == 0, "Ctrl-A is beginning of line")
  box:key({ key = "ctrl", char = "e" })
  check(box.cursor == 11, "Ctrl-E is end of line")
  box:key({ key = "ctrl", char = "u" })
  check(box.line == "", "Ctrl-U kills to beginning of line")
  box:key({ key = "ctrl", char = "y" })
  check(box.line == "hello world", "Ctrl-Y yanks the kill buffer")
  box:key({ key = "ctrl", char = "w" })
  check(box.line == "hello ", "Ctrl-W kills the last word")
end

-- ---- completion menu: several candidates open an overlay -------------------
do
  local saved = bog.complete
  bog.complete = function()
    return { { text = "/reset", help = "h" }, { text = "/resume", help = "h" } }
  end
  local box = Input.new()
  feed(box, chars("/re"))
  box:key(TAB)
  check(box.line == "/res", "Tab still inserts the common prefix")
  check(box._menu ~= nil and #box._menu.items == 2, "several candidates open a menu")
  local rows = box:menu_runs(80)
  check(#rows == 2, "menu_runs lists both candidates")
  box:key(K("down"))
  box:key(ENTER)
  check(box.line == "/resume", "Enter on the menu picks the selected item")
  check(box._menu == nil, "picking closes the menu")
  bog.complete = saved
end

-- ---- @ file autocomplete: typing @ opens a menu; basename search works -----
do
  local box = Input.new()
  feed(box, chars("@"))
  check(box._menu ~= nil and #box._menu.items > 0, "typing @ opens the file menu")
  feed(box, chars("complete"))
  check(box._menu ~= nil, "further typing keeps the @ menu open (filters, does not dismiss)")
  local found = false
  for i, it in ipairs(box._menu.items) do
    if (it.text or it) == "@lua/complete.lua" then found = true; box._menu.sel = i end
  end
  check(found, "@complete menu includes @lua/complete.lua")
  box:key(ENTER)
  check(box.line == "@lua/complete.lua", "Enter on an @ hit replaces the token with the path")
end

do
  local box = Input.new()
  feed(box, chars("@lua/comp"))
  box:key(TAB)
  check(box.line:find("complete", 1, true), "Tab on @lua/comp completes inside that directory")
end

-- ---- paste inserts without submitting --------------------------------------
do
  local box = Input.new()
  local a = box:key({ type = "paste", text = "pasted\nlines" })
  check(a == nil, "paste does not submit")
  check(box.line == "pasted\nlines", "paste inserts the payload")
end

-- ---- Ctrl-R history search -------------------------------------------------
do
  local box = Input.new{ history = { "alpha", "bravo", "charlie" } }
  box:key({ key = "ctrl", char = "r" })
  check(box._search ~= nil, "Ctrl-R opens history search")
  box:key({ key = "char", char = "a" })
  box:key({ key = "char", char = "l" })
  box:key({ key = "char", char = "p" })
  local rows = box:search_runs(80)
  check(#rows >= 2, "search overlay lists matches")
  box:key(ENTER)
  check(box.line == "alpha", "Enter takes the matching history line")
  check(box._search == nil, "Enter closes search")
end

-- ---- history file persists submissions -------------------------------------
do
  local path = (os.tmpname and os.tmpname()) or "/tmp/boggart-hist-test"
  local box = Input.new{ history_file = path }
  feed(box, chars("remember me")); box:key(ENTER)
  local box2 = Input.new{ history_file = path }
  box2:key(K("up"))
  check(box2.line == "remember me", "a new box reloads history from the file")
  os.remove(path)
end

-- ---- runs never raise on a bad line (repl_style guarded) -------------------
do
  local saved = bog.repl_style
  bog.repl_style = function() error("boom") end
  local box = Input.new()
  feed(box, chars("still fine"))
  local ok, runs = pcall(function() return box:runs(80) end)
  check(ok, "runs() survives a raising repl_style")
  check(ok and body(runs) == "still fine", "text still renders when styling fails")
  bog.repl_style = saved
end

-- ---- utf8: a multibyte char is one editing unit ----------------------------
do
  local box = Input.new()
  feed(box, chars("café"))                       -- é is two bytes
  check(box.cursor == 4, "cursor counts codepoints, not bytes")
  box:key(K("backspace"))
  check(box.line == "caf", "backspace removes the whole multibyte char")
  check(box.cursor == 3, "cursor steps back one codepoint")
end

-- ---- report ----------------------------------------------------------------
if fails == 0 then
  io.write("ok  tui_input: all assertions passed\n")
else
  io.write(string.format("FAILED: %d assertion(s)\n", fails))
  os.exit(1)
end
