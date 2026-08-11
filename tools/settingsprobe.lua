-- settingsprobe.lua -- drive the settings form the way a keyboard would.
--
--   export T=$(mktemp -d)
--   HOME=$T BOGGART_STUDIO_SCRIPT=$PWD/tools/settingsprobe.lua ./boggart-studio .
--
-- The throwaway HOME is not optional: this writes an API key, an endpoint and a
-- model into ~/.boggart/auth, and running it against a real home would overwrite
-- whatever is there.
--
-- Every assertion goes through the view's own entry points -- edit, on_text_input
-- per character, on_key_pressed -- rather than calling auth directly, because the
-- thing under test is the wiring between them. The one claim that cannot be made
-- from the inside is the important one: field 1 never contains the key that was
-- typed, only what C is prepared to say about it.
local core = require "core"

core.add_thread(function()
  coroutine.yield(0.3)
  local out = {}
  local function p(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    out[#out + 1] = table.concat(parts, " | ")
  end

  local ok, err = pcall(function()
    local studio = require "core.studio"
    local sv = studio.open_settings()
    p("view", sv:get_name(), core.active_view == sv)

    local function typein(i, s)
      sv:edit(i)
      for c in s:gmatch(".") do sv:on_text_input(c) end
    end

    -- 1. API key -----------------------------------------------------------
    p("has_key_before", auth.has_key())
    typein(1, "sk-ant-probe-0123456789ABCDEF")
    p("buffer_len", #sv.buffer)
    sv:on_key_pressed("return")
    p("has_key_after", auth.has_key())
    p("masked", (auth.masked()))
    p("notice_key", sv.notice and sv.notice.text, sv.notice and sv.notice.bad)
    local f = sv:fields()
    p("field1_shown", f[1].value)
    p("field1_leaks_key", tostring(f[1].value):find("ABCDEF", 1, true) ~= nil)
    p("auth_has_getter", rawget(auth, "get") ~= nil or rawget(auth, "api_key") ~= nil)

    -- 2. Endpoint round-trip ------------------------------------------------
    typein(2, "http://127.0.0.1:8000")
    sv:on_key_pressed("return")
    p("endpoint", bog.api.endpoint())
    p("base_url", auth.base_url())
    p("field2_shown", sv:fields()[2].value)
    p("notice_ep", sv.notice and sv.notice.text, sv.notice and sv.notice.bad)

    -- 3. Escape abandons ----------------------------------------------------
    local before = auth.base_url()
    typein(2, "http://garbage.invalid")
    sv:on_key_pressed("escape")
    p("escape_focus_cleared", sv.focus == nil, sv.buffer == "")
    p("escape_kept_endpoint", auth.base_url() == before, auth.base_url())

    -- 4. Nonsense context window is rejected --------------------------------
    bog.session.context_limit = nil
    local limit_before = bog.api.context_limit(bog.session)
    typein(4, "banana")
    sv:on_key_pressed("return")
    p("ctx_rejected_notice", sv.notice and sv.notice.text, sv.notice and sv.notice.bad)
    p("ctx_unchanged", bog.api.context_limit(bog.session) == limit_before,
      bog.session.context_limit)
    typein(4, "12")
    sv:on_key_pressed("return")
    p("ctx_too_small", sv.notice and sv.notice.text, sv.notice and sv.notice.bad,
      bog.session.context_limit)
    typein(4, "250000")
    sv:on_key_pressed("return")
    p("ctx_accepted", sv.notice and sv.notice.text, sv.notice and sv.notice.bad,
      bog.api.context_limit(bog.session))
    p("field4_shown", sv:fields()[4].value)

    -- 5. Model + backspace + tab -------------------------------------------
    typein(3, "claude-opus-5X")
    sv:on_key_pressed("backspace")
    p("backspace_buffer", sv.buffer)
    sv:on_key_pressed("return")
    p("model", bog.session.model, auth.model and auth.model())
    p("field3_shown", sv:fields()[3].value)

    sv:edit(1)
    sv:on_key_pressed("tab")
    p("tab_from_1", sv.focus)
    sv.focus = 4
    sv.buffer = ""
    sv:on_key_pressed("tab")
    p("tab_wraps_from_4", sv.focus)
    sv:on_key_pressed("escape")

    -- 6. Clear buttons ------------------------------------------------------
    local flds = sv:fields()
    p("clear_ep", select(2, pcall(flds[2].clear)))
    p("endpoint_after_clear", bog.api.endpoint())
    p("clear_key", select(2, pcall(flds[1].clear)))
    p("has_key_after_clear", auth.has_key())
    local empty = sv:fields()
    p("field1_when_unset", empty[1].value, empty[1].value == "not set")
    p("field1_hint_when_unset", empty[1].hint)
    if os.getenv("ANTHROPIC_API_KEY") then
      typein(1, "sk-ant-stored-but-ignored")
      sv:on_key_pressed("return")
      p("env_wins_notice", sv.notice and sv.notice.text, sv.notice and sv.notice.bad)
      p("env_wins_hint", sv:fields()[1].hint)
      p("env_clear_notice", select(2, pcall(sv:fields()[1].clear)))
    end

    -- 7. Unhandled keys fall through ---------------------------------------
    sv.focus = nil
    p("unfocused_key_returns", sv:on_key_pressed("return"))
    sv:edit(1)
    p("focused_unknown_key", sv:on_key_pressed("f5"))
    sv:on_key_pressed("escape")
  end)

  io.write("OK=", tostring(ok), " ERR=", tostring(err), "\n")
  io.write(table.concat(out, "\n"), "\n")
  io.flush()
  os.exit(0)
end)
