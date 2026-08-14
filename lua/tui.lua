-- tui.lua -- the full-screen chat cTUI (`boggart --tui`).
--
-- A terminal application over `tc` (the termctl cell grid): a scrolling
-- transcript, a status row, and an input line. It is the terminal sibling of the
-- studio's chat panel and shares its machinery -- termrender for the transcript,
-- bog.api.status for the status row, bog.complete / bog.repl_style (through the
-- input widget) for the prompt -- so the two front ends stay one engine.
--
-- Why this exists as its own mode rather than dressing up the scrolling REPL:
-- isocline (the REPL's line editor) and termctl both drive the terminal and
-- cannot run at once. So the cTUI does not use isocline; it renders with tc and
-- edits input with tui.input. The scrolling REPL keeps isocline. They are
-- separate modes, chosen at startup, and this one bows out (returns false) when
-- there is no real terminal, so piped and one-shot runs fall back to the REPL.
--
-- The frame is caller-owned: poll once, paint once, per iteration. For a single
-- agent that is just this loop; the streaming on_text callback repaints as the
-- answer arrives, so a turn is live rather than a freeze. (Servicing a whole
-- swarm's concurrent turns from here -- painting one frame per scheduler
-- iteration -- is the next step; this v1 runs one turn at a time.)
local M = {}

local Input = require("tui.input")

-- The studio palette (style.lua), the same hexes termrender and the status bar
-- use, so the chrome matches the content.
local C = {
  dim     = "525257",
  text    = "97979c",
  accent  = "e1e1e6",
  bar_bg  = "252529",
  amber   = "ffa94d",
  cursor  = "e1e1e6",
}

-- ---- painting helpers ------------------------------------------------------

-- Blit a run-line (a list of {text, fg, bg, attr}) starting at (x, y). Returns
-- the column just past the last glyph.
local function blit(x, y, runs)
  for _, r in ipairs(runs or {}) do
    x = tc.puts(x, y, r.text or "", r.fg, r.bg, r.attr)
  end
  return x
end

-- Paint a whole row with one background, then text over it -- used for the
-- status bar so it reads as a solid band across the terminal.
local function fill_row(y, w, bg)
  for x = 0, w - 1 do tc.set(x, y, 32, nil, bg, nil) end
end

-- ---- transcript ------------------------------------------------------------
-- Each entry renders to a list of run-lines via termrender.runs. Completed
-- entries are cached on the entry itself (by width and text length), so a
-- growing streamed answer only re-renders the one entry that changed and a long
-- backlog is not re-flowed on every keystroke.
local function entry_lines(e, width)
  if e._rl and e._rw == width and e._rn == #(e.text or "") then return e._rl end
  local ok, lines = pcall(bog.termrender.runs, e, { width = width })
  if not ok or type(lines) ~= "table" then
    lines = { { { text = tostring(e.text or "") } } }
  end
  e._rl, e._rw, e._rn = lines, width, #(e.text or "")
  return lines
end

-- All entries flattened to run-lines, a blank line between them.
local function transcript_lines(entries, width)
  local out = {}
  for i, e in ipairs(entries) do
    if i > 1 then out[#out + 1] = {} end
    for _, ln in ipairs(entry_lines(e, width)) do out[#out + 1] = ln end
  end
  return out
end

-- ---- status row ------------------------------------------------------------
local function status_runs()
  local ok, s = pcall(bog.api.status)
  if not ok or not s then return { { text = " (no model) ", fg = C.dim, bg = C.bar_bg } } end
  local frac = 0
  pcall(function() frac = bog.api.context_fraction(bog.session) or 0 end)
  local agents = 0
  pcall(function() agents = bog.worker.count() or 0 end)
  local bg = C.bar_bg
  local runs = {
    { text = " " .. s.provider .. " ", fg = s.is_local and C.text or C.amber, bg = bg,
      attr = s.is_local and nil or { bold = true } },
    { text = "\u{00B7} " .. s.model .. " ", fg = C.text, bg = bg },
  }
  if s.is_local then runs[#runs + 1] = { text = "\u{00B7} " .. s.host .. " ", fg = C.dim, bg = bg } end
  runs[#runs + 1] = { text = string.format("\u{00B7} ctx %d%% ", math.floor(frac * 100 + 0.5)), fg = C.dim, bg = bg }
  runs[#runs + 1] = { text = string.format("\u{00B7} %d agent%s ", agents, agents == 1 and "" or "s"), fg = C.dim, bg = bg }
  return runs
end

-- ---- the frame -------------------------------------------------------------
local function draw(st)
  local w, h = tc.size()
  if h < 3 or w < 8 then return end
  tc.clear()

  -- Transcript fills every row above the status and input rows. `scroll` counts
  -- lines up from the bottom; 0 pins to the newest.
  local body = h - 2
  local lines = transcript_lines(st.entries, w)
  st.total = #lines
  local top = math.max(0, #lines - body - st.scroll)
  for i = 0, body - 1 do
    local ln = lines[top + i + 1]
    if ln then blit(0, i, ln) end
  end

  -- Status row, then the input row with a block cursor.
  fill_row(h - 2, w, C.bar_bg)
  blit(0, h - 2, status_runs())
  local iruns, cursor_col = st.box:runs(w)
  blit(0, h - 1, iruns)
  local cx = math.min(math.max(0, cursor_col or 0), w - 1)
  tc.set(cx, h - 1, 32, nil, C.cursor, nil) -- a reverse-ish block where the cursor sits

  tc.flush()
end

-- Run one turn, streaming into a live assistant entry so the answer appears as
-- it arrives. Blocking is fine here: a single conversation has nothing else to
-- service, and each chunk repaints.
local function run_turn(st, text)
  local e = { role = "assistant", text = "" }
  st.entries[#st.entries + 1] = e
  st.scroll = 0
  local ok, err = pcall(function()
    bog.api.run_turn(text, function(chunk)
      e.text = e.text .. chunk
      draw(st)
    end)
  end)
  if not ok then
    st.entries[#st.entries + 1] = { role = "error", text = tostring(err) }
  end
  pcall(bog.save_session)
end

-- run() -> true if the cTUI ran, false if there is no terminal for it (so the
-- caller falls back to the scrolling REPL). Restores the terminal on every exit
-- path, including an error mid-frame.
function M.run()
  if not (tc and tc.init and tc.init()) then return false end

  local st = { entries = {}, box = Input.new{}, scroll = 0, total = 0 }
  pcall(bog.new_session)

  local ok, err = pcall(function()
    local _, h = tc.size()
    draw(st)
    while true do
      local ev = tc.poll(100)
      local t = ev.type
      if t == "resize" then
        draw(st)
      elseif t == "key" then
        if ev.key == "ctrl" and ev.char == "q" then break end
        if ev.key == "pageup" then
          st.scroll = math.min(st.total, st.scroll + (select(2, tc.size()) - 3)); draw(st)
        elseif ev.key == "pagedown" then
          st.scroll = math.max(0, st.scroll - (select(2, tc.size()) - 3)); draw(st)
        else
          local action, value = st.box:key(ev)
          if action == "cancel" then
            break
          elseif action == "submit" then
            if value and value:match("%S") then
              st.entries[#st.entries + 1] = { role = "user", text = value }
              run_turn(st, value)
            end
            draw(st)
          else
            draw(st)
          end
        end
      end
    end
  end)

  tc.shutdown()
  if not ok then io.stderr:write("tui: ", tostring(err), "\n") end
  return true
end

return M
