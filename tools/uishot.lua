-- uishot.lua -- render the studio with representative content and photograph it.
--
-- Run with `ninja ui-check`. This exists because the panel-attachment bug of
-- 2026-08-11 was invisible to every headless test: AgentView constructed
-- correctly, laid out correctly, and answered every probe correctly, while
-- never appearing on screen at all -- once because the editor core does not set
-- view.node (so the "is the panel open?" check was nil every time) and once
-- because a `locked` split pins a node to its view's size, which for a fresh
-- View is zero. Neither is detectable without a rendered frame.
--
-- It has since grown a second job. A frame is also the only place to check the
-- things that only exist once a layout has run against a real window: that two
-- buttons are not sitting on the same pixels, that the rail has not eaten half
-- a narrow window, that a toolbar button is wired to a command that exists.
-- Those are cheap assertions here and impossible in tests/studio.lua, which has
-- no window at all.
--
-- Each scenario also writes a BMP, because the last resort for a UI is still a
-- person looking at it. BMP because SDL2 writes one with no extra dependency.
local core = require "core"
local command = require "core.command"
local studio = require "core.studio"
local difflib = require "core.diff"
local widgets = require "core.widgets"

local OUT = os.getenv("BOGGART_STUDIO_SHOT") or "/tmp/boggart-studio.bmp"

local problems = {}
local function check(ok, msg) if not ok then problems[#problems + 1] = msg end end

-- Scenario shots go beside the main one, named after the scenario.
local function shot_path(name)
  if not name then return OUT end
  return (OUT:gsub("%.bmp$", "")) .. "-" .. name .. ".bmp"
end

core.add_thread(function()
  local v = studio.open_agent()

  local function frame(n)
    core.redraw = true
    for _ = 1, (n or 4) do coroutine.yield(0.08) end
  end

  local function shot(name)
    frame(4)
    local ok, err = system.save_screenshot(shot_path(name))
    check(ok, "save_screenshot(" .. tostring(name) .. ") failed: " .. tostring(err))
  end

  -- Every rect the panel registered this frame, checked against each other and
  -- against the panel. Two buttons on the same pixels is not a cosmetic
  -- complaint: widgets.hit answers with whichever was registered first, so the
  -- one underneath is unclickable and looks merely mis-drawn.
  -- `view` defaults to the conversation, which is what every caller below
  -- meant before there was a second view with buttons in it.
  local function check_hits(where, view)
    view = view or v
    local hits = view.hits or {}
    check(#hits > 0, where .. ": the panel registered no clickable rects at all")
    for i = 1, #hits do
      for j = i + 1, #hits do
        local a, b = hits[i], hits[j]
        if a.x < b.x + b.w and b.x < a.x + a.w
           and a.y < b.y + b.h and b.y < a.y + a.h then
          check(false, string.format("%s: '%s' and '%s' overlap", where,
            tostring(a.item and a.item.label), tostring(b.item and b.item.label)))
        end
      end
    end
    for _, r in ipairs(hits) do
      check(r.y >= view.position.y and r.y + r.h <= view.position.y + view.size.y + 1,
        string.format("%s: '%s' is outside the panel vertically (y %.0f h %.0f)",
          where, tostring(r.item and r.item.label), r.y, r.h))
      local cmd = r.item and r.item.command
      -- A button naming a command nobody registered is a button that does
      -- nothing, and clicking it is the only way to find out.
      check(not cmd or command.map[cmd] ~= nil,
        string.format("%s: '%s' is wired to the unknown command '%s'", where,
          tostring(r.item and r.item.label), tostring(cmd)))
    end
  end

  local function seed_representative()
    v.entries = {}
    v.pending = nil
    v:push("user", "add a retry helper to lua/api.lua and show me the diff")
    v:push("assistant", table.concat({
      "## Retry with backoff",
      "",
      "I'll add a **bounded** retry with *jittered* backoff to `lua/api.lua`.",
      "The policy lives in `M.RETRY`, see [the spec](https://example.com/retry).",
      "",
      "- Retries only `429` and `5xx`",
      "- Gives up after **four** attempts",
      "- Jitter stops a fleet resynchronising",
      "",
      "---",
      "",
      "```lua",
      "-- Retry on 429/5xx only. Jitter keeps a fleet of agents from",
      "-- resynchronising on the same second after a rate limit.",
      "local function backoff_ms(attempt)",
      "  local base = M.RETRY.base_ms * (2 ^ (attempt - 1))",
      "  return math.min(base, M.RETRY.max_ms) * (0.5 + math.random())",
      "end",
      "```",
      "",
      "> Anything longer than eight seconds is worse than failing.",
      "",
      "Applying it now.",
    }, "\n"))
    v:push("tool", "read lua/api.lua", "read")

    local old = "local M = {}\n\nfunction M.endpoint()\n  return auth.base_url()\nend\n"
    local new = "local M = {}\n\nM.RETRY = { attempts = 4, base_ms = 500, max_ms = 8000 }\n\n"
      .. "function M.endpoint()\n  return auth.base_url()\nend\n"
    v:push("diff", "", { diff = difflib.compute(old, new), path = "lua/api.lua" })

    v:push("error", "endpoint unreachable: connection refused (retrying in 1.2s)")
    v:push("assistant", "Retried and succeeded. The helper is in place.")

    v:set_input("now run @lua/api.lua through the tests")
    v.pending = { name = "write", summary = "lua/api.lua  +2 -0  at line 3" }
    bog.session.usage = { input = 18420, output = 2130, cached = 41200, turns = 7,
                          last_input = 59620 }
  end

  local ok, err = pcall(function()
    coroutine.yield(0.3)

    -- ---- the representative frame -----------------------------------------
    seed_representative()

    -- Assertions a rendered frame can make and a headless probe cannot: the
    -- panel is in the node tree, it has a non-zero size, and asking for it
    -- twice does not build a second one.
    check(studio.agent_view() == v, "agent_view() does not find the open panel")
    check(studio.open_agent() == v, "open_agent() built a second panel")
    check(core.root_view.root_node:get_node_for_view(v) ~= nil,
      "panel is not attached to the node tree")
    check(studio.sidebar ~= nil, "no sidebar")
    check(core.root_view:get_primary_node():get_node_for_view(v) ~= nil,
      "the conversation is not in the primary node")

    shot(nil)

    check(v.size.x > 100, "panel width is " .. tostring(v.size.x) .. " (collapsed)")
    check(v.size.y > 100, "panel height is " .. tostring(v.size.y) .. " (collapsed)")
    check(studio.sidebar.size.x > 50,
      "sidebar width is " .. tostring(studio.sidebar.size.x) .. " (collapsed)")
    check_hits("representative")

    -- Focusing the conversation must also bring its tab forward. Taking only
    -- the keyboard leaves you typing into a panel the window is not showing.
    core.set_active_view(studio.open_agent())
    check(core.root_view:get_primary_node().active_view == studio.agent_view(),
      "open_agent() focused the panel without bringing its tab forward")

    -- Every button the panel offers, clicked. A command that errors takes the
    -- window down in front of a user; here it is a line of output. The command
    -- view has to be dismissed between clicks, or the second click lands in it.
    local clickable = {}
    for _, r in ipairs(v.hits) do
      clickable[#clickable + 1] = { x = r.x + r.w / 2, y = r.y + r.h / 2,
                                    label = r.item and r.item.label or "?" }
    end
    for _, c in ipairs(clickable) do
      local okc, errc = pcall(function()
        core.on_event("mousepressed", "left", c.x, c.y, 1)
        core.on_event("mousereleased", "left", c.x, c.y)
      end)
      check(okc, "clicking '" .. c.label .. "' raised: " .. tostring(errc))
      if core.active_view == core.command_view then
        pcall(function() core.command_view:exit(false) end)
      end
      frame(1)
      core.set_active_view(v)
    end
    -- The rail's own "Open a file..." button, used the way a person uses it.
    -- The rail lives in a locked node, so opening a document while focus is
    -- still in it used to trip an assert and the file simply never opened.
    -- Focus goes to the rail first, which is both what the bug needs and what
    -- the segmented control leaves behind: SidebarView:update() re-derives the
    -- tab from the active view, so with the conversation focused the Code tab
    -- would flip straight back to Chat and never draw the button.
    studio.sidebar.visible = true
    core.set_active_view(studio.sidebar)
    studio.sidebar.tab = "code"
    frame(3)
    local opened = false
    for _, r in ipairs(studio.sidebar.hits or {}) do
      if r.item and (r.item.id == "open" or r.item.label == "open") then
        core.on_event("mousepressed", "left", r.x + r.w / 2, r.y + r.h / 2, 1)
        core.on_event("mousereleased", "left", r.x + r.w / 2, r.y + r.h / 2)
        opened = true
      end
    end
    check(opened, "the sidebar has no 'Open a file...' button to click")
    if core.active_view == core.command_view then
      core.command_view:set_text("README.md")
      local oks, errs = pcall(function() core.command_view:submit() end)
      check(oks, "opening a file from the sidebar raised: " .. tostring(errs))
    else
      check(false, "the sidebar's open button did not raise the file prompt")
    end
    frame(2)

    -- The sweep clicked the sidebar toggle, among everything else, and the
    -- check above left a document in front of the conversation. Put both back:
    -- the scenarios below check the rail's width, which a hidden rail would
    -- satisfy by being zero, and they measure the panel, which only has a
    -- current size while its node is actually showing it.
    studio.sidebar.visible = true
    studio.sidebar.tab = "chat"
    v = studio.open_agent()
    local node = core.root_view.root_node:get_node_for_view(v)
    if node then node:set_active_view(v) end
    core.set_active_view(v)
    frame(3)

    -- ---- content nobody looks at until it breaks ---------------------------
    v.entries = {}
    v.pending = nil
    v:set_input("")
    v:push("user", "wrap and encoding check")
    v:push("assistant", "NOSPACES:" .. string.rep("abcdef0123456789", 18))
    v:push("assistant", "accents: café naïve résumé Ünicode, then "
      .. string.rep("naïve ", 24))
    -- CJK now draws, from a system font found at runtime; emoji still do not,
    -- because the only font on a stock macOS that has them is a colour one and
    -- stb_truetype cannot rasterise those. Both are here for the same reason
    -- as before: the *layout* around them has to stay sane. Before the wrapper
    -- counted characters a CJK line was sliced mid-codepoint and the rows
    -- either side came out visibly corrupt; before it counted cells the line
    -- was laid out at half the width it drew at and ran off the panel.
    v:push("assistant", "CJK: 日本語のテキストはここにあります。これは長い行です。")
    v:push("assistant", "emoji: 🎉🚀🐛✅ done")
    v:push("assistant", "wide code:\n```lua\nlocal x = " .. string.rep("y", 140)
      .. "\n```")
    v:push("assistant", "unterminated:\n```lua\nlocal a = 1\nno closing fence")
    v:push("assistant", "nested:\n````md\n```lua\nprint('hi')\n```\n````\nafter")
    shot("hostile")
    check_hits("hostile")

    -- Rows must be something the renderer can decode. A row that is not valid
    -- UTF-8 is a row the C decoder walks off the end of.
    for _, e in ipairs(v.entries) do
      if e.role ~= "diff" then
        for i, row in ipairs(v:layout(e, 96)) do
          for _, t in ipairs(row) do
            check(utf8.len(t[2]) ~= nil, string.format(
              "row %d of a %s entry is not valid UTF-8", i, e.role))
          end
        end
      end
    end

    -- ---- the world's scripts ------------------------------------------------
    --
    -- A frame is the only place some of this can be checked at all. Coverage
    -- comes from whatever fonts the machine running this happens to have, so
    -- the assertions below are about arithmetic that must hold everywhere --
    -- rows fitting the column in cells, drawn pixels matching measured cells --
    -- while the BMP is there for the part only a person can judge: whether the
    -- scripts share a baseline, and whether anything is a box that should not
    -- be.
    --
    -- What this cannot check, because the app does not do it: Arabic and
    -- Hebrew are drawn in logical order with unjoined letters, and Devanagari
    -- is drawn without conjuncts or reordering. Correct shaping and bidi need
    -- HarfBuzz and FriBidi. The widths are right; the glyphs are not.
    v.entries = {}
    v.pending = nil
    v:set_input("編集中のテキスト café 日本語")
    v:push("user", "日本語のテキストを表示できますか？")
    v:push("assistant", table.concat({
      "Japanese   日本語のテキスト、ひらがな、カタカナ",
      "Chinese    中文简体字和繁體字測試",
      "Korean     한국어 텍스트 입니다",
      "Cyrillic   Привет, мир!   Greek: Ελληνικά κείμενο",
      "Hebrew     שלום עולם      Arabic: مرحبا بالعالم",
      "Devanagari नमस्ते दुनिया      Thai: สวัสดีชาวโลก",
      "Latin      café naïve Ünïcödé   combining: e\u{0301} a\u{0300}",
      "Symbols    → ← ↑ ↓ ─ │ ┌ ┐ ∀ ∃ ∑ € ™ ½",
      "Emoji      \u{1F600} \u{1F469}\u{200D}\u{1F4BB} \u{1F680}",
      "Mixed      the file 設定.lua has 3 errors — see ссылка",
      "",
      "```lua",
      "local msg = \"日本語\"   -- a comment with 中文",
      "```",
      "",
      "Wrapping: " .. string.rep("日本語のテキストです。", 14),
    }, "\n"))
    shot("unicode")
    check_hits("unicode")

    -- Every row fits the column measured in cells. This is the check that was
    -- failing silently: with the wrapper counting codepoints these rows were
    -- inside 96 characters and up to 192 cells, so the tail of every CJK line
    -- was drawn past the right edge of the panel.
    for _, e in ipairs(v.entries) do
      if e.role ~= "diff" then
        for i, row in ipairs(v:layout(e, 96)) do
          local cells = 0
          for _, t in ipairs(row) do
            check(utf8.len(t[2]) ~= nil, string.format(
              "unicode row %d of a %s entry is not valid UTF-8", i, e.role))
            cells = cells + sys.width(t[2])
          end
          check(cells <= 96, string.format(
            "unicode row %d of a %s entry is %d cells wide, not 96",
            i, e.role, cells))
        end
      end
    end

    -- Measured cells and drawn pixels have to be the same thing, or the caret
    -- lands beside the character it claims to be on. They agree only because
    -- the renderer snaps a monospace font's advances to the grid that
    -- sys.width describes; without that a CJK glyph advances about 1.7 cells
    -- and every line of Japanese drifts left of its own layout.
    local cf = require("core.style").code_font
    local cell = cf:get_width("0")
    for _, s in ipairs { "abc", "café", "日本語", "한국어", "→─", "Привет",
                         "\u{1F600}", "the file 設定.lua" } do
      check(cf:get_width(s) == sys.width(s) * cell, string.format(
        "%q draws %d px but measures %d cells of %d",
        s, cf:get_width(s), sys.width(s), cell))
    end

    -- A capability, reported rather than assumed. An empty chain is a legal
    -- answer -- it means this machine has nothing beyond the bundled fonts --
    -- so this asserts the call works, not that it found anything.
    local fb = renderer.font.fallbacks()
    check(type(fb) == "table", "renderer.font.fallbacks() did not return a table")
    io.write(string.format("  font fallbacks: %d discovered\n", #fb))
    for _, f in ipairs(fb) do
      if f.loaded then io.write("    used: ", f.path, "\n") end
    end

    -- ---- an empty conversation ---------------------------------------------
    v.entries = {}
    v:set_input("")
    shot("empty")
    check(#v.entries == 0, "the empty scenario is not empty")
    check_hits("empty")

    -- ---- the welcome screen ------------------------------------------------
    --
    -- The surface a new install opens on, drawn at a sane width and at the
    -- narrow one, and driven through the real event path.
    --
    -- What this deliberately does not touch: "Test connection", "Start
    -- chatting" and "Not now". All three commit configuration -- an endpoint, a
    -- model, and the marker that says the screen has been seen -- and ui-check
    -- runs against the real home directory of whoever ran it. A UI test that
    -- reconfigures your agent is not a test. The end-to-end path is exercised
    -- instead by a probe under a temporary HOME.
    local WelcomeView = require "core.welcomeview"
    local wv = WelcomeView.open()
    frame(4)
    check(core.root_view:get_primary_node():get_node_for_view(wv) ~= nil,
      "welcome: not a tab in the primary node")
    check(wv.size.x > 100 and wv.size.y > 100,
      "welcome: collapsed to " .. wv.size.x .. "x" .. wv.size.y)
    check_hits("welcome", wv)

    local function wclick(id)
      for _, r in ipairs(wv.hits) do
        if r.item.id == id then
          core.on_event("mousemoved", r.x + r.w / 2, r.y + r.h / 2, 0, 0)
          core.on_event("mousepressed", "left", r.x + r.w / 2, r.y + r.h / 2, 1)
          core.on_event("mousereleased", "left", r.x + r.w / 2, r.y + r.h / 2)
          frame(2)
          return true
        end
      end
      check(false, "welcome: no button called '" .. id .. "'")
      return false
    end

    -- Both routes must offer a key or an endpoint, and a model.
    wclick("Use an Anthropic API key")
    check(#wv:fields() == 2, "welcome: the key route has "
      .. #wv:fields() .. " fields, not 2")
    shot("welcome")
    check_hits("welcome-api", wv)

    -- The field, through the keyboard rather than by calling the method: a
    -- completely dead keyboard passed every direct-call test this app has had.
    -- Compared against whatever this machine already had, never against
    -- "false": the person running ui-check may well have a key.
    local had_key = auth.has_key()
    wclick("field1")
    check(wv.focus == 1, "welcome: clicking the key field did not focus it")
    core.on_event("textinput", "s")
    core.on_event("textinput", "k")
    check(wv.buffer == "sk", "welcome: the key field ignored the keyboard ("
      .. string.format("%q", wv.buffer) .. ")")
    core.on_event("keypressed", "backspace")
    check(wv.buffer == "s", "welcome: backspace did nothing")
    core.on_event("keypressed", "escape")
    check(wv.focus == nil and wv.buffer == "",
      "welcome: escape left the field editing")
    check(auth.has_key() == had_key,
      "welcome: an abandoned edit changed the stored credential -- it must not")

    -- Narrow. The column is centred and elides rather than clipping, so the
    -- test is that nothing is drawn outside the view horizontally.
    system.set_window_size(420, 700)
    frame(8)
    shot("welcome-narrow")
    for _, r in ipairs(wv.hits) do
      check(r.x >= wv.position.x - 1 and r.x + r.w <= wv.position.x + wv.size.x + 1,
        string.format("welcome-narrow: '%s' runs outside the view (x %.0f w %.0f of %.0f)",
          tostring(r.item.id), r.x, r.w, wv.size.x))
    end
    system.set_window_size(1400, 900)
    frame(6)

    -- Put it away and get the conversation back, or every scenario after this
    -- one measures a view that is no longer on screen.
    local wnode = core.root_view.root_node:get_node_for_view(wv)
    if wnode then
      wnode:set_active_view(wv)
      wnode:close_active_view(core.root_view.root_node)
    end
    v = studio.open_agent()
    core.set_active_view(v)
    frame(3)

    -- ---- a long transcript, and scrolling ----------------------------------
    v.entries = {}
    for i = 1, 400 do
      v:push(i % 4 == 0 and "user" or "assistant",
        string.format("entry %d: the quick brown fox jumps over the lazy dog", i))
    end
    frame(4)
    check(v.content_height > v.size.y,
      "400 entries do not fill the panel (content_height "
      .. tostring(v.content_height) .. ")")

    -- Drawing has to cost what is on screen, not what is in the session: the
    -- panel is pumped from the frame loop, so a slow draw is a slow agent, and
    -- a transcript only ever grows. Scrolled to the top, almost none of these
    -- entries are visible and almost none of them should be touched.
    --
    -- Framed properly rather than calling draw() in a loop: rencache buffers
    -- the commands and only end_frame drains them, so an unframed loop just
    -- overflows the buffer and measures the complaining.
    for _ = 1, 1600 do v:push("assistant", "and another line of transcript") end
    v.scroll.to.y, v.scroll.y = 0, 0
    frame(3)
    local t0 = system.get_time()
    for _ = 1, 5 do
      renderer.begin_frame()
      core.root_view:draw()
      renderer.end_frame()
    end
    local ms = (system.get_time() - t0) * 1000 / 5
    check(ms < 25, string.format("a frame with 2000 entries takes %.1f ms", ms))

    -- The wheel goes to whatever the pointer is over, so the pointer has to be
    -- put over the conversation first. Without this the events land in the
    -- sidebar and the check passes or fails for the wrong reason.
    core.on_event("mousemoved", v.position.x + v.size.x / 2,
      v.position.y + v.size.y / 2, 0, 0)
    for _ = 1, 8 do core.on_event("mousewheel", -1000) end
    frame(4)
    local max = v.content_height - v.size.y
    check(math.abs(v.scroll.to.y - max) < 1,
      string.format("scrolling past the end lands at %.0f, not %.0f",
        v.scroll.to.y, max))
    v.scroll.to.y, v.scroll.y = max / 2, max / 2
    shot("long")

    for _ = 1, 8 do core.on_event("mousewheel", 1000) end
    frame(4)
    check(v.scroll.to.y == 0, "scrolling back up does not reach the top ("
      .. tostring(v.scroll.to.y) .. ")")

    -- ---- the approval bar, with a path too long for the column -------------
    v.entries = {}
    v.scroll.to.y, v.scroll.y = 0, 0
    v:push("assistant", "about to write")
    v.pending = { name = "write", summary =
      "/Users/someone/a/deeply/nested/directory/structure/that/keeps/going/"
      .. "and/going/agentview_backup_final_v2.lua  +148 -33  at line 991" }
    shot("approval")
    check_hits("approval")
    v.pending = nil

    -- ---- a very narrow window, and a very wide one -------------------------
    local sizes = { { 420, 700, "narrow" }, { 2400, 900, "wide" }, { 1400, 900, "normal" } }
    for _, s in ipairs(sizes) do
      v.entries = {}
      v:push("user", "how does this look at " .. s[3] .. "?")
      v:push("assistant", "Here is **bold** and `code` and a [link](http://x). "
        .. "A long paragraph so that wrapping has work to do at any width.")
      v:push("assistant", "```lua\nlocal function f(a, b) return a + b end\n```")
      v:set_input("a draft")
      system.set_window_size(s[1], s[2])
      frame(8)
      shot(s[3])
      check_hits(s[3])
      check(v.size.x > 0 and v.size.y > 0,
        s[3] .. ": the panel collapsed to " .. v.size.x .. "x" .. v.size.y)
      -- A rail wider than a third of the window is no longer a rail. Only the
      -- drag used to enforce that, so a window narrowed afterwards kept the
      -- width it had been dragged to and the conversation got what was left.
      check(studio.sidebar.size.x <= core.root_view.size.x / 3 + 2,
        string.format("%s: the sidebar is %d of %d pixels", s[3],
          studio.sidebar.size.x, core.root_view.size.x))
      check(v.position.x + v.size.x <= core.root_view.size.x + 1,
        s[3] .. ": the panel runs off the right of the window")
    end
  end)

  check(ok, "the probe raised: " .. tostring(err))

  if #problems > 0 then
    io.write("FAIL\n")
    for _, p in ipairs(problems) do io.write("  - " .. p .. "\n") end
    io.flush()
    os.exit(1)
  end
  io.write(string.format("ok  conversation %dx%d, sidebar %d  wrote %s (+9 scenarios)\n",
    v.size.x, v.size.y, studio.sidebar.size.x, OUT))
  io.flush()
  os.exit(0)
end)
