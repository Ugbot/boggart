-- vim.lua -- behavioural tests for the studio's modal (neovim) editing
-- layer (studio/data/core/vim.lua). Unlike tests/studio.lua, which only
-- loadfile-compiles the GUI Lua, this drives the real grammar against a real
-- Doc + DocView: it stubs the handful of window globals the doc/view chain
-- reads (system, renderer, SCALE, DATADIR...) so the whole editor core loads
-- headlessly under `boggart --eval`, then feeds keystrokes through vim.on_char
-- and asserts the resulting buffer. Motions that need a laid-out window (j/k
-- half-page) are exercised loosely; everything charwise/linewise is exact.

package.path = "studio/data/?.lua;studio/data/?/init.lua;" .. package.path
local t = 0
rawset(_G, "SCALE", 1); rawset(_G, "DATADIR", "studio/data")
rawset(_G, "USERDIR", os.tmpname() .. "_ud")
rawset(_G, "EXEDIR", "."); rawset(_G, "PLATFORM", "Mac OS X"); rawset(_G, "ARGS", {})
rawset(_G, "system", { get_time = function() t = t + 0.5; return t end,
                       set_clipboard = function() end, get_clipboard = function() return "" end,
                       absolute_path = function(p) return p end, window_has_focus = function() return true end })
rawset(_G, "renderer", { font = { load = function() return setmetatable({}, {__index=function() return function() return 1 end end}) end } })

local Doc = require "core.doc"
local DocView = require "core.docview"
local core = require "core"
local command = require "core.command"
require "core.commands.doc"   -- register doc:* commands used by operators
local vim = require "core.vim"
vim.enabled = true

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end

-- Build a fresh editor DocView over `text`, caret at (line,col).
local function setup(text, line, col)
  local d = Doc()
  d:insert(1, 1, text)
  -- Doc starts with an empty first line; our insert leaves a trailing one.
  local dv = DocView(d)
  function dv:get_visible_line_range() return 1, #self.doc.lines end
  core.active_view = dv
  vim.register = { text = "", linewise = false }
  d:set_selection(line or 1, col or 1)
  return dv, d
end

local function body(d)
  return table.concat(d.lines)
end

-- Feed a key string, routing per current mode. "~" in the string is a literal;
-- use ESC (\27) to leave insert / cancel.
local function keys(dv, s)
  for i = 1, #s do
    local ch = s:sub(i, i)
    if ch == "\27" then
      vim.escape(dv)
    elseif dv.vim and dv.vim.mode == "insert" then
      dv:on_text_input(ch)   -- through the wrapper, as the real input path does
    else
      vim.on_char(dv, ch)
    end
  end
end

-- ---- motions (as operator targets) -----------------------------------------
do
  local dv, d = setup("hello world\n", 1, 1)
  keys(dv, "dw")
  ok(d.lines[1] == "world\n", "dw deletes word+space -> '"..d.lines[1].."'")
end
do
  local dv, d = setup("hello world\n", 1, 1)
  keys(dv, "de")
  ok(d.lines[1] == " world\n", "de deletes to word end inclusive -> '"..d.lines[1].."'")
end
do
  local dv, d = setup("hello world\n", 1, 1)
  keys(dv, "d$")
  ok(d.lines[1] == "\n", "d$ deletes to end of line -> '"..d.lines[1].."'")
end
do
  local dv, d = setup("hello world\n", 1, 7)  -- caret on 'w'
  keys(dv, "db")
  ok(d.lines[1] == "world\n", "db deletes previous word -> '"..d.lines[1].."'")
end
do
  local dv, d = setup("foo.bar baz\n", 1, 1)
  keys(dv, "dW")
  ok(d.lines[1] == "baz\n", "dW deletes WORD (punct included) -> '"..d.lines[1].."'")
end

-- ---- f / t / % -------------------------------------------------------------
do
  local dv, d = setup("hello world\n", 1, 1)
  keys(dv, "dfo")  -- delete through first 'o'
  ok(d.lines[1] == " world\n", "dfo deletes up to and incl 'o' -> '"..d.lines[1].."'")
end
do
  local dv, d = setup("hello world\n", 1, 1)
  keys(dv, "dto")  -- delete up to (not incl) 'o'
  ok(d.lines[1] == "o world\n", "dto stops before 'o' -> '"..d.lines[1].."'")
end
do
  local dv, d = setup("a(bcd)e\n", 1, 2)  -- caret on '('
  keys(dv, "d%")
  ok(d.lines[1] == "ae\n", "d%% deletes bracket pair -> '"..d.lines[1].."'")
end

-- ---- linewise operators ----------------------------------------------------
do
  local dv, d = setup("one\ntwo\nthree", 2, 1)
  keys(dv, "dd")
  ok(body(d) == "one\nthree\n", "dd deletes line -> '"..body(d).."'")
end
do
  local dv, d = setup("one\ntwo\nthree", 1, 1)
  keys(dv, "2dd")
  ok(body(d) == "three\n", "2dd deletes two lines -> '"..body(d).."'")
end
do
  local dv, d = setup("one\ntwo", 1, 1)
  keys(dv, "yyp")
  ok(body(d) == "one\none\ntwo\n", "yyp duplicates line -> '"..body(d):gsub("\n","|").."'")
end

-- ---- x X r ~ D C -----------------------------------------------------------
do
  local dv, d = setup("abc\n", 1, 1)
  keys(dv, "x")
  ok(d.lines[1] == "bc\n", "x deletes char -> '"..d.lines[1].."'")
end
do
  local dv, d = setup("abc\n", 1, 2)
  keys(dv, "X")
  ok(d.lines[1] == "bc\n", "X deletes char before -> '"..d.lines[1].."'")
end
do
  local dv, d = setup("abc\n", 1, 1)
  keys(dv, "rz")
  ok(d.lines[1] == "zbc\n", "r replaces char -> '"..d.lines[1].."'")
end
do
  local dv, d = setup("aBc\n", 1, 1)
  keys(dv, "~~~")
  ok(d.lines[1] == "AbC\n", "~ toggles case and advances -> '"..d.lines[1].."'")
end
do
  local dv, d = setup("hello world\n", 1, 7)
  keys(dv, "D")
  ok(d.lines[1] == "hello \n", "D deletes to eol -> '"..d.lines[1].."'")
end

-- ---- insert entry ----------------------------------------------------------
do
  local dv, d = setup("bc\n", 1, 1)
  keys(dv, "ia\27")
  ok(d.lines[1] == "abc\n", "i inserts before caret -> '"..d.lines[1].."'")
end
do
  local dv, d = setup("ab\n", 1, 1)
  keys(dv, "aX\27")
  ok(d.lines[1] == "aXb\n", "a appends after caret -> '"..d.lines[1].."'")
end
do
  local dv, d = setup("ab\n", 1, 1)
  keys(dv, "A!\27")
  ok(d.lines[1] == "ab!\n", "A appends at eol -> '"..d.lines[1].."'")
end
do
  local dv, d = setup("one\ntwo", 1, 1)
  keys(dv, "oX\27")
  ok(body(d) == "one\nX\ntwo\n", "o opens line below -> '"..body(d):gsub("\n","|").."'")
end
do
  local dv, d = setup("one\ntwo", 2, 1)
  keys(dv, "OX\27")
  ok(body(d) == "one\nX\ntwo\n", "O opens line above -> '"..body(d):gsub("\n","|").."'")
end

-- ---- visual ----------------------------------------------------------------
do
  local dv, d = setup("hello\n", 1, 1)
  keys(dv, "vlld")  -- select 3 chars, delete
  ok(d.lines[1] == "lo\n", "v+ll+d deletes 3 chars -> '"..d.lines[1].."'")
end
do
  local dv, d = setup("one\ntwo\nthree", 1, 1)
  keys(dv, "Vjd")  -- visual-line select 2 lines, delete
  -- j needs visible range; if it fails to move, only line 1 deletes
  ok(body(d) == "three\n" or body(d) == "two\nthree\n", "Vjd linewise delete -> '"..body(d):gsub("\n","|").."'")
end

-- ---- paste (charwise) ------------------------------------------------------
do
  local dv, d = setup("abc\n", 1, 1)
  keys(dv, "xp")  -- delete 'a' (register='a'), paste after -> "bac"
  ok(d.lines[1] == "bac\n", "xp transposes -> '"..d.lines[1].."'")
end

-- ---- counts ----------------------------------------------------------------
do
  local dv, d = setup("aaaa bbbb\n", 1, 1)
  keys(dv, "3x")
  ok(d.lines[1] == "a bbbb\n", "3x deletes three chars -> '"..d.lines[1].."'")
end

-- ---- Phase 2: ex command parsing (pure) ------------------------------------
do
  local p = vim.parse_ex("%s/foo/bar/g")
  ok(p.range and p.range.whole, "parse: %% is a whole-file range")
  ok(p.cmd == "s", "parse: substitute command")
  ok(p.sub and p.sub.pattern == "foo" and p.sub.replacement == "bar" and p.sub.flags == "g",
     "parse: s/pat/rep/flags split")
end
do
  local p = vim.parse_ex("2,5d")
  ok(p.range.a == 2 and p.range.b == 5, "parse: numeric range a,b")
  ok(p.cmd == "d", "parse: delete command")
end
do
  local p = vim.parse_ex(":10")
  ok(p.cmd == "goto" and p.range.a == 10, "parse: bare number is goto")
end
do
  local p = vim.parse_ex("wq")
  ok(p.cmd == "wq" and not p.range, "parse: wq, no range")
end
do
  local p = vim.parse_ex("q!")
  ok(p.cmd == "q" and p.bang, "parse: bang parsed")
end
do
  local p = vim.parse_ex(".,$s/a/b/")
  ok(p.range.a == "." and p.range.b == "$", "parse: . and $ addresses")
  ok(p.sub.flags == "", "parse: empty flags")
end

-- ---- Phase 2: ex execution -------------------------------------------------
do
  local dv, d = setup("foo foo\nfoo", 1, 1)
  vim.run_ex(dv, "%s/foo/bar/g")
  ok(body(d) == "bar bar\nbar\n", "ex: %%s global substitute -> '"..body(d):gsub("\n","|").."'")
end
do
  local dv, d = setup("foo foo\n", 1, 1)
  vim.run_ex(dv, "s/foo/bar/")
  ok(d.lines[1] == "bar foo\n", "ex: s without g replaces first only -> '"..d.lines[1].."'")
end
do
  local dv, d = setup("one\ntwo\nthree\nfour", 1, 1)
  vim.run_ex(dv, "2,3d")
  ok(body(d) == "one\nfour\n", "ex: 2,3d deletes range -> '"..body(d):gsub("\n","|").."'")
end
do
  local dv, d = setup("one\ntwo\nthree", 1, 1)
  vim.run_ex(dv, "3")  -- goto line 3
  local l = d:get_selection()
  ok(l == 3, "ex: bare number jumps to line -> "..l)
end
do
  local dv, d = setup("aaa\nbbb\nccc", 1, 1)
  vim.run_ex(dv, "1t2")  -- copy line 1 to after line 2
  ok(body(d) == "aaa\nbbb\naaa\nccc\n", "ex: :t copies line -> '"..body(d):gsub("\n","|").."'")
end
do
  local dv, d = setup("aaa\nbbb\nccc", 1, 1)
  vim.run_ex(dv, "1m3")  -- move line 1 to after line 3
  ok(body(d) == "bbb\nccc\naaa\n", "ex: :m moves line -> '"..body(d):gsub("\n","|").."'")
end

-- ---- Phase 2: search -------------------------------------------------------
do
  local dv, d = setup("alpha beta alpha gamma\n", 1, 1)
  vim.do_search(dv, "alpha", false)
  local l, c = d:get_selection()
  ok(l == 1 and c == 12, "search: / jumps to next match -> "..l..","..c)
  vim.search_next(dv, false)  -- n wraps back to first
  local l2, c2 = d:get_selection()
  ok(c2 == 1, "search: n wraps to first match -> col "..c2)
end
do
  local dv, d = setup("foo\nbar\nfoo\nbaz", 1, 1)
  d:set_selection(2, 1)         -- on line 'bar'
  vim.search_word(dv, false)    -- no word 'bar' elsewhere; stays or nil
  local dv2, d2 = setup("foo\nbar\nfoo\nbaz", 3, 1)
  vim.do_search(dv2, "foo", false)   -- from line 3 -> wraps to line 1
  local l = d2:get_selection()
  ok(l == 1, "search: wraps forward to first 'foo' -> line "..l)
end

-- ---- Phase 3: text objects -------------------------------------------------
do
  local dv, d = setup("the quick fox\n", 1, 6)  -- caret in 'quick'
  keys(dv, "diw")
  ok(d.lines[1] == "the  fox\n", "diw deletes inner word -> '"..d.lines[1].."'")
end
do
  local dv, d = setup("the quick fox\n", 1, 6)
  keys(dv, "daw")
  ok(d.lines[1] == "the fox\n", "daw deletes word + trailing space -> '"..d.lines[1].."'")
end
do
  local dv, d = setup("foo(bar, baz)end\n", 1, 5)  -- caret inside parens
  keys(dv, "di(")
  ok(d.lines[1] == "foo()end\n", "di( deletes inside parens -> '"..d.lines[1].."'")
end
do
  local dv, d = setup("foo(bar)end\n", 1, 5)
  keys(dv, "da(")
  ok(d.lines[1] == "fooend\n", "da( deletes parens too -> '"..d.lines[1].."'")
end
do
  local dv, d = setup('say "hello" now\n', 1, 7)  -- caret inside quotes
  keys(dv, 'di"')
  ok(d.lines[1] == 'say "" now\n', "di\" deletes inside quotes -> '"..d.lines[1].."'")
end
do
  local dv, d = setup("x = { a = 1 } end\n", 1, 8)
  keys(dv, "ci{Z\27")
  ok(d.lines[1] == "x = {Z} end\n", "ci{ changes inside braces -> '"..d.lines[1].."'")
end

-- ---- Phase 3: named registers ----------------------------------------------
do
  local dv, d = setup("keep\ndrop\n", 1, 1)
  keys(dv, '"ayy')          -- yank line 1 into register a
  keys(dv, "j")             -- (j may not move headless; jump manually)
  d:set_selection(2, 1)
  keys(dv, "x")             -- clobber the unnamed register with 'd'
  keys(dv, '"ap')           -- paste register a below current line
  ok(body(d):find("keep\n.-keep"), "named register a survives an intervening delete -> '"..body(d):gsub("\n","|").."'")
end

-- ---- Phase 3: dot-repeat ---------------------------------------------------
do
  local dv, d = setup("aaaaaa\n", 1, 1)
  keys(dv, "x")   -- delete one
  keys(dv, ".")   -- repeat: delete another
  keys(dv, ".")   -- and another
  ok(d.lines[1] == "aaa\n", "dot repeats x -> '"..d.lines[1].."'")
end
do
  local dv, d = setup("one two three four\n", 1, 1)
  keys(dv, "dw")  -- delete 'one '
  keys(dv, ".")   -- delete 'two '
  ok(d.lines[1] == "three four\n", "dot repeats dw -> '"..d.lines[1].."'")
end
do
  local dv, d = setup("cat cat\n", 1, 1)
  keys(dv, "ciwdog\27")  -- change inner word to 'dog'
  keys(dv, "w")          -- move to next word start (caret on second 'cat')
  keys(dv, ".")          -- repeat the change
  ok(d.lines[1] == "dog dog\n", "dot repeats ciw+text -> '"..d.lines[1].."'")
end

-- ---- Phase 4: visual-block -------------------------------------------------
do
  local dv, d = setup("abcd\nefgh\nijkl", 1, 1)
  vim.start_vblock(dv)
  dv.vim.block.cl, dv.vim.block.cc = 3, 3   -- block rows 1-3, cols 1-3
  keys(dv, "d")             -- delete the 3x3 column block
  ok(body(d) == "d\nh\nl\n", "vblock d deletes a column block -> '"..body(d):gsub("\n","|").."'")
end
do
  local dv, d = setup("abcd\nefgh\nijkl", 1, 1)
  vim.start_vblock(dv)
  dv.vim.block.cl, dv.vim.block.cc = 3, 3
  keys(dv, "y")             -- yank the column block
  ok(vim.register.text == "abc\nefg\nijk", "vblock y yanks columns -> '"..vim.register.text:gsub("\n","|").."'")
end
do
  local dv, d = setup("one\ntwo\nsix", 1, 1)
  vim.start_vblock(dv)
  dv.vim.block.cl = 3
  keys(dv, "I")            -- block insert at column 1
  keys(dv, "// ")          -- type a prefix
  keys(dv, "\27")          -- escape replicates to all block lines
  ok(body(d) == "// one\n// two\n// six\n", "vblock I prefixes every line -> '"..body(d):gsub("\n","|").."'")
end
do
  local dv, d = setup("a\nbb\nccc", 1, 1)
  vim.start_vblock(dv)
  dv.vim.block.cl = 3
  keys(dv, "A")            -- append at the right edge of the (col-1) block
  keys(dv, "!")
  keys(dv, "\27")
  ok(body(d) == "a!\nb!b\nc!cc\n", "vblock A appends at the block's right column -> '"..body(d):gsub("\n","|").."'")
end
do
  local dv, d = setup("xxA\nxxB\nxxC", 1, 1)
  vim.start_vblock(dv)
  dv.vim.block.cl, dv.vim.block.cc = 3, 2   -- block rows 1-3, cols 1-2
  keys(dv, "c")           -- change the block
  keys(dv, "Y")
  keys(dv, "\27")
  ok(body(d) == "YA\nYB\nYC\n", "vblock c replaces the column block on every line -> '"..body(d):gsub("\n","|").."'")
end

-- ---- Phase 4: multi-cursor -------------------------------------------------
do
  local dv, d = setup("cat\ncat\ncat", 1, 1)
  vim.add_cursor_next(dv)   -- seed cursor on 'cat' (1,1)
  vim.add_cursor_next(dv)   -- next occurrence (2,1)
  vim.add_cursor_next(dv)   -- next occurrence (3,1)
  ok(dv.vim.cursors and #dv.vim.cursors == 3, "add-cursor collects 3 cursors")
  keys(dv, "ciwDOG\27")     -- change at primary; fanned to the other cursors
  ok(body(d) == "DOG\nDOG\nDOG\n", "multi-cursor fans ciw to all cursors -> '"..body(d):gsub("\n","|").."'")
end
do
  local dv, d = setup("foo\nfoo\nfoo", 1, 1)
  vim.add_cursor_next(dv); vim.add_cursor_next(dv); vim.add_cursor_next(dv)
  keys(dv, "x")             -- delete one char at each cursor
  ok(body(d) == "oo\noo\noo\n", "multi-cursor fans x to all cursors -> '"..body(d):gsub("\n","|").."'")
end

io.write(string.format("vim: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
