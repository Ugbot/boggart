-- studio.lua -- the studio's Lua actually compiles.
--
-- Written after a read-only-for-loop-variable slip in agentview.lua took the
-- whole window down: the app came up, core.studio failed to load, and the only
-- symptom was an editor with no agent in it. A compile error in a UI file is
-- not a subtle bug, but it is an invisible one -- nothing else in the suite
-- loads these files, and the app funnels the error into a log view that nobody
-- reads in CI. loadfile() catches the whole class in milliseconds, headlessly,
-- on every platform.
--
-- This checks that they compile, not that they work: these modules need a
-- window and a running editor to do anything at all. Behaviour is covered by
-- `ninja ui-check`, which renders a real frame and therefore cannot run here.
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end

-- Tests run from the build directory, so find the source tree from this file.
local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]+$") or "."
local root = here:match("^(.*)[/\\][^/\\]+$") or "."

local dirs = {
  root .. "/studio/data/core",
  root .. "/studio/data/core/commands",
  root .. "/studio/data/core/doc",
  root .. "/studio/data/plugins",
  root .. "/studio/data/shell",             -- the new ground-up shell (P0+)
  root .. "/studio/data/shell/workspaces",
  root .. "/studio/data/shell/agent",
}

local files = {}
for _, dir in ipairs(dirs) do
  for _, name in ipairs(sys.listdir(dir) or {}) do
    if name:match("%.lua$") then files[#files + 1] = dir .. "/" .. name end
  end
end

ok(#files > 20, "found the studio's Lua (" .. #files .. " files)")

for _, path in ipairs(files) do
  local fn, err = loadfile(path)
  local short = path:sub(#root + 2)
  ok(fn ~= nil, "compiles: " .. short .. (fn and "" or ("  -- " .. tostring(err))))
end

-- The pieces the app cannot start without, named so that a rename losing one
-- fails here rather than at launch.
for _, must in ipairs {
  "studio/data/core/init.lua",
  "studio/data/core/agentview.lua",
  "studio/data/core/agentcomplete.lua",
  "studio/data/core/sidebarview.lua",
  "studio/data/core/studio.lua",
  "studio/data/core/widgets.lua",
  "studio/data/core/recipes.lua",
  "studio/data/core/diff.lua",
  "studio/data/core/rootview.lua",
} do
  ok(loadfile(root .. "/" .. must) ~= nil, "present and compiles: " .. must)
end

-- ---------------------------------------------------------------------------
-- The agent panel's text handling, headless
-- ---------------------------------------------------------------------------
--
-- Everything above is a compile check. This runs the real agentview.lua against
-- a fake window: a stub `renderer` whose fonts are exactly one unit wide, and a
-- stub `core`, which between them are all the module needs to be loaded and
-- called. Nothing here draws.
--
-- It exists because the panel's genuinely tricky code -- wrapping, the markdown
-- scanner, the caret -- is pure string arithmetic that a rendered frame checks
-- only by eye, and both regressions so far were the kind you have to notice:
-- markdown that ate the space around bold, and a wrapper that cut a word in the
-- middle of a codepoint and handed the renderer bytes it could not decode.
local W = 8   -- every glyph is this wide, so pixels are columns times eight

local font = {}
font.__index = font
function font:get_width(s)
  -- The stub measures the way the real font does for the ASCII this exercises:
  -- one advance per byte. The panel must not depend on that -- it has to count
  -- characters itself -- which is exactly what the wrapping tests check.
  return #s * W
end
function font:get_height() return 10 end

local function new_font() return setmetatable({}, font) end

-- rawset, because boggart runs its Lua under strict.lua: assigning a new global
-- the ordinary way is an error, and these are exactly the globals the studio
-- expects its C host to have installed before any of its modules load.
rawset(_G, "SCALE", 1)
rawset(_G, "DATADIR", root .. "/studio/data")
rawset(_G, "renderer", {
  font = { load = function() return new_font() end },
  draw_rect = function() end,
  draw_text = function(_, text, x) return x + #text * W end,
  set_clip_rect = function() end,
})
if rawget(_G, "system") == nil then
  rawset(_G, "system", { fuzzy_match = function() return 0 end })
end
-- A Doc times its own undo merges and resolves its own filename, and the
-- highlighter wants somewhere to put a coroutine. None of the three do anything
-- interesting to the arithmetic under test; they only have to exist.
-- The clock has to actually advance: Doc merges undo entries that happened
-- within a fraction of a second of each other, so a clock stuck at zero merges
-- the entire history into one command and "undo" empties the buffer.
local clock = 0
rawget(_G, "system").get_time = rawget(_G, "system").get_time
  or function() clock = clock + 1; return clock end
rawget(_G, "system").absolute_path = rawget(_G, "system").absolute_path
  or function(p) return p end

package.path = root .. "/studio/data/?.lua;" .. root .. "/studio/data/?/init.lua;"
  .. package.path

-- core/init.lua wants a window and a project scan; the panel wants four fields
-- off it. A stub is the whole difference between this suite running anywhere
-- and not running at all.
package.loaded["core"] = {
  redraw = false,
  docs = {},
  threads = {},
  active_view = nil,
  clip_rect_stack = { { 0, 0, 0, 0 } },
  push_clip_rect = function() end,
  pop_clip_rect = function() end,
  set_active_view = function() end,
  add_thread = function() end,
  log = function() end,
  error = function() end,
}

local loaded, AgentView = pcall(require, "core.agentview")
ok(loaded, "agentview loads against a stub window"
  .. (loaded and "" or ("  -- " .. tostring(AgentView))))

if loaded then
  -- The constructor reads bog.version and the stored credentials for its
  -- banner, both of which this suite already has: it runs inside boggart.
  local okv, v = pcall(function()
    local x = AgentView()
    x.entries = {}
    return x
  end)
  ok(okv, "AgentView() constructs" .. (okv and "" or ("  -- " .. tostring(v))))
  if not okv then
    io.write(string.format("\n%d passed, %d failed\n", passed, failed))
    return 1
  end

  local function rows_of(text, cols, role)
    return v:layout({ role = role or "assistant", text = text }, cols)
  end
  local function text_of(row)
    local parts = {}
    for _, t in ipairs(row) do parts[#parts + 1] = t[2] end
    return table.concat(parts)
  end
  local function chars(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
  end

  -- ---- wrapping ----------------------------------------------------------
  local long = string.rep("abcdefghij", 30)   -- 300 characters, no spaces
  local rows = rows_of(long, 40)
  local widest, joined = 0, {}
  for _, r in ipairs(rows) do
    widest = math.max(widest, chars(text_of(r)))
    joined[#joined + 1] = text_of(r)
  end
  ok(widest <= 40, "an unbroken 300-character run wraps to the column (widest "
    .. widest .. ")")
  ok(table.concat(joined) == long, "...and no characters are lost doing it")

  -- The one that mattered: a word too long for the column used to be cut with
  -- string.sub at a byte offset, which lands inside a codepoint. Every row has
  -- to be something the renderer can decode.
  local accented = "x" .. string.rep("é", 100)
  local all_valid, total = true, 0
  for _, r in ipairs(rows_of(accented, 40)) do
    local s = text_of(r)
    if utf8.len(s) == nil then all_valid = false end
    total = total + chars(s)
    if chars(s) > 40 then all_valid = false end
  end
  ok(all_valid, "wrapping a long accented word yields valid UTF-8 rows")
  ok(total == 101, "...containing all 101 characters (got " .. total .. ")")

  -- Widths are characters, not bytes: "café" is four columns.
  local one = rows_of("café", 40)
  ok(#one == 1, "a four-character accented word does not wrap at 40 columns")

  -- ---- display width -----------------------------------------------------
  -- The panel measures in grid cells, which is a third thing after bytes and
  -- characters: a CJK ideograph is one character, three bytes and two cells.
  -- These are the tables in src/utf8width.h, reached through sys.width, and
  -- they are checked here because the arithmetic is pure and a rendered frame
  -- proves an off-by-one only to someone who already suspects it.
  local widths = {
    { "abc",                3, "ascii"            },
    { "café",               4, "precomposed é"    },
    { "e\u{0301}",          1, "e + combining acute is one cell" },
    { "日本語",             6, "CJK is two cells each" },
    { "한국어",             6, "Hangul syllables"  },
    { "Привет",             6, "Cyrillic is one cell each" },
    { "Ελληνικά",           8, "Greek"             },
    { "שלום",               4, "Hebrew"            },
    { "العربية",            7, "Arabic"            },
    { "Ａ",                 2, "fullwidth Latin"   },
    { "→─",                 2, "arrows and box drawing are one cell" },
    { "\u{1F600}",          2, "emoji is two cells" },
    { "\u{1F469}\u{200D}\u{1F4BB}", 4, "a ZWJ sequence measures as its parts" },
    { "",                   0, "the empty string"  },
  }
  for _, c in ipairs(widths) do
    ok(sys.width(c[1]) == c[2], string.format(
      "width: %s is %d cells (got %d)", c[3], c[2], sys.width(c[1])))
  end

  -- The cut is on a character boundary, and a two-cell character straddling
  -- the limit is left out whole rather than halved -- which is why the columns
  -- taken are a separate return from the prefix.
  local jp = "日本語abc"
  local p3, u3 = sys.wtake(jp, 3)
  ok(p3 == "日" and u3 == 2,
    "wtake leaves out a wide character that does not fit (got '" .. p3
    .. "' using " .. u3 .. ")")
  local p6, u6 = sys.wtake(jp, 6)
  ok(p6 == "日本語" and u6 == 6, "...and takes it when it does")
  ok(sys.wtake(jp, 0) == "" and sys.wtake(jp, 99) == jp,
    "wtake handles both ends")
  for n = 0, 12 do
    -- Parenthesised: wtake returns two values, and utf8.len's second argument
    -- is a starting index, so an unwrapped call passes the column count as a
    -- position and fails on the zero.
    ok(utf8.len((sys.wtake(jp, n))) ~= nil,
      "wtake(" .. n .. ") is valid UTF-8")
  end

  -- ---- wrapping by width, not by character -------------------------------
  -- The bug this replaces: a paragraph of Japanese wrapped at 40 *characters*
  -- drew 80 cells wide and ran off the right of the panel, with nothing to
  -- scroll to it and no clue that anything had been lost.
  local jp_para = string.rep("日本語のテキストです。", 12)
  local jrows = rows_of(jp_para, 40)
  local jwidest, jjoined = 0, {}
  for _, r in ipairs(jrows) do
    local s = text_of(r)
    jwidest = math.max(jwidest, sys.width(s))
    jjoined[#jjoined + 1] = s
    if utf8.len(s) == nil then jwidest = 9999 end
  end
  ok(jwidest <= 40,
    "a Japanese paragraph wraps to the column in cells (widest " .. jwidest .. ")")
  ok(table.concat(jjoined) == jp_para, "...and loses nothing doing it")

  -- Mixed scripts on one row have to add up the same way.
  local mixed = "the file 設定.lua has ошибки"
  ok(sys.width(mixed) == #("the file ") + 4 + #(".lua has ") + 6,
    "a mixed line measures as the sum of its parts")

  -- A column too narrow for the character in it. This used to be an infinite
  -- loop rather than a cosmetic problem: the wrapper asked for one cell, got
  -- an empty string back because the next glyph needed two, and never made
  -- progress. It has to terminate and it has to emit the character.
  local narrow = rows_of("日本語日本語", 1)
  ok(#narrow >= 6, "a two-cell glyph in a one-cell column still gets emitted ("
    .. #narrow .. " rows)")
  local nall = {}
  for _, r in ipairs(narrow) do nall[#nall + 1] = text_of(r) end
  ok(table.concat(nall) == "日本語日本語",
    "...with every character present exactly once")
  ok(#rows_of("a日b", 2) >= 2, "a one-cell and a two-cell glyph share a column")

  -- ---- inline markdown ---------------------------------------------------
  -- The space around a span. This is the regression that shipped.
  local md = text_of(rows_of("add a **bounded** retry now", 60)[1])
  ok(md == "add a bounded retry now",
    "bold keeps the spaces around it (got '" .. md .. "')")
  local md2 = text_of(rows_of("see `M.RETRY` and *this* too", 60)[1])
  ok(md2 == "see M.RETRY and this too",
    "code and italic keep their spacing (got '" .. md2 .. "')")
  local md3 = text_of(rows_of("read [the spec](http://x) first", 60)[1])
  ok(md3 == "read the spec first", "a link renders its text (got '" .. md3 .. "')")

  -- ---- fences ------------------------------------------------------------
  local function code_rows(text, cols)
    local n = 0
    for _, r in ipairs(rows_of(text, cols)) do if r.code then n = n + 1 end end
    return n
  end
  ok(code_rows("a\n```lua\nlocal x = 1\n```\nb", 60) == 1,
    "a fenced line is a code row and the fences are not")
  ok(code_rows("a\n```lua\nlocal x = 1\nlocal y = 2", 60) == 2,
    "an unterminated fence still renders its contents as code")
  -- A ```` block contains ``` blocks; the inner fences are content.
  ok(code_rows("````md\n```lua\nx\n```\n````", 60) == 3,
    "a longer fence is not closed by a shorter one")

  -- ---- the layout cache --------------------------------------------------
  local e = { role = "assistant", text = "AAAA BBBB" }
  v:layout(e, 40)
  e.text = "CCCC DDDD"
  ok(text_of(v:layout(e, 40)[1]) == "CCCC DDDD",
    "the layout cache notices a rewrite of the same length")
  local warm = v:layout(e, 40)
  ok(v:layout(e, 40) == warm, "...and still returns the cached rows otherwise")

  -- ---- the composer ------------------------------------------------------
  v:set_input("hello world again")
  v:on_key_pressed("ctrl+backspace")
  ok(v:input_text() == "hello world",
    "ctrl+backspace deletes a word (got '" .. v:input_text() .. "')")
  v:set_input("alpha beta gamma")
  v.cx = 12                       -- between "beta " and "gamma"
  v:on_key_pressed("ctrl+backspace")
  ok(v:input_text() == "alphagamma" and v.cx == 6,
    "...from the middle of a line, keeping the tail (got '"
    .. v:input_text() .. "' cx " .. v.cx .. ")")

  v:set_input("")
  v:on_text_input("héllo")
  v:on_key_pressed("left"); v:on_key_pressed("left")
  v:on_key_pressed("left"); v:on_key_pressed("left")
  ok(v.cx == 2, "the caret steps whole characters, not bytes (cx " .. v.cx .. ")")
  v:on_key_pressed("backspace")
  ok(utf8.len(v:input_text()) ~= nil and v:input_text() == "éllo",
    "backspace deletes a whole character (got '" .. v:input_text() .. "')")

  v:set_input("one\ntwo\nthree")
  v.cy, v.cx = 3, 4
  v:on_key_pressed("up")
  ok(v.cy == 2, "up moves the caret in a multi-line draft (cy " .. v.cy .. ")")
  v:on_key_pressed("up")
  ok(v.cy == 1 and v.cx <= 4, "...and clamps to a shorter line")
  v:on_key_pressed("down")
  ok(v.cy == 2, "down moves it back")

  v:set_input("")
  v.history, v.hpos = { "first", "second" }, 0
  v:on_key_pressed("up")
  ok(v:input_text() == "second", "up recalls history from a single-line input")
  v:on_key_pressed("up")
  ok(v:input_text() == "first", "...and walks backwards through it")
  v:on_key_pressed("down"); v:on_key_pressed("down")
  ok(v:input_text() == "", "down walks back out to an empty input")

  -- ---- the transcript ----------------------------------------------------
  v.entries = {}
  v:push("user", "hi")
  v:stream("par"); v:stream("tial")
  ok(#v.entries == 2 and v.entries[2].text == "partial",
    "streamed chunks join into one entry")
  v:close_stream()
  v:stream("next")
  ok(#v.entries == 3, "a closed stream does not absorb the next reply")

  -- ---- the fallback turn (no scheduler) ----------------------------------
  -- Swarm mode is the studio's default now -- the chat turn normally runs as a
  -- scheduler actor so it can spawn sub-agents -- but the studio must still be
  -- a chat window when the actor layer cannot start (no store, a require
  -- failed) or, as here, when there is no core.studio wired at all. In that
  -- case submit() runs the turn as a bare coroutine that tick() drives, exactly
  -- as it did before the swarm was unified, and a plain turn must still stream
  -- and settle. The model is stubbed: this checks the panel's own machinery,
  -- not the network, and it is the one path a headless suite can drive end to
  -- end (the scheduler path needs a window and a live model, so it is covered
  -- by the driven studio probe and ninja ui-check instead).
  v.entries, v.busy, v.co, v.turn_id = {}, false, nil, nil
  local saved_run_on = bog.api.run_on
  bog.api.run_on = function(_, _, on_text)
    on_text("hello ")
    on_text("there")
    return true
  end
  v:submit("say hi")
  ok(v.busy, "fallback: submit marks the turn busy")
  ok(v.turn_id == nil, "fallback: no scheduler wired, so no coordinator actor id")
  ok(v.co ~= nil, "fallback: the turn runs as a bare coroutine tick() drives")
  for _ = 1, 50 do
    if not v.busy then break end
    v:tick()
  end
  bog.api.run_on = saved_run_on
  ok(not v.busy, "fallback: the turn completed with no scheduler pumping it")
  local said = ""
  for _, e in ipairs(v.entries) do
    if e.role == "assistant" then said = said .. e.text end
  end
  ok(said == "hello there",
    "fallback: streamed text landed in the transcript (got '" .. said .. "')")

  -- ---- completion, slash commands, shared permission modes ----------------
  -- The cTUI's Tab/`@`/`/` work through bog.complete and bog.handle_command.
  -- The studio composer has to use the same engines so a skill or a file
  -- mention means the same thing in both windows.
  local okp, perm = pcall(require, "perm")
  ok(okp, "perm loads" .. (okp and "" or ("  -- " .. tostring(perm))))
  if okp then
    ok(v:policy_for("read") == "allow", "smart mode allows read")
    ok(v:policy_for("write") == "ask", "smart mode asks before write")
    ok(v:policy_for("bash") == "ask", "smart mode asks before bash")
    v:set_mode("chat")
    ok(v:policy_for("write") == "deny", "chat mode denies write")
    v:set_mode("manual")
    ok(v:policy_for("read") == "ask", "manual mode asks before read")
    v:set_mode("auto")
    ok(v:policy_for("write") == "allow", "auto mode allows write")
    v:set_mode("smart")
    v:on_key_pressed("shift+tab")
    ok(v.mode == "manual", "shift+tab cycles smart -> manual (got " .. tostring(v.mode) .. ")")
    v:set_mode("smart")
  end

  v:set_input("@lua/comp")
  v:on_key_pressed("tab")
  ok(v:input_text() == "@lua/complete.lua",
    "Tab completes @lua/comp to @lua/complete.lua (got '" .. v:input_text() .. "')")

  v:set_input("@complete")
  v:on_key_pressed("tab")
  ok(v._complete_menu and #v._complete_menu.items >= 2,
    "Tab on @complete opens a menu (lua/ and tests/ both match)")
  v:on_key_pressed("escape")
  ok(v._complete_menu == nil, "escape dismisses the completion menu")

  v:set_input("")
  v:on_text_input("@")
  ok(v._complete_menu and #v._complete_menu.items > 0,
    "typing @ opens the file menu")

  v.entries, v.busy = {}, false
  v:set_input("/help")
  v:send()
  local help_out = ""
  for _, e in ipairs(v.entries) do
    if e.role == "system" then help_out = help_out .. (e.text or "") end
  end
  ok(help_out:find("/model", 1, true),
    "/help in the composer prints the command list (got '"
    .. help_out:sub(1, 80) .. "')")
  ok(not v.busy, "/help does not start a model turn")

  local saved_run = bog.api.run_on
  local ran
  bog.api.run_on = function(_, text, on_text)
    ran = text
    on_text("ok")
    return true
  end
  v.entries, v.busy, v.co, v.turn_id = {}, false, nil, nil
  v:set_input("/tdd")
  v:send()
  for _ = 1, 50 do if not v.busy then break end v:tick() end
  bog.api.run_on = saved_run
  ok(type(ran) == "string" and ran:find("tdd", 1, true),
    "/tdd hands the skill instructions to the agent")

  -- The shell has no SidebarView; the chevron that toggled it must not appear
  -- as a dead button on the shared AgentView toolbar.
  local has_side = false
  local has_new = false
  for _, it in ipairs(v:toolbar_items()) do
    if it.command == "studio:toggle-sidebar" then has_side = true end
    if it.command == "agent:new-session" then has_new = true end
  end
  ok(not has_side, "toolbar has no legacy sidebar chevron without a sidebar")
  ok(has_new, "toolbar still has New chat")

  v.entries, v.busy, v.co, v.turn_id = {}, false, nil, nil
  v:send_prompt("/help")
  local help2 = ""
  for _, e in ipairs(v.entries) do
    if e.role == "system" then help2 = help2 .. (e.text or "") end
  end
  ok(help2:find("/model", 1, true), "send_prompt('/help') runs the slash command")
end

-- ---------------------------------------------------------------------------
-- Decorations, and whether they stay where they were put
-- ---------------------------------------------------------------------------
--
-- A mark that drifts off the line it describes is worse than no mark: it points
-- confidently at the wrong code. The bookkeeping that stops that happening is
-- pure integer arithmetic over a line table, so it is checked here rather than
-- by squinting at a rendered frame, where an off-by-one looks like a design
-- decision.
local okm, marks = pcall(require, "core.marks")
ok(okm, "marks loads" .. (okm and "" or ("  -- " .. tostring(marks))))

local okdoc, Doc = pcall(require, "core.doc")
ok(okdoc, "doc loads with the mark hooks in it"
  .. (okdoc and "" or ("  -- " .. tostring(Doc))))

if okm and okdoc then
  -- Most of the paths below are only keys into the marks store, but the reload
  -- case at the end genuinely opens its file, and there is no /tmp on Windows:
  -- io.open would return nil, the `if fp then` would skip the block, and the
  -- suite would go green having tested nothing. sys.tmpdir() is the platform's
  -- own answer (uv_os_tmpdir), which is the same reason nothing here asks what
  -- OS it is on.
  local TMP = sys.tmpdir()

  -- ---- the store ---------------------------------------------------------
  local T = TMP .. "/marks-store.lua"
  marks.clear(T)
  local id = marks.set(T, 10, { kind = "added", text = "agent +1 -0" })
  ok(marks.get(T, 10) and marks.get(T, 10)[1].id == id,
    "a mark is found on the line it was set on")
  ok(marks.get(T, 9) == nil, "...and nowhere else")
  marks.set(T, 3, { kind = "error" })
  marks.set(T, 7, { kind = "info" })
  ok(marks.count(T) == 3, "three marks on one target (got " .. marks.count(T) .. ")")
  local all = marks.all(T)
  ok(all[1].line == 3 and all[2].line == 7 and all[3].line == 10,
    "all() comes back in line order")
  ok(marks.all(T) == all, "...and is cached until something changes")
  ok(select(1, marks.next(T, 3)) == 7, "next walks forward from a line")
  ok(select(1, marks.next(T, 10)) == 3, "...and wraps to the top")
  ok(select(1, marks.prev(T, 7)) == 3, "prev walks back")
  ok(select(1, marks.prev(T, 3)) == 10, "...and wraps to the bottom")
  ok(marks.clear(T, "error") == 1 and marks.count(T) == 2, "clear by kind")
  ok(marks.clear(T, id) == 1 and marks.count(T) == 1, "clear by id")
  ok(marks.clear(T) == 1 and marks.count(T) == 0, "clear everything")

  -- ---- tracking edits ----------------------------------------------------
  local n = 0
  local function docof(text)
    n = n + 1
    local d = Doc()
    d.filename = TMP .. "/marks-track-" .. n .. ".lua"
    d:insert(1, 1, text)
    return d
  end

  local d = docof("one\ntwo\nthree\nfour\nfive\n")
  marks.set(d, 4, { kind = "changed" })          -- on "four"
  d:insert(1, 1, "a\nb\nc\n")                    -- three lines above it
  ok(marks.all(d)[1].line == 7,
    "three lines inserted above move the mark down by three (line "
    .. marks.all(d)[1].line .. ")")
  ok(d.lines[7] == "four\n", "...which is still the line it was describing")

  d:insert(7, 2, "XX")                           -- inside the marked line
  ok(marks.all(d)[1].line == 7, "an edit within a line moves nothing")

  d:insert(7, 1, "z\n")                          -- at the head of the marked line
  ok(marks.all(d)[1].line == 8,
    "text inserted at column one carries the line's mark down with the line")

  d:remove(1, 1, 4, 1)                           -- three whole lines above
  ok(marks.all(d)[1].line == 5,
    "removing three lines above moves the mark up by three (line "
    .. marks.all(d)[1].line .. ")")

  local d2 = docof("one\ntwo\nthree\nfour\nfive\n")
  marks.set(d2, 2, { kind = "added" })
  marks.set(d2, 3, { kind = "added" })
  marks.set(d2, 5, { kind = "added" })
  d2:remove(2, 1, 4, 1)                          -- deletes lines 2 and 3
  local lines2 = {}
  for _, m in ipairs(marks.all(d2)) do lines2[#lines2 + 1] = m.line end
  ok(#lines2 == 3 and lines2[1] == 2 and lines2[2] == 2 and lines2[3] == 3,
    "marks inside a deleted span collapse onto the surviving line, and the "
    .. "one below shifts up (got " .. table.concat(lines2, ",") .. ")")

  -- Undo runs back through raw_insert, so it has to put the marks back too.
  local d3 = docof("one\ntwo\nthree\nfour\n")
  marks.set(d3, 3, { kind = "changed" })
  d3:insert(1, 1, "x\ny\n")
  ok(marks.all(d3)[1].line == 5, "an insert moves the mark")
  d3:undo()
  ok(marks.all(d3)[1].line == 3, "...and undoing it puts the mark back")

  -- ---- from a diff -------------------------------------------------------
  local F = TMP .. "/marks-diff.lua"
  local old, new = "a\nb\nc\nd\n", "a\nB1\nB2\nc\nd\n"
  marks.clear(F)
  local ids = marks.from_edit(F, old, new, { path = F })
  ok(#ids == 2, "a one-for-two replacement marks two lines (got " .. #ids .. ")")
  local head = marks.get(F, 2)[1]
  ok(head.line == 2 and head.kind == "changed", "the hunk starts where it starts")
  ok(head.text == "agent +2 -1",
    "the head line carries the summary (got '" .. tostring(head.text) .. "')")
  ok(marks.get(F, 3)[1].text == nil,
    "...and the rest of the hunk does not repeat it")
  ok(marks.from_edit(F, new, new) ~= nil and #marks.from_edit(F, new, new) == 0,
    "an unchanged write marks nothing")

  -- A pure deletion has no line of its own to sit on, so it marks the line
  -- that closed over the gap.
  local G = TMP .. "/marks-del.lua"
  marks.clear(G)
  marks.from_edit(G, "a\nb\nc\n", "a\nc\n")
  ok(marks.count(G) == 1 and marks.get(G, 2) and marks.get(G, 2)[1].kind == "removed",
    "a deletion marks the line that closed the gap")

  -- A second agent write has to move the first one's marks: nothing else can,
  -- because that edit never passes through the buffer.
  local H = TMP .. "/marks-two.lua"
  marks.clear(H)
  marks.from_edit(H, "1\n2\n3\n4\n5\n6\n", "1\n2\n3\n4\nFIVE\n6\n")   -- line 5
  marks.from_edit(H, "1\n2\n3\n4\nFIVE\n6\n", "1\nx\ny\n2\n3\n4\nFIVE\n6\n")
  local ls = {}
  for _, m in ipairs(marks.all(H)) do ls[#ls + 1] = m.line end
  ok(ls[#ls] == 7, "an earlier hunk moves when a later write inserts above it "
    .. "(marks at " .. table.concat(ls, ",") .. ")")

  -- ---- reverting one hunk ------------------------------------------------
  local d4 = docof(new)
  marks.clear(d4)
  marks.from_edit(d4, old, new, { path = d4.filename })
  local m4 = marks.get(d4, 2)[1]
  local reverted = marks.revert(d4, m4)
  ok(reverted, "a hunk reverts")
  ok(d4.lines[2] == "b\n" and d4.lines[3] == "c\n",
    "...restoring exactly what was replaced (got '"
    .. tostring(d4.lines[2]):gsub("\n", "\\n") .. "')")
  ok(marks.count(d4) == 0, "...and takes its marks with it")

  -- Refusing is the important half: the recorded text is what the agent wrote,
  -- and if the buffer no longer says that, putting it back destroys somebody
  -- else's edit rather than the agent's.
  local d5 = docof(new)
  marks.clear(d5)
  marks.from_edit(d5, old, new)
  d5:insert(2, 1, "mine ")
  local okr, why = marks.revert(d5, marks.get(d5, 2)[1])
  ok(not okr and type(why) == "string",
    "revert refuses when the buffer has moved on (" .. tostring(why) .. ")")
  ok(d5.lines[2] == "mine B1\n", "...and changes nothing when it refuses")

  -- ---- a reload is not an edit -------------------------------------------
  -- Doc:reload replaces the line table outright. If it ever goes back to
  -- remove-everything-then-insert-everything, every mark in the file lands on
  -- line 1 and this catches it.
  local path = TMP .. "/marks-reload.lua"
  local fp = io.open(path, "wb")
  if fp then
    fp:write("one\ntwo\nthree\nfour\n")
    fp:close()
    local d6 = Doc(path)
    marks.clear(d6)
    marks.set(d6, 3, { kind = "changed" })
    local fp2 = io.open(path, "wb")
    fp2:write("one\ntwo\nTHREE\nfour\n")
    fp2:close()
    ok(d6:reload(), "a doc reloads from disk")
    ok(d6.lines[3] == "THREE\n", "...picking up what changed")
    ok(marks.count(d6) == 1 and marks.all(d6)[1].line == 3,
      "...without disturbing the marks on it")
  end

  -- ---- colours -----------------------------------------------------------
  -- The wash is memoised; two frames asking for the same kind must not hand
  -- back two tables, or the frame loop is allocating for nothing.
  ok(marks.wash({ kind = "added" }) == marks.wash("added"),
    "the line wash for a kind is one shared table")
  ok(marks.wash({ kind = "added", hl = { 1, 2, 3, 4 } })[1] == 1,
    "...and an explicit hl wins over it")
end

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
return failed == 0 and 0 or 1
