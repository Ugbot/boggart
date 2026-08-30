-- uishot.lua -- render the (legacy) studio with representative content and photograph it.
--
-- Run with `ninja ui-check`. Photographs the LEGACY window composition
-- (BOGGART_STUDIO_LEGACY=1) because the assertions below are about SidebarView
-- and the single-primary-node layout. The default studio is the shell.
--
-- This exists because the panel-attachment bug of 2026-08-11 was invisible to
-- every headless test: AgentView constructed correctly, laid out correctly, and
-- answered every probe correctly, while never appearing on screen at all --
-- once because the editor core does not set view.node (so the "is the panel
-- open?" check was nil every time) and once because a `locked` split pins a
-- node to its view's size, which for a fresh View is zero. Neither is
-- detectable without a rendered frame.
--
-- It has since grown a second job. A frame is also the only place to check the
-- things that only exist once a layout has run against a real window: that two
-- buttons are not sitting on the same pixels, that the rail has not eaten half
-- a narrow window, that a toolbar button is wired to a command that exists.
-- Those are cheap assertions here and impossible in tests/studio.lua, which has
-- no window at all.
--
-- Each scenario also writes a BMP, because the last resort for a UI is still a
-- person looking at it. BMP because SDL3 writes one with no extra dependency.
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
    check(studio.legacy or studio.rail ~= nil, "no activity rail")
    check(core.root_view:get_primary_node():get_node_for_view(v) ~= nil,
      "the conversation is not in the primary node")

    shot(nil)

    check(v.size.x > 100, "panel width is " .. tostring(v.size.x) .. " (collapsed)")
    check(v.size.y > 100, "panel height is " .. tostring(v.size.y) .. " (collapsed)")
    check(studio.sidebar.size.x > 50,
      "sidebar width is " .. tostring(studio.sidebar.size.x) .. " (collapsed)")
    if studio.rail then
      check(studio.rail.size.x >= 20 * SCALE and studio.rail.size.x <= 56 * SCALE,
        "rail width is " .. tostring(studio.rail.size.x) .. " (not a rail)")
      check(studio.rail.position.x + studio.rail.size.x
              <= studio.sidebar.position.x + 2,
        "the rail overlaps the session list")
      check_hits("rail", studio.rail)
    end
    check_hits("representative")

    -- ---- scrolling reaches the bottom -------------------------------------
    --
    -- Two bugs lived here, and neither is visible in a screenshot: the
    -- scrollable height omitted the toolbar, so the last inch of transcript
    -- could not be reached; and "am I at the bottom?" was asked of the layout
    -- AFTER the new content had grown it, so any message taller than six lines
    -- stopped the panel following the tail -- which is every code block and
    -- every diff.
    do
      local saved = v.entries
      v.entries = {}
      for i = 1, 80 do v:push("assistant", "scroll probe line " .. i) end
      frame(4)
      v.scroll.y = v.scroll.to.y
      v:draw()
      local max = math.max(0, (v.content_height or 0) - v.size.y)
      check(math.abs(v.scroll.to.y - max) < 2,
        string.format("a fresh transcript does not scroll to the bottom "
          .. "(at %.0f of %.0f)", v.scroll.to.y, max))
      -- The one that matters, and the one a self-consistent maximum cannot
      -- answer: with the view scrolled as far as it goes, is the end of the
      -- transcript actually on screen?
      check(v.content_bottom_y and v.content_bottom_y <= v.body_bottom_y + 1,
        string.format("scrolled fully down, the transcript still ends %.0f px "
          .. "below the visible area", (v.content_bottom_y or 0) - (v.body_bottom_y or 0)))

      local tall = {}
      for i = 1, 30 do tall[i] = "tall line " .. i end
      v:push("assistant", table.concat(tall, "\n"))
      frame(4)
      v.scroll.y = v.scroll.to.y
      v:draw()
      max = math.max(0, (v.content_height or 0) - v.size.y)
      check(math.abs(v.scroll.to.y - max) < 2,
        "a message taller than the slack stops the panel following the tail")

      v.scroll.to.y, v.scroll.y = 0, 0
      v:draw()
      v:push("assistant", "arrived while reading history")
      frame(3)
      check(v.scroll.to.y < 50,
        "a new message yanks the view down while the user is reading history")

      v.entries = saved
      v.scroll.to.y, v.scroll.y = 0, 0
      frame(2)
    end

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
    -- Files: tree in the slot, empty (or last) editor in the center, chat
    -- snapped to a locked right dock. Opening a file fills the center.
    -- switch_workspace exists in the legacy attach too, but it is a no-op
    -- there (set_sidebar returns immediately). The assertions below are
    -- about the default rail layout; legacy still uses the Chat/Code tab.
    if studio.switch_workspace and not studio.legacy then
      studio.switch_workspace("edit")
      frame(4)
      local tree = studio.tree or package.loaded["plugins.treeview"]
      check(type(tree) == "table" and tree.visible,
        "Files: the file tree is not visible")
      check(tree.size.x >= 20, "Files: the tree collapsed to " .. tostring(tree.size.x))
      local root = core.root_view.root_node
      local agent_node = root:get_node_for_view(studio.view)
      check(agent_node ~= nil, "Files: the conversation left the window")
      check(agent_node.locked, "Files: chat is not a locked right dock")
      local prim = core.root_view:get_primary_node()
      check(prim ~= agent_node, "Files: chat is still the center stage")
      check(prim.active_view ~= studio.view,
        "Files: the conversation occupies the editor pane")
      check(root:get_node_for_view(studio.sidebar) == nil,
        "Files: the session list is still docked next to the tree")
      check(root:get_node_for_view(tree) ~= nil,
        "Files: the tree is not in the sidebar slot")
      core.set_active_view(tree)
      frame(2)
    else
      studio.sidebar.visible = true
      core.set_active_view(studio.sidebar)
      studio.sidebar.tab = "code"
      frame(3)
    end
    local oks, errs = pcall(function() command.perform("core:find-file") end)
    check(oks, "opening a file raised: " .. tostring(errs))
    if core.active_view == core.command_view then
      core.command_view:set_text("README.md")
      local okf, errf = pcall(function() core.command_view:submit() end)
      check(okf, "opening README.md raised: " .. tostring(errf))
    else
      check(false, "find-file did not raise the file prompt")
    end
    frame(3)
    if not studio.legacy then
      local root = core.root_view.root_node
      local agent_node = root:get_node_for_view(studio.view)
      check(agent_node ~= nil and agent_node.locked,
        "Files: opening a file removed the right chat dock")
      local prim = core.root_view:get_primary_node()
      check(prim.active_view and prim.active_view.doc,
        "Files: opening README did not fill the center editor")
      check(prim ~= agent_node, "Files: the file landed in the chat dock")
    end

    -- Back to Chat: session list in the slot, conversation still measurable.
    if studio.switch_workspace and not studio.legacy then
      studio.switch_workspace("agent")
    end
    studio.sidebar.visible = true
    v = studio.open_agent()
    local node = core.root_view.root_node:get_node_for_view(v)
    if node then node:set_active_view(v) end
    core.set_active_view(v)
    frame(3)
    local prompts
    for _, r in ipairs(studio.sidebar.hits or {}) do
      if r.item and r.item.label == "Prompts" then prompts = r end
    end
    check(prompts ~= nil, "the session list has no Prompts button")
    check(not prompts or prompts.item.command == "agent:run-recipe",
      "Prompts is not wired to agent:run-recipe")
    if studio.rail then
      local has_set, has_more
      for _, r in ipairs(studio.rail.hits or {}) do
        if r.item and r.item.id == "settings" then has_set = true end
        if r.item and r.item.id == "more" then has_more = true end
      end
      check(has_set, "the rail has no Settings item")
      check(not has_more, "the rail still has a More overflow")
    end
    if not studio.legacy then
      local okm, errm = pcall(function() command.perform("agent:set-mode") end)
      check(okm, "opening permission mode raised: " .. tostring(errm))
      frame(2)
      local overlay = require "core.menu"
      check(overlay.open, "permission mode did not open an anchored menu")
      local mh = overlay.hits[1]
      check(mh ~= nil, "permission menu has no hits")
      if mh and v.mode_hit then
        check(math.abs(mh.x - v.mode_hit.x) < 400,
          "permission menu is not near the composer button")
        check(mh.y + mh.h < (core.command_view.position.y or 1e9) + 8,
          "permission menu is on the command bar")
      end
      overlay.hide()
      frame(1)
    end

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
      "welcome: not on the agent stage")
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

    -- Put the pointer back over the panel first.
    --
    -- The wheel is routed by RootView to whatever node is under
    -- root_view.mouse, and a real pointer resting anywhere over the window
    -- updates that on the frames drawn in between -- so this burst could be
    -- delivered to the sidebar instead, and the check failed depending on
    -- where the mouse physically was. That is a defect in the test, not a
    -- flake to be tolerated.
    core.on_event("mousemoved", v.position.x + v.size.x / 2,
      v.position.y + v.size.y / 2, 0, 0)
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

    -- ---- a long single line in the composer wraps, it does not overflow -----
    -- A logical line longer than the column used to run off the right edge;
    -- now it fills several visual rows. Assert every drawn slice fits the
    -- column, the visible rows are a contiguous run of the logical line, and a
    -- click on a wrapped row round-trips to a caret inside that line.
    do
      system.set_window_size(1400, 900)
      v.entries = {}
      v.pending = nil
      local long = "This is where I'm going to test the full size of this box to "
        .. "see how we do overflow of text, typing well past the visible width so "
        .. "the composer has to wrap it onto several rows instead of clipping it."
      v:set_input(long)
      frame(4)
      local rows = v.composer_rows or {}
      check(#rows >= 2, "composer: a long line drew " .. #rows .. " row(s), not several")
      local reassembled = {}
      for _, r in ipairs(rows) do
        check(sys.width(r.line) <= 96, string.format(
          "composer: a wrapped row is %d cells wide, past the 96-column cap",
          sys.width(r.line)))
        if r.i == 1 then reassembled[#reassembled + 1] = r.line end
      end
      check(long:find(table.concat(reassembled), 1, true) == 1,
        "composer: the wrapped rows are not a contiguous prefix of the line")
      local r2 = rows[2]
      if r2 then
        local cy, cx = v:composer_pos_at(r2.x + r2.h, r2.y + r2.h / 2)
        check(cy == 1 and cx > 1 and cx <= #long + 1, string.format(
          "composer: a click on the 2nd wrapped row mapped to (%s,%s), outside the line",
          tostring(cy), tostring(cx)))
      end
      shot("composer-wrap")
      check_hits("composer-wrap")
      v:set_input("")
    end

    -- ---- Markdown preview: a .md opens rendered, not as raw source ----------
    -- Proportional headings, syntax-highlighted code, wrapped prose, and a
    -- clickable link. Assert the view type, that layout happened, that nothing
    -- overflows the content width, and that a link kept its URL.
    do
      local MarkdownView = require "core.markdownview"
      local FIX = (os.getenv("TMPDIR") or "/tmp") .. "/boggart-uicheck-md.md"
      local f = io.open(FIX, "wb")
      if f then
        f:write("# Heading One\n\nA **bold** word, *emphasis*, `code`, and a "
          .. "[link](https://example.com/x) that stays clickable. A long line so "
          .. "that wrapping has real work to do across the width of the panel here.\n\n"
          .. "## Heading Two\n\n- a bullet\n- another\n\n1. first\n2. second\n\n"
          .. "- [x] a done task\n- [ ] a todo task\n\n"
          .. "| Col A | Col B |\n| --- | --- |\n| 1 | two |\n| 3 | four |\n\n"
          .. "> a quote\n\n```lua\nlocal function f(a, b) return a + b end\n```\n\n---\n\nDone.\n")
        f:close()
        local mv = core.root_view:open_doc(core.open_doc(FIX))
        core.set_active_view(mv)
        frame(6)
        check(mv:is(MarkdownView), "a .md opens as a MarkdownView, not a DocView")
        check(mv._layout ~= nil and mv._layout.height > 0, "markdown: layout produced height")
        check(#mv._layout.rows > 6, "markdown: layout produced rows")
        local pad = require("core.style").padding.x
        for _, row in ipairs(mv._layout.rows) do
          for _, run in ipairs(row.runs or {}) do
            check(run.x + run.w <= mv.size.x - pad + 3,
              "markdown: a run overflows the content width")
          end
        end
        frame(2)
        local hasurl = false
        for _, h in ipairs(mv.hits or {}) do
          if h.url and h.url:find("example.com", 1, true) then hasurl = true end
        end
        check(hasurl, "markdown: a link registered a clickable hit carrying its URL")
        local has_table = false
        for _, row in ipairs(mv._layout.rows) do if row.kind == "table" then has_table = true end end
        check(has_table, "markdown: the GFM table produced table rows")
        -- the image binding: build a 2x2 RGBA image and confirm it constructs.
        local okimg, img = pcall(renderer.image_from_rgba,
          string.rep(string.char(255, 0, 0, 255), 4), 2, 2)
        check(okimg and img, "renderer.image_from_rgba builds an image")
        if okimg and img then
          local iw, ih = img:size()
          check(iw == 2 and ih == 2, "the image reports its size")
        end
        shot("markdown")
        local node = core.root_view.root_node:get_node_for_view(mv)
        if node then node:set_active_view(mv); node:close_active_view(core.root_view.root_node) end
        v = studio.open_agent(); core.set_active_view(v); frame(2)
      end
    end
  end)

  -- -------------------------------------------------------------------------
  -- The surfaces that are not the conversation
  -- -------------------------------------------------------------------------
  --
  -- Separately pcall'd so a failure here still reports everything the block
  -- above found, and so a new scenario cannot silently swallow an old one.
  local ok2, err2 = pcall(function()
    local FIX = (os.getenv("TMPDIR") or "/tmp") .. "/boggart-uicheck"
    sys.mkdir_p(FIX .. "/many")
    for i = 1, 400 do
      local f = io.open(string.format("%s/many/f%03d.txt", FIX, i), "wb")
      if f then f:write("x"); f:close() end
    end
    local long = io.open(FIX .. "/many/" .. string.rep("w", 220) .. ".txt", "wb")
    if long then long:write("x"); long:close() end

    -- ---- the picker --------------------------------------------------------
    local picker = studio.pick("file", function() end)
    core.set_active_view(picker)
    picker:cd(FIX .. "/many")
    frame(4)

    check(#picker.entries > 400,
      "picker: only " .. #picker.entries .. " entries in a 400-file directory")

    -- Drawing costs what is on screen, not what is in the directory.
    check(#picker.row_hits < 200, string.format(
      "picker: %d hit rects for %d entries -- the list is not clipped to the "
      .. "viewport", #picker.row_hits, #picker.entries))

    -- No row wider than its column: there is no eliding in common.draw_text.
    do
      local font = require("core.style").code_font
      for _, r in ipairs(picker.row_hits) do
        local e = r.entry
        check(font:get_width((e.dir and "/ " or "  ") .. (e.shown or e.name))
                <= r.w + font:get_width("0"),
          "picker: the row for a " .. #(e.name) .. "-character name is drawn "
          .. "wider than the column it is in")
      end
    end

    -- The keyboard, through the event path.
    picker.scroll.to.y, picker.scroll.y = 0, 0
    for _ = 1, 60 do core.on_event("keypressed", "down") end
    frame(2)
    picker.scroll.y = picker.scroll.to.y
    picker:draw()
    check(picker.selected == 61,
      "picker: 60 downs moved the selection to " .. picker.selected)
    do
      local row
      for _, r in ipairs(picker.row_hits) do
        if r.index == picker.selected then row = r end
      end
      check(row ~= nil and row.y >= picker.position.y
              and row.y + row.h <= picker.position.y + picker.size.y + 1,
        "picker: the selected row is off screen after 60 downs -- nothing "
        .. "scrolls the list to follow the arrow keys")
    end
    shot("picker")

    -- Filtering to one match and pressing enter opens THAT match, not the
    -- parent -- ".." used to be kept in the filtered list, first.
    picker:cd(FIX)
    frame(2)
    core.on_event("textinput", "m")
    core.on_event("textinput", "a")
    frame(2)
    local vis = picker:visible_entries()
    check(#vis == 1 and vis[1].name == "many", string.format(
      "picker: filtering to 'ma' leaves %d rows (%s), not just 'many'",
      #vis, vis[1] and vis[1].name or "-"))
    local before = picker.dir
    core.on_event("keypressed", "return")
    frame(2)
    check(picker.dir ~= before and picker.dir:find("many", 1, true) ~= nil,
      "picker: enter on a filtered match went to " .. picker.dir)

    -- An unreadable directory keeps ".." so a keyboard user can leave it.
    sys.mkdir_p(FIX .. "/shut")
    pcall(os.execute, "chmod 000 '" .. FIX .. "/shut' 2>/dev/null")
    picker:cd(FIX .. "/shut")
    frame(2)
    if picker.error then
      check(#picker.entries >= 1 and picker.entries[1].up,
        "picker: an unreadable directory has no '..' row -- the only way out "
        .. "is the mouse")
    end
    pcall(os.execute, "chmod 755 '" .. FIX .. "/shut' 2>/dev/null")
    do
      local n = core.root_view.root_node:get_node_for_view(picker)
      if n then n:set_active_view(picker); n:close_active_view(core.root_view.root_node) end
    end

    -- ---- marks over a write with two changes in it -------------------------
    local marks = require "core.marks"
    local T = FIX .. "/two-hunks.lua"
    local a, b = {}, {}
    for i = 1, 40 do a[i] = "line " .. i end
    for i = 1, 40 do b[i] = a[i] end
    b[4] = "CHANGED FOUR"
    b[37] = "CHANGED THIRTY-SEVEN"
    local old, new = table.concat(a, "\n") .. "\n", table.concat(b, "\n") .. "\n"
    marks.clear(T)
    marks.from_edit(T, old, new, { path = T })
    do
      local lines = {}
      for _, m in ipairs(marks.all(T)) do lines[#lines + 1] = m.line end
      check(#lines == 2 and lines[1] == 4 and lines[2] == 37, string.format(
        "marks: a two-change write marked %d lines (%s) instead of 4 and 37",
        #lines, table.concat(lines, ",")))
    end

    -- ...and an earlier mark moves the right amount when a later write inserts
    -- above it AND changes something below it, in one write.
    local U = FIX .. "/moved.lua"
    marks.clear(U)
    local first_ids = marks.from_edit(U, "a\nb\nc\nd\ne\nf\n",
                                         "a\nb\nSEE\nd\ne\nf\n")  -- line 3
    marks.from_edit(U, "a\nb\nSEE\nd\ne\nf\n",
                       "x\ny\na\nb\nSEE\nd\ne\nEFF\n")            -- +2 above
    do
      -- That mark, by id, not "is anything on line 5": the single-hunk answer
      -- marks the whole file, so a line-5 check passes while the original is
      -- still sitting at 3.
      local m = marks.by_id(U, first_ids[1])
      check(m ~= nil and m.line == 5, string.format(
        "marks: the first write's mark is at line %s, not the 5 it moved to "
        .. "when a later write inserted two lines above and changed a line "
        .. "below it", tostring(m and m.line)))
    end

    -- ---- a panel the agent got wrong ---------------------------------------
    local PanelView = require "core.panelview"
    local uisandbox = require "core.uisandbox"
    sys.mkdir_p(bog.userdir .. "/ui")
    local function panel(name, src)
      local f = io.open(bog.userdir .. "/ui/" .. name .. ".lua", "wb")
      check(f ~= nil, "could not write the " .. name .. " panel fixture")
      if not f then return nil end
      f:write(src); f:close()
      local pv = PanelView(name)
      core.root_view:get_primary_node():add_view(pv)
      core.set_active_view(pv)
      return pv
    end

    local spinner = panel("uicheck_spin",
      "function draw(ctx)\n"
      .. "  while true do pcall(function() while true do end end) end\n"
      .. "end")
    if spinner then
      local t0 = system.get_time()
      frame(3)
      local secs = system.get_time() - t0
      check(secs < 5, string.format(
        "panel: three frames of an unbounded draw took %.1fs -- the window is "
        .. "hung, and a panel that swallows the guard in its own pcall is "
        .. "still swallowing it", secs))
      check(spinner.errors > 0 and (spinner.err or ""):find("did not finish"),
        "panel: an unbounded draw was not reported as one (err: "
        .. tostring(spinner.err) .. ")")
    end

    -- A panel cannot repaint the rest of the application. Only the top level of
    -- the theme was frozen, so style.padding.x -- which every view lays itself
    -- out with -- was writable through the read-only proxy.
    local thief = panel("uicheck_theft", [[
function draw(ctx)
  ctx.state.ok1 = pcall(function() style.padding.x = 0 end)
  ctx.state.ok2 = pcall(function() style.background = { 255, 0, 0, 255 } end)
  ctx.text("theft", ctx.x, ctx.y, style.text)
end]])
    if thief then
      local pad_before = require("core.style").padding.x
      frame(3)
      check(thief.state.ok1 == false,
        "panel: a generated panel wrote to style.padding through the "
        .. "read-only theme proxy")
      check(thief.state.ok2 == false,
        "panel: a generated panel replaced a theme colour")
      check(require("core.style").padding.x == pad_before,
        "panel: the application's padding changed under a panel")
      shot("panel")
    end
    for _, name in ipairs { "uicheck_spin", "uicheck_theft" } do
      local pv = nil
      for _, node_view in ipairs(core.root_view.root_node:get_children()) do
        if node_view.name == name then pv = node_view end
      end
      local n = pv and core.root_view.root_node:get_node_for_view(pv)
      if n then n:set_active_view(pv); n:close_active_view(core.root_view.root_node) end
      os.remove(bog.userdir .. "/ui/" .. name .. ".lua")
    end

    -- ---- the sidebar with more sessions than fit ---------------------------
    local sb = studio.sidebar
    sb.visible = true
    local saved_sessions, saved_at = sb.sessions, sb.last_refresh
    local rows = {}
    for i = 1, 300 do
      rows[i] = { id = i, title = (i == 2 and "") or ("session " .. i) }
    end
    rows[3].title = string.rep("\u{65e5}\u{672c}\u{8a9e}", 80)
    sb.sessions = rows
    sb.last_refresh = os.time() + 3600
    core.set_active_view(sb)
    frame(4)

    check(sb:get_scrollable_size() ~= math.huge,
      "sidebar: get_scrollable_size is still math.huge -- the scrollbar can "
      .. "never be drawn and the scroll can never be clamped")
    do
      local _, _, sw, sh = sb:get_scrollbar_rect()
      check(sw > 0 and sh > 0, string.format(
        "sidebar: 300 sessions produce a %.0fx%.0f scrollbar", sw, sh))
    end
    check(#sb.hits < 80, string.format(
      "sidebar: %d hit rects for 300 sessions -- the list is not clipped to "
      .. "the viewport", #sb.hits))

    -- The footer owns its own pixels; a row drawn under it wins the hit test.
    do
      local footer
      for _, h in ipairs(sb.hits) do
        if h.item and h.item.id == "model" then footer = h end
      end
      check(footer ~= nil, "sidebar: no footer hit rect")
      if footer then
        for _, h in ipairs(sb.hits) do
          check(h == footer or h.y >= footer.y + footer.h
                  or h.y + h.h <= footer.y,
            "sidebar: a session row overlaps the footer, and wins its clicks")
        end
      end
    end
    for _, h in ipairs(sb.hits) do
      if h.item and tostring(h.item.id or ""):find("^sess") then
        check(utf8.len(tostring(h.item.id)) ~= nil, "sidebar: a row id is not UTF-8")
      end
    end
    shot("sidebar")
    sb.sessions, sb.last_refresh = saved_sessions, saved_at

    -- Collapsing with a drag still held must not throw the width away.
    do
      local function find(node)
        if node.type == "leaf" then return nil end
        for _, which in ipairs { "a", "b" } do
          local c = node[which]
          if c.type == "leaf" and c.active_view == sb then return node end
        end
        return find(node.a) or find(node.b)
      end
      local split = find(core.root_view.root_node)
      sb:set_target_size("x", 260); sb:update()
      local kept = sb.size.x
      sb.visible = false
      sb.init_size = true
      sb:update()
      if split then
        core.root_view.dragged_divider = split
        core.root_view:on_mouse_moved(0, 0, 1, 0)
        core.root_view.dragged_divider = nil
      end
      sb:update()
      check(sb.visible and sb.size.x == kept, string.format(
        "sidebar: a drag after a collapse reopened it at %.0f, not the %.0f it "
        .. "had -- the width the user chose was discarded", sb.size.x, kept))
      sb:set_target_size("x", 210); sb:update()
    end

    -- ---- settings ----------------------------------------------------------
    --
    -- Nothing here commits: the field is filled and then abandoned, because
    -- ui-check runs against the real home directory of whoever ran it.
    local SettingsView = require "core.settingsview"
    local sv = SettingsView()
    core.root_view:get_primary_node():add_view(sv)
    core.set_active_view(sv)
    frame(4)
    check_hits("settings", sv)
    sv:edit(1)
    core.on_event("textinput", "a")
    core.on_event("textinput", "\u{00e9}")
    check(sv.buffer == "a\u{00e9}", "settings: the field ignored the keyboard")
    core.on_event("keypressed", "backspace")
    check(sv.buffer == "a" and utf8.len(sv.buffer) ~= nil, string.format(
      "settings: backspace over a two-byte character left %q, which is not "
      .. "a whole character", sv.buffer))
    core.on_event("keypressed", "escape")
    check(sv.focus == nil, "settings: escape left the field editing")

    -- Committing an empty field says so. It used to return in silence, which
    -- is what clearing the box and pressing enter looks like.
    sv:edit(2)
    sv.notice = nil
    core.on_event("keypressed", "return")
    check(sv.notice ~= nil and sv.notice.bad, "settings: committing an empty "
      .. "field reported nothing at all")
    shot("settings")
    do
      local n = core.root_view.root_node:get_node_for_view(sv)
      if n then n:set_active_view(sv); n:close_active_view(core.root_view.root_node) end
    end

    v = studio.open_agent()
    core.set_active_view(v)
    frame(3)
  end)
  check(ok2, "the surfaces probe raised: " .. tostring(err2))

  check(ok, "the probe raised: " .. tostring(err))

  if #problems > 0 then
    io.write("FAIL\n")
    for _, p in ipairs(problems) do io.write("  - " .. p .. "\n") end
    io.flush()
    os.exit(1)
  end
  io.write(string.format("ok  conversation %dx%d, sidebar %d, rail %s  wrote %s (+9 scenarios)\n",
    v.size.x, v.size.y, studio.sidebar.size.x,
    studio.rail and tostring(math.floor(studio.rail.size.x)) or "off", OUT))
  io.flush()
  os.exit(0)
end)
