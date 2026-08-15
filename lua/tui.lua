-- tui.lua -- the full-screen chat cTUI (`boggart --tui`).
--
-- A terminal application over `tc` (the termctl cell grid): a scrolling
-- transcript, a live agents pane, a status row, and an input line. It is the
-- terminal sibling of the studio's chat panel and shares its machinery --
-- termrender for the transcript, bog.api.status for the status row, bog.complete
-- / bog.repl_style (through the input widget) for the prompt, and the swarm
-- scheduler for the fleet.
--
-- Why its own mode rather than dressing up the scrolling REPL: isocline (the
-- REPL's line editor) and termctl both drive the terminal and cannot run at
-- once. So the cTUI does not use isocline; it renders with tc and edits input
-- with tui.input. It bows out (returns false) when there is no real terminal, so
-- pipes and one-shot runs fall through to the REPL.
--
-- Swarm-aware frame. A turn does not block: the coordinator runs as a scheduler
-- actor, and sched.run's should_stop hook polls input and paints exactly one
-- frame per scheduler iteration -- the scheduler keeps the loop, the cTUI never
-- takes it, so every sub-agent the coordinator spawns keeps making progress
-- while you watch. This is dash.lua's rule, applied to the cell grid: the chat
-- is the coordinator, and a lone chat is simply a swarm whose fanout stayed at
-- one.
local M = {}

local Input = require("tui.input")
local uv = require("uv")

-- Frame budget for the scheduler-driven paint. should_stop fires once per
-- scheduler step -- i.e. once per stream chunk, dozens of times a second -- so
-- painting every time both floods the terminal and re-renders the whole growing
-- message each chunk (quadratic over a long answer). Instead paint at most ~30fps
-- and only when something changed, with a slower heartbeat so the agents pane's
-- elapsed clock still ticks while a turn sits waiting on the network.
-- Paint at most ~30fps (FRAME_MS) and only when something changed, with a slower
-- heartbeat (HEARTBEAT_MS): a repeating uv timer wakes the loop that often so the
-- agents pane's clock keeps ticking even while a turn waits on the network with
-- no other traffic. now_ms is uv.hrtime (the real monotonic clock) NOT uv.now
-- (the loop's cached time, which stalls between loop runs).
local FRAME_MS, HEARTBEAT_MS = 33, 250
local function now_ms() return uv.hrtime() // 1000000 end

-- The studio palette (style.lua), the same hexes termrender and the status bar
-- use, so the chrome matches the content.
local C = {
  dim    = "525257",
  text   = "97979c",
  accent = "e1e1e6",
  bar_bg = "252529",
  amber  = "ffa94d",
  cursor = "e1e1e6",
  divider = "202024",
  tool   = "7c86b8", -- the activity strip's muted blue
}

-- The tool/activity strip: a fixed, bounded, rolling region at the foot of the
-- transcript. Tool calls and notes go HERE, not into the conversation, so the
-- blue "» read: ..." lines stay in one place and roll instead of scattering
-- through the transcript. Shows the newest ACTIVITY_LINES; the buffer keeps more
-- for scrollback headroom but is capped.
local ACTIVITY_LINES, ACTIVITY_KEEP = 4, 300

-- Test hook: when BOGGART_TUI_SNAP names a file, every frame writes the actual
-- on-screen buffer there (tc.snapshot), so a harness can verify exactly what the
-- terminal shows rather than replaying the diff stream. Off unless set.
local SNAP = os.getenv("BOGGART_TUI_SNAP")

-- ---- painting helpers ------------------------------------------------------

-- Truncate a string to at most `cols` columns (one per codepoint, the same
-- approximation termrender wraps by), so a run cannot bleed past its region.
local function clip_cols(s, cols)
  if cols <= 0 then return "" end
  if not utf8 then return s:sub(1, cols) end
  local n = utf8.len(s)
  if not n or n <= cols then return s end
  local off = utf8.offset(s, cols + 1)
  return off and s:sub(1, off - 1) or s
end

-- Blit a run-line at (x,y), clipped to the exclusive right edge `maxx`. The clip
-- is what keeps the transcript out of the agents pane (and everything off the
-- divider): tc.puts alone only stops at the grid edge, so a line wider than its
-- column would otherwise overprint the pane beside it.
local function blit(x, y, runs, maxx)
  for _, r in ipairs(runs or {}) do
    local text = r.text or ""
    if maxx then
      local room = maxx - x
      if room <= 0 then break end
      text = clip_cols(text, room)
    end
    x = tc.puts(x, y, text, r.fg, r.bg, r.attr)
  end
  return x
end

local function fill_row(y, w, bg)
  for x = 0, w - 1 do tc.set(x, y, 32, nil, bg, nil) end
end

-- ---- transcript ------------------------------------------------------------
-- Each entry renders to run-lines via termrender.runs, cached on the entry by
-- width and text length so a long backlog is not re-flowed on every keystroke
-- and a streamed answer only re-renders the one entry that is still growing.
local function entry_lines(e, width)
  if e._rl and e._rw == width and e._rn == #(e.text or "") then return e._rl end
  local ok, lines = pcall(bog.termrender.runs, e, { width = width })
  if not ok or type(lines) ~= "table" then
    lines = { { { text = tostring(e.text or "") } } }
  end
  e._rl, e._rw, e._rn = lines, width, #(e.text or "")
  return lines
end

local function transcript_lines(entries, width)
  local out = {}
  for i, e in ipairs(entries) do
    if i > 1 then out[#out + 1] = {} end
    for _, ln in ipairs(entry_lines(e, width)) do out[#out + 1] = ln end
  end
  return out
end

-- ---- the live agent roster -------------------------------------------------
-- Every scheduler actor, joined with its thread record (for a human label) and
-- its file claim (what it is editing), mapped to the shape tui.agents renders.
-- The scheduler's yield kinds become a plain run/wait: runnable is running,
-- anything blocked (io/proc/recv) is waiting on the world.
local STATUS = { runnable = "run", io = "wait", proc = "wait", recv = "wait", stopping = "done" }

local function agent_snapshot(st)
  local sched = bog.sched
  if not (sched and sched.actors) then return {} end
  local labels = {}
  local ok, rows = pcall(bog.store.thread_list, false)
  if ok then for _, r in ipairs(rows) do labels[r.id] = r.title end end
  local claim = {}
  local okc, cl = pcall(bog.claims.list)
  if okc then for _, c in ipairs(cl) do if c.writer then claim[c.writer] = c.path end end end
  local now = os.time()
  local out = {}
  for _, a in ipairs(sched.actors) do
    out[#out + 1] = {
      id = a.id,
      label = labels[a.id] or (a.id == st.coord.id and "coordinator") or ("agent-" .. a.id),
      status = STATUS[a.status] or "run",
      elapsed = st.t0 and (now - st.t0) or nil,
      note = claim[a.id],
    }
  end
  return out
end

-- The pane is drawn only while there are actors to show; between turns the
-- transcript takes the full width. Loaded lazily and guarded, so the cTUI still
-- runs if the pane module is absent.
-- The transcript's minimum column and the pane's bounds. The pane is a nicety;
-- it must never shrink the transcript below MIN_TW, and on a terminal too narrow
-- for both it disappears entirely (the transcript takes the whole width). This
-- is the arithmetic that was wrong: a fixed 24-38 pane on a 30-column terminal
-- left the transcript 5 columns -- or, narrower still, a negative width, which
-- drew nothing. Fan-out shows in the status row's agent count regardless.
local MIN_TW, MIN_PANE, MAX_PANE = 30, 20, 40
local function pane_width(st, w)
  if not (bog.sched and bog.sched.count and bog.sched.count() > 0) then return 0 end
  if not M._Agents then
    local ok, A = pcall(require, "tui.agents")
    M._Agents = ok and A or false
  end
  if not M._Agents then return 0 end
  if w < MIN_TW + 1 + MIN_PANE then return 0 end -- no room for both -> no pane
  -- Up to a third of the width, bounded, and never past what leaves the
  -- transcript its minimum (the guard above makes this at least MIN_PANE).
  return math.max(MIN_PANE, math.min(MAX_PANE, w // 3, w - 1 - MIN_TW))
end

-- ---- status row ------------------------------------------------------------
local function status_runs(st)
  local ok, s = pcall(bog.api.status)
  if not ok or not s then return { { text = " (no model) ", fg = C.dim, bg = C.bar_bg } } end
  local frac = 0
  pcall(function() frac = bog.api.context_fraction(st.coord and st.coord.session or bog.session) or 0 end)
  local agents = 0
  pcall(function() agents = bog.sched and bog.sched.count and bog.sched.count() or 0 end)
  local bg = C.bar_bg
  local runs = {
    { text = " " .. s.provider .. " ", fg = s.is_local and C.text or C.amber, bg = bg,
      attr = s.is_local and nil or { bold = true } },
    { text = "\u{00B7} " .. s.model .. " ", fg = C.text, bg = bg },
  }
  if s.is_local then runs[#runs + 1] = { text = "\u{00B7} " .. s.host .. " ", fg = C.dim, bg = bg } end
  runs[#runs + 1] = { text = string.format("\u{00B7} ctx %d%% ", math.floor(frac * 100 + 0.5)), fg = C.dim, bg = bg }
  runs[#runs + 1] = { text = string.format("\u{00B7} %d agent%s ", agents, agents == 1 and "" or "s"), fg = C.dim, bg = bg }
  if st.running then runs[#runs + 1] = { text = "\u{00B7} working\u{2026} (Ctrl-C) ", fg = C.amber, bg = bg } end
  return runs
end

-- ---- the frame -------------------------------------------------------------
-- Rows the activity strip needs: a divider plus up to ACTIVITY_LINES of the
-- newest tool/log lines. Zero when there is nothing to show.
local function strip_rows(st)
  local n = st.activity and #st.activity or 0
  if n == 0 then return 0 end
  return math.min(ACTIVITY_LINES, n) + 1 -- +1 for the divider row
end

local function draw(st)
  local w, h = tc.size()
  if h < 3 or w < 8 then return end
  tc.clear()

  -- Split the height: input (h-1), status (h-2), then the activity strip, then
  -- the transcript/pane get whatever is left. The strip is dropped if the
  -- terminal is too short to keep a usable transcript.
  local sh = strip_rows(st)
  local body = h - 2 - sh
  if body < 3 then sh, body = 0, h - 2 end

  local pw = pane_width(st, w)
  local tw = pw > 0 and (w - pw - 1) or w

  -- transcript, left column, pinned to newest unless scrolled up
  local lines = transcript_lines(st.entries, tw)
  st.total = #lines
  local top = math.max(0, #lines - body - st.scroll)
  for i = 0, body - 1 do
    local ln = lines[top + i + 1]
    if ln then blit(0, i, ln, tw) end -- clipped to the transcript column
  end

  -- agents pane, right column (spans the transcript height, above the strip)
  if pw > 0 then
    local dx = w - pw - 1
    for y = 0, body - 1 do tc.set(dx, y, 0x2502, C.divider, nil, nil) end -- vertical rule
    local ok, prunes = pcall(M._Agents.runs, agent_snapshot(st), { width = pw, height = body })
    if ok and prunes then
      for i, ln in ipairs(prunes) do
        if i > body then break end
        blit(dx + 1, i - 1, ln, w)
      end
    end
  end

  -- the activity strip: a labelled divider, then the newest tool/log lines,
  -- rolling in place -- the one fixed home for the "» ..." blue lines.
  if sh > 0 then
    local hdr = "\u{2500}\u{2500} activity " .. string.rep("\u{2500}", math.max(0, w - 12))
    blit(0, body, { { text = hdr, fg = C.divider } }, w)
    local n = #st.activity
    local show = sh - 1
    local start = math.max(1, n - show + 1)
    for k = 0, show - 1 do
      local line = st.activity[start + k]
      if line then blit(0, body + 1 + k, { { text = line, fg = C.tool } }, w) end
    end
  end

  -- status row, then the input row with a block cursor
  fill_row(h - 2, w, C.bar_bg)
  blit(0, h - 2, status_runs(st), w)
  local iruns, cursor_col = st.box:runs(w)
  blit(0, h - 1, iruns, w)
  local cx = math.min(math.max(0, cursor_col or 0), w - 1)
  tc.set(cx, h - 1, 32, nil, C.cursor, nil)

  tc.flush()
  if SNAP and tc.snapshot then
    local f = io.open(SNAP, "w")
    if f then f:write(tc.snapshot()); f:close() end
  end
end

-- ---- swarm setup + turns ---------------------------------------------------
-- The cTUI runs the agent layer the same way every other mode does -- one shared
-- activation (bog.activate_agents): the scheduler, the coordination tools, the
-- bus and a raised fanout cap. The cTUI's own addition is a coordinator agent
-- whose session is the conversation (created in M.run).
local function setup_swarm() bog.activate_agents() end

local function page(st) local _, h = tc.size(); return math.max(1, h - 3) end

-- Run one turn under the scheduler. The coordinator streams into a live entry;
-- the should_stop hook paints one frame per iteration and lets the user scroll
-- or interrupt (Ctrl-C) while the fleet works.
local function run_turn(st, text)
  st.entries[#st.entries + 1] = { role = "user", text = text }
  st.cur = nil -- the first assistant chunk opens a fresh entry, after any tool call
  st.scroll, st.running, st.t0, st.abort = 0, true, os.time(), false
  st.dirty, st.last_paint = true, 0

  -- The coordinator's opts captured the ORIGINAL bog.log_tool (raw stdout) when
  -- it was built, before M.run swapped in the capture -- so run_on would use that
  -- and write tool lines straight to the alt screen, desyncing termctl's model
  -- from the real terminal (its front buffer stays clean while the screen fills
  -- with garbage). Force on_tool to the current capture so every tool call lands
  -- in the activity strip instead.
  local topts = {}
  for k, v in pairs(st.coord.opts or {}) do topts[k] = v end
  topts.on_tool = bog.log_tool

  local turn_err
  local co = coroutine.create(function()
    -- Assistant text streams into st.cur; a tool call (captured in M.run) closes
    -- it, so the next chunk opens a new entry and the conversation reads as clean
    -- prose segments. Never write here -- everything is an entry the cell grid
    -- draws, or it would shred the frame.
    local tok, terr = pcall(bog.api.run_on, st.coord.session, text, function(chunk)
      if not st.cur then
        st.cur = { role = "assistant", text = "" }
        st.entries[#st.entries + 1] = st.cur
      end
      st.cur.text = st.cur.text .. chunk
      st.dirty = true
    end, topts)
    if not tok then turn_err = terr end
  end)
  bog.sched.add(st.coord.id, co)

  -- The turn is just the swarm running on the one uv loop, and this is the
  -- classic event-loop body: drain input, resume whoever the last wait made
  -- ready, paint if due, then SLEEP in a single uv.run("once"). That wait wakes
  -- the instant ANY handle fires -- an http socket delivering a token (stdin is
  -- on the loop too, so a keypress wakes it just the same; the heartbeat timer
  -- guarantees the agent clock still ticks while a slow child streams). No
  -- fixed quantum: the stream flows at full socket speed, and input is never
  -- more than one event away. resume_ready only touches coroutines; the loop
  -- does the waiting -- so nothing here polls.
  st.dirty, st.last_paint = true, 0
  st.wake:start(HEARTBEAT_MS, HEARTBEAT_MS, function() end) -- wake to tick the clock
  while bog.sched.count() > 0 do
    local ev = tc.poll(0)
    while ev.type == "key" do
      if ev.key == "ctrl" and ev.char == "c" then st.abort = true end
      if ev.key == "pageup" then st.scroll = st.scroll + page(st); st.dirty = true end
      if ev.key == "pagedown" then st.scroll = math.max(0, st.scroll - page(st)); st.dirty = true end
      ev = tc.poll(0)
    end
    if st.abort then break end

    bog.sched.resume_ready()               -- advance the swarm (coroutines only)
    if bog.sched.count() == 0 then break end

    local dt = now_ms() - st.last_paint
    if dt >= FRAME_MS and (st.dirty or dt >= HEARTBEAT_MS) then
      st.dirty, st.last_paint = false, now_ms()
      draw(st)
    end

    uv.run("once")                         -- sleep until the next event
  end
  st.wake:stop()

  if st.abort then
    for _, a in ipairs(bog.sched.actors) do pcall(bog.sched.kill, a.id) end
    st.entries[#st.entries + 1] = { role = "system", text = "(interrupted)" }
  elseif turn_err then
    st.entries[#st.entries + 1] = { role = "error", text = tostring(turn_err) }
  end
  pcall(bog.store.thread_save, st.coord.id,
    { messages = st.coord.session.messages, status = "idle" })
  st.running = false
  draw(st)
end

-- run() -> true if the cTUI ran, false if there is no terminal for it. Restores
-- the terminal on every exit path, including an error mid-frame.
function M.run()
  if not (tc and tc.init and tc.init()) then return false end

  -- Put stdin on the uv loop: from here a keypress is a uv callback like an http
  -- socket or a timer, so the whole cTUI can sleep in ONE uv.run and wake the
  -- instant anything happens -- keyboard, a streamed token, the clock. This is
  -- what makes the event-loop body below correct (and what every Node TUI does:
  -- raw stdin is a libuv handle, never polled). If it fails there is no terminal
  -- we can drive that way, so fall back to the scrolling REPL.
  if not tc.attach() then tc.shutdown(); return false end

  local ok0, coord = pcall(function()
    setup_swarm()
    return bog.thread.new_agent{ agent = "coordinator", title = "coordinator", model = bog.session.model }
  end)
  if not ok0 or not coord then tc.shutdown(); return false end
  bog.swarm_root = coord

  local st = { coord = coord, entries = {}, activity = {}, box = Input.new{},
               scroll = 0, total = 0, running = false, wake = uv.new_timer() }

  -- Route the agent's line logging into the fixed activity strip, not the
  -- conversation. bog.log_tool and bog.log write raw bytes to stdout/stderr; in
  -- the cell-grid cTUI those land wherever the cursor happens to sit and shred
  -- the frame -- the classic symptom being "» read: ..." tool lines smeared
  -- through the streamed text. Captured here into a bounded rolling buffer that
  -- draw() paints in one place, and only the coordinator's: a sub-agent's calls
  -- belong to the pane (dropped here, not printed, so they cannot corrupt
  -- anything either). A tool call also closes the open assistant run, so the
  -- transcript reads as clean prose segments. Restored on exit (dash.lua does the
  -- same for ltui).
  local saved_log_tool, saved_log = bog.log_tool, bog.log
  local function is_coord()
    local cur = bog.sched and bog.sched.current()
    return cur == nil or cur == st.coord.id
  end
  local function activity(line)
    st.activity[#st.activity + 1] = line
    if #st.activity > ACTIVITY_KEEP then table.remove(st.activity, 1) end
    st.cur, st.dirty = nil, true
  end
  bog.log_tool = function(name, input)
    if not is_coord() then return end
    local preview = ""
    if type(input) == "table" then
      local hint = input.command or input.path or input.query or input.name or input.title
      if hint then preview = ": " .. tostring(hint):gsub("%s+", " "):sub(1, 200) end
    end
    activity("\u{00BB} " .. tostring(name) .. preview) -- "» name: preview"
  end
  bog.log = function(msg) if is_coord() then activity("\u{00B7} " .. tostring(msg)) end end

  -- The between-turns prompt is the same event loop as a turn, just with no
  -- actors running: drain every buffered key, act on it, then sleep in a single
  -- uv.run("once") until the next keypress wakes us (stdin is on the loop). No
  -- poll timeout, no spin -- the process is genuinely asleep between keystrokes.
  local ok, err = pcall(function()
    draw(st)
    local quit = false
    while not quit do
      local ev = tc.poll(0)
      while ev.type ~= "none" do
        if ev.type == "resize" then
          draw(st)
        elseif ev.type == "key" then
          if ev.key == "ctrl" and ev.char == "q" then quit = true; break end
          if ev.key == "pageup" then
            st.scroll = math.min(st.total, st.scroll + page(st)); draw(st)
          elseif ev.key == "pagedown" then
            st.scroll = math.max(0, st.scroll - page(st)); draw(st)
          else
            local action, value = st.box:key(ev)
            if action == "cancel" then
              quit = true; break
            elseif action == "submit" then
              if value and value:match("%S") then run_turn(st, value) end
              draw(st)
            else
              draw(st)
            end
          end
        end
        ev = tc.poll(0)
      end
      if quit then break end
      uv.run("once") -- sleep until a keypress (or leftover loop handle) wakes us
    end
  end)

  bog.log_tool, bog.log = saved_log_tool, saved_log -- restore before leaving the alt screen
  if st.wake then pcall(function() st.wake:stop(); st.wake:close() end) end
  tc.shutdown()
  if not ok then io.stderr:write("tui: ", tostring(err), "\n") end
  return true
end

return M
