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
end

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
return failed == 0 and 0 or 1
