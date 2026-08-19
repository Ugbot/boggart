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
local help = require("tui.help")
local gate = require("tui.gate")
local take = require("take")
local perm = require("perm")
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
  plum   = "9b7ad4", -- the logo wardrobe (a touch brighter so it reads on dark)
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

-- Truncate a string to at most `cols` display columns (sys.width / wcwidth, the
-- same unit termrender wraps by), so a run cannot bleed past its region. CJK
-- and emoji occupy two cells; clipping by codepoint would let them overprint
-- the agents pane.
local function clip_cols(s, cols)
  if cols <= 0 then return "" end
  s = tostring(s or "")
  if sys and sys.width and sys.width(s) <= cols then return s end
  if sys and sys.wtake then return sys.wtake(s, cols) end
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
-- The logo mascot renders verbatim (box-drawing must not reflow): one run-line
-- per source line, walking each line so the robot glyphs come out amber and the
-- wardrobe plum. Everything else goes through termrender.
local ART_TOKENS = { "(•‿•)", "╰┘", "╷" }
local function art_runs(line)
  local runs, i = {}, 1
  while i <= #line do
    local hit
    for _, tok in ipairs(ART_TOKENS) do
      if line:sub(i, i + #tok - 1) == tok then
        runs[#runs + 1] = { text = tok, fg = C.amber }; i = i + #tok; hit = true; break
      end
    end
    if not hit then
      local b = line:byte(i)
      local clen = b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4
      local ch = line:sub(i, i + clen - 1)
      local last = runs[#runs]
      if last and last.fg == C.plum then last.text = last.text .. ch
      else runs[#runs + 1] = { text = ch, fg = C.plum } end
      i = i + clen
    end
  end
  return runs
end

-- Each entry renders to run-lines via termrender.runs, cached on the entry by
-- width and text length so a long backlog is not re-flowed on every keystroke
-- and a streamed answer only re-renders the one entry that is still growing.
local function entry_lines(e, width)
  if e.role == "art" then
    if e._art then return e._art end
    local out = {}
    for line in (e.text .. "\n"):gmatch("(.-)\n") do out[#out + 1] = art_runs(line) end
    e._art = out
    return out
  end
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
      -- The coordinator is labelled by its ROLE here whatever its stored title
      -- is: the session title now names the conversation (for the chat list),
      -- so the roster must not inherit it and read as "agent: lets get back...".
      label = (a.id == st.coord.id and "coordinator") or labels[a.id] or ("agent-" .. a.id),
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
  local mode = (st.mode or perm.state().mode or "smart")
  runs[#runs + 1] = { text = "\u{00B7} " .. mode .. " ", fg = C.text, bg = bg }
  if st.help then runs[#runs + 1] = { text = "\u{00B7} ? ", fg = C.amber, bg = bg } end
  if st.eof_arm then runs[#runs + 1] = { text = "\u{00B7} Ctrl-D again to quit ", fg = C.amber, bg = bg } end
  if st.running then runs[#runs + 1] = { text = "\u{00B7} working\u{2026} (Esc) ", fg = C.amber, bg = bg } end
  -- You can keep typing while a turn runs; Enter is held until it finishes. Say so
  -- when there is composed text waiting, so a blocked Enter never feels broken.
  if st.running and st.box and (st.box.line or "") ~= "" then
    runs[#runs + 1] = { text = "\u{00B7} \u{21B5} held ", fg = C.tool, bg = bg }
  end
  return runs
end

-- ---- the frame -------------------------------------------------------------
-- Rows the activity strip needs: a divider plus up to ACTIVITY_LINES of the
-- newest tool/log lines. Zero when there is nothing to show.
local function strip_rows(st)
  local n = st.activity and #st.activity or 0
  if n == 0 then return 0 end
  local cap = st.activity_max or ACTIVITY_LINES
  return math.min(cap, n) + 1 -- +1 for the divider row
end

local function draw(st)
  local w, h = tc.size()
  if help.too_small(w, h) then
    tc.clear()
    local msg = help.too_small_runs()
    local y = math.max(0, (h - #msg) // 2)
    for i, ln in ipairs(msg) do blit(math.max(0, (w - 24) // 2), y + i - 1, ln, w) end
    tc.flush()
    return
  end
  tc.clear()

  local vis, cursor_row, cursor_col = st.box:visual(w)
  local overlay = st.box:overlay_runs(w)
  local ih = math.max(1, #vis)
  local oh = #overlay
  local sh = strip_rows(st)
  local ask = (st.pending and st.pending.decision == nil)
    and perm.runs(st.pending, w) or {}
  local ah = #ask
  -- input rows + overlay + status + optional activity strip + approval bar
  local body = h - 1 - ih - oh - sh - ah
  if body < 3 then sh, body = 0, h - 1 - ih - oh - ah end
  if body < 1 then body = 1 end

  local pw = pane_width(st, w)
  local tw = pw > 0 and (w - pw - 1) or w

  -- transcript, left column, pinned to newest unless scrolled up
  local lines = transcript_lines(st.entries, tw)
  -- A pending `choose` menu renders at the foot of the transcript (where the eye
  -- is), so a parked turn asks its question in view. Answered in the key loop.
  if bog.choice then
    lines[#lines + 1] = { { text = "" } }
    local extra
    local okc, res = pcall(require("choose").runs, bog.choice, tw)
    if okc and type(res) == "table" then extra = res end
    if extra then
      for _, ln in ipairs(extra) do lines[#lines + 1] = ln end
    else
      lines[#lines + 1] = { { text = bog.choice.prompt, fg = C.tool } }
      for _, o in ipairs(bog.choice.options) do
        lines[#lines + 1] = { { text = "  " .. o.key .. ") ", fg = C.tool }, { text = o.label } }
      end
      if bog.choice.allow_input then
        lines[#lines + 1] = { { text = "  (press a letter, or type your own + Enter)", fg = C.divider } }
      end
    end
  end
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

  -- status row, then the approval bar, then the completion/search overlay,
  -- then the (possibly multiline) composer with a block cursor on the focused
  -- visual row.
  local status_y = body + sh
  fill_row(status_y, w, C.bar_bg)
  blit(0, status_y, status_runs(st), w)
  for i, ln in ipairs(ask) do
    blit(0, status_y + i, ln, w)
  end
  for i, ln in ipairs(overlay) do
    blit(0, status_y + ah + i, ln, w)
  end
  local input_y = status_y + 1 + ah + oh
  for i, ln in ipairs(vis) do
    blit(0, input_y + i - 1, ln, w)
  end
  local cx = math.min(math.max(0, cursor_col or 0), w - 1)
  local cy = math.min(input_y + (cursor_row or 1) - 1, h - 1)
  tc.set(cx, cy, 32, nil, C.cursor, nil)

  if st.help then
    local hr = help.runs(w)
    local top = math.max(0, (body - #hr) // 2)
    for i, ln in ipairs(hr) do blit(0, top + i - 1, ln, w) end
  end

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

-- Jump the transcript scroll to the previous/next user prompt. `{` / `}`
-- when the composer is empty, matching Claude Code and the studio normal mode.
local function jump_user(st, dir)
  local idxs = {}
  for i, e in ipairs(st.entries) do
    if e.role == "user" then idxs[#idxs + 1] = i end
  end
  if #idxs == 0 then return end
  local cur = st.user_i or (#idxs + (dir < 0 and 1 or 0))
  cur = math.max(1, math.min(#idxs, cur + dir))
  st.user_i = cur
  -- Pin that entry near the bottom of the body: count lines from the start
  -- through it, then scroll so it sits in view.
  local tw = select(1, tc.size())
  local lines, target = 0, 0
  for i, e in ipairs(st.entries) do
    if i > 1 then lines = lines + 1 end
    local n = #entry_lines(e, tw)
    if i == idxs[cur] then target = lines end
    lines = lines + n
  end
  local _, h = tc.size()
  local body = math.max(1, h - 6)
  st.scroll = math.max(0, lines - body - target)
  st.dirty = true
end

local function edit_in_editor(st)
  local vis = os.getenv("VISUAL") or os.getenv("EDITOR")
  if not vis or vis == "" then
    st.entries[#st.entries + 1] = { role = "system",
      text = "set $VISUAL or $EDITOR to edit the prompt" }
    st.dirty = true
    return
  end
  local path = (bog.userdir or os.getenv("TMPDIR") or "/tmp") .. "/boggart-prompt.txt"
  local f = io.open(path, "w")
  if not f then return end
  f:write(st.box.line or ""); f:close()
  tc.shutdown()
  os.execute(vis .. " '" .. path:gsub("'", "'\\''") .. "'")
  if not (tc.init and tc.init()) then return end
  tc.attach()
  local r = io.open(path, "r")
  if r then
    local body = r:read("*a") or ""
    r:close()
    st.box:_set(body:gsub("\r\n", "\n"):gsub("\n+$", ""))
  end
  st.dirty = true
end

local function note_mentions(st, notes)
  for _, n in ipairs(notes or {}) do
    if n.ok then
      st.entries[#st.entries + 1] = { role = "system",
        text = string.format("attached %s (%d bytes)", n.path, n.bytes) }
    else
      st.entries[#st.entries + 1] = { role = "error", text = "no such file: " .. n.path }
    end
  end
end

-- Shared keyboard handling for a pending choose menu (mid-turn or after-turn).
-- Numbered menus still answer to positional a/b via index_for_key.
local function handle_choice_input(st, ev)
  if not bog.choice then return false end
  local rec, CH = bog.choice, require("choose")
  if ev.key == "escape" then CH.decide(rec, { cancel = true }); st.dirty = true; return true
  elseif ev.key == "enter" then
    if st.box.line ~= "" then CH.decide(rec, { text = st.box.line }); st.box:_set("") end
    st.dirty = true; return true
  elseif st.box.line == "" and type(ev.char) == "string" and #ev.char == 1 then
    local i = CH.index_for_key(rec, ev.char)
    if i then CH.decide(rec, { index = i })
    else st.box:key(ev) end
    st.dirty = true; return true
  else st.box:key(ev); st.dirty = true; return true
  end
end

-- After a turn, offer a captured prose question as the same choose UX.
local function maybe_capture_choice(st)
  local choose = require("choose")
  local rec = choose.capture_from_session(st.coord.session)
  if not rec then return nil end
  st.captured_reply = nil
  choose.present_after_turn(rec, function(decision, r)
    st.captured_reply = choose.format_user_reply(r, decision)
    st.dirty = true
  end)
  while bog.choice do
    local ev = tc.poll(0)
    while ev.type ~= "none" do
      if ev.type == "resize" then st.dirty = true
      elseif ev.type == "mouse" then
        if ev.button == 64 then st.scroll = math.min(st.total, st.scroll + 3); st.dirty = true
        elseif ev.button == 65 then st.scroll = math.max(0, st.scroll - 3); st.dirty = true end
      elseif ev.type == "key" then
        if not handle_choice_input(st, ev) then st.box:key(ev); st.dirty = true end
      end
      ev = tc.poll(0)
    end
    if st.dirty then draw(st) end
    uv.run("once")
  end
  local reply = st.captured_reply
  st.captured_reply = nil
  return reply
end

-- Slash commands (/exit, /auth, /model, /help, ...). These run through the very
-- same handler the scrolling REPL uses, so the cTUI is not a second-class front
-- end that silently sends "/exit" to the model. handle_command writes its output
-- with io.write/print, which in a cell-grid TUI would shred the frame -- so we
-- capture that output (stripped of ANSI) into a system entry instead. Returns
-- "quit" for /exit and /quit.
local function slash(st, line)
  local cmd = line:match("^/(%S+)")
  if cmd == "exit" or cmd == "quit" then return "quit" end
  if not bog.handle_command then
    st.entries[#st.entries + 1] = { role = "system", text = "commands are unavailable" }
    return
  end
  local buf = {}
  local real_write, real_print = io.write, print
  io.write = function(...)
    for i = 1, select("#", ...) do buf[#buf + 1] = tostring((select(i, ...))) end
  end
  print = function(...)
    local t = {}
    for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
    buf[#buf + 1] = table.concat(t, "\t") .. "\n"
  end
  local ok, brk = pcall(bog.handle_command, line)
  io.write, print = real_write, real_print
  local out = table.concat(buf):gsub("\27%[[%d;]*m", ""):gsub("%s+$", "")
  if not ok then out = "command error: " .. tostring(brk) end
  if out ~= "" then st.entries[#st.entries + 1] = { role = "system", text = out } end
  st.dirty = true
  if brk == true then return "quit" end
  -- A command may ask (via a { run = prompt } return) to hand a failure to the
  -- agent -- e.g. a git push that was rejected. Pass it up to be run as a turn.
  if type(brk) == "table" and brk.run then return brk end
  return nil
end

-- text == nil resumes an interrupted turn (finish its tool round, then run on)
-- instead of starting a new one.
local function run_turn(st, text)
  if text ~= nil then
    st.entries[#st.entries + 1] = { role = "user", text = text }
    -- Name the conversation from its first real message. The coordinator session
    -- is created titled by its ROLE ("coordinator") for the fleet roster; that
    -- made every saved TUI chat show as "coordinator" in the session list, which
    -- read as "nothing saved". Do it once, on the first turn (before run_on
    -- appends this message), and persist so /sessions and resume can find it.
    local sess = st.coord.session
    if #(sess.messages or {}) == 0 then
      pcall(bog.store.thread_save, st.coord.id, { title = text:gsub("%s+", " "):sub(1, 60) })
    end
  end
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
  topts.run_tool = gate.run_tool(st)
  if st.mode == "chat" then
    topts.tools = function() return {} end
  end

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
    while ev.type ~= "none" do
      -- Mouse wheel scrolls the transcript (64 = up, 65 = down), even mid-turn.
      if ev.type == "mouse" then
        if ev.button == 64 then st.scroll = math.min(st.total, st.scroll + 3); st.dirty = true
        elseif ev.button == 65 then st.scroll = math.max(0, st.scroll - 3); st.dirty = true end
      elseif ev.type == "paste" then
        st.box:paste(ev.text); st.dirty = true
      elseif ev.type == "key" then
      if gate.key(st, ev) then st.dirty = true
      elseif st.help then st.help = false; st.dirty = true
      elseif handle_choice_input(st, ev) then
        -- parked choose (mid-turn tool or after-turn capture) owns the keyboard
      elseif ev.key == "esc" or ev.key == "escape" then
        st.abort = true
      else
      -- The input field stays LIVE while the turn runs: you can keep composing,
      -- and now you can SEND too. Enter queues the line onto the coordinator's
      -- inbox (api.run_on folds it into the next request, so it steers the
      -- agent mid-turn) rather than being withheld. Ctrl-C aborts, Ctrl-P
      -- pauses/resumes the sub-agents, PageUp/Down scroll; every other key edits.
      if ev.key == "ctrl" and ev.char == "c" then st.abort = true

      elseif ev.key == "ctrl" and ev.char == "p" then
        st.paused = not st.paused
        for _, a in ipairs(bog.sched.actors) do
          if a.id ~= st.coord.id then pcall(bog.sched.pause, a.id, st.paused) end
        end
        st.dirty = true
      elseif ev.key == "ctrl" and ev.char == "o" then
        st.activity_max = (st.activity_max == 16) and ACTIVITY_LINES or 16
        st.dirty = true
      elseif ev.key == "pageup" then st.scroll = math.min(st.total, st.scroll + page(st)); st.dirty = true
      elseif ev.key == "pagedown" then st.scroll = math.max(0, st.scroll - page(st)); st.dirty = true
      elseif ev.key == "enter" then
        local action, value = st.box:key(ev)
        if action == "submit" and value and value:match("%S") then
          st.coord.session.inbox = st.coord.session.inbox or {}
          st.coord.session.inbox[#st.coord.session.inbox + 1] = value
          st.entries[#st.entries + 1] = { role = "user", text = value }
          st.cur = nil        -- a following assistant chunk opens a fresh entry
          st.dirty = true
        end
      else st.box:key(ev); st.dirty = true end
      end
      end
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
    local resumable = bog.api.incomplete_turn and bog.api.incomplete_turn(st.coord.session)
    st.entries[#st.entries + 1] = { role = "system",
      text = resumable and "(interrupted — Enter to resume, or type to abandon)"
                        or "(interrupted)" }
  elseif turn_err then
    st.entries[#st.entries + 1] = { role = "error", text = tostring(turn_err) }
  end
  st.paused = false
  -- On cancel, make only the IN-FLIGHT tool safe (finalize_pending: a tool that
  -- was mid-execution becomes interrupted so it is never blindly re-run). Tools
  -- that never started are left unanswered ON PURPOSE, so the turn stays
  -- RESUMABLE -- durable checkpointing already saved every completed result.
  -- Enter on an empty box resumes; typing a new message abandons and repairs.
  if st.abort then pcall(bog.api.finalize_pending, st.coord.session) end
  pcall(bog.store.thread_save, st.coord.id,
    { messages = st.coord.session.messages, status = "idle" })
  st.running = false
  draw(st)
  if st.abort or turn_err then return nil end
  return maybe_capture_choice(st)
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
  bog.choice_ui = true   -- an async chooser is live: the `choose` tool parks here

  local hist_file = (bog.userdir or "") .. "/history"
  local st = { coord = coord, entries = {}, activity = {},
               box = Input.new{ history_file = hist_file },
               scroll = 0, total = 0, running = false, wake = uv.new_timer() }
  gate.sync(st)
  gate.install_approve(st)
  st.entries[1] = { role = "art", text = require("logo").art } -- the mascot, on launch
  bog.clear_ui = function()
    st.entries = { { role = "art", text = require("logo").art } }
    st.activity = {}
    st.pending = nil
    st.dirty = true
  end
  bog.copy_text = function(text)
    -- Best-effort: a front end that has a clipboard (studio) replaces this.
    st._copied = text
  end

  -- Make a collapsing fan-out visible. A sub-agent that dies (a bad key, an
  -- unreachable endpoint, a crash) is removed from the scheduler and the fleet
  -- count drops -- so without this a fleet that spawns three and instantly
  -- loses all three just reads as "0 agents", as if nothing happened. Surface
  -- the death, with its reason, as an error entry. The coordinator's own crash
  -- is the turn error (shown separately), so skip it here. Handlers run in a
  -- one-shot coroutine and must not yield -- appending an entry is pure Lua.
  local crash_sub = bog.events and bog.events.on and
    bog.events.on("swarm:actor_stopped", function(_, ev)
      if not ev or ev.reason ~= "crashed" or ev.id == st.coord.id then return end
      local why = (ev.detail and ev.detail ~= "") and (": " .. tostring(ev.detail)) or ""
      st.entries[#st.entries + 1] = { role = "error", text = "agent #" .. tostring(ev.id) .. " failed" .. why }
      st.dirty = true
    end)

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
        elseif ev.type == "paste" then
          st.box:paste(ev.text); draw(st)
        elseif ev.type == "mouse" then
          -- Wheel scrolls the transcript (64 = up, 65 = down).
          if ev.button == 64 then st.scroll = math.min(st.total, st.scroll + 3); draw(st)
          elseif ev.button == 65 then st.scroll = math.max(0, st.scroll - 3); draw(st) end
        elseif ev.type == "key" then
          if ev.key == "ctrl" and ev.char == "q" then quit = true; break end
          if gate.key(st, ev) then draw(st)
          elseif st.help then
            st.help = false; draw(st)
          elseif ev.key == "pageup" then
            st.scroll = math.min(st.total, st.scroll + page(st)); draw(st)
          elseif ev.key == "pagedown" then
            st.scroll = math.max(0, st.scroll - page(st)); draw(st)
          elseif ev.key == "ctrl" and ev.char == "o" then
            st.activity_max = (st.activity_max == 16) and ACTIVITY_LINES or 16
            draw(st)
          else
            local empty = (st.box.line or "") == ""
            if bog.choice and handle_choice_input(st, ev) then draw(st)
            elseif empty and ev.key == "char" and ev.char == "?" then
              st.help = true; draw(st)
            elseif empty and ev.key == "char" and ev.char == "{" then
              jump_user(st, -1); draw(st)
            elseif empty and ev.key == "char" and ev.char == "}" then
              jump_user(st, 1); draw(st)

            else
            local action, value = st.box:key(ev)
            st.eof_arm = (action == "eof") and not st.eof_arm
            if action == "eof" and not st.eof_arm then quit = true; break end
            if action == "eof" then draw(st)
            elseif action == "cancel" then
              -- Esc on an empty prompt no longer quits (Ctrl-D / Ctrl-Q do).
              st.help = false; draw(st)
            elseif action == "editor" then
              edit_in_editor(st); draw(st)
            elseif action == "submit" then
              if bog.choice and handle_choice_input(st, { type = "key", key = "enter" }) then
                -- pending after-turn menu: Enter submits a typed answer
              else
              local p = take.parse(value)
              if p.kind == "slash" then
                local s = slash(st, p.line)
                if s == "quit" then quit = true; break
                elseif type(s) == "table" and s.run then
                  local reply = run_turn(st, s.run)
                  while reply do reply = run_turn(st, reply) end
                end
              elseif p.kind == "bash" then
                st.entries[#st.entries + 1] = { role = "user", text = "!" .. p.command }
                local okb, out = take.run_bash(p.command)
                st.entries[#st.entries + 1] = {
                  role = okb and "system" or "error", text = out }
              elseif p.kind == "prompt" then
                note_mentions(st, p.notes)
                local reply = run_turn(st, p.text)
                while reply do reply = run_turn(st, reply) end
              elseif bog.api.incomplete_turn and bog.api.incomplete_turn(st.coord.session) then
                local reply = run_turn(st, nil)
                while reply do reply = run_turn(st, reply) end
              end
              end
              gate.sync(st)
              draw(st)
            else
              if action ~= "eof" then st.eof_arm = nil end
              draw(st)
            end
            end
          end
        end
        ev = tc.poll(0)
      end
      if quit then break end
      uv.run("once") -- sleep until a keypress (or leftover loop handle) wakes us
    end
  end)

  bog.choice_ui, bog.choice = nil, nil            -- no async chooser once we leave
  bog.log_tool, bog.log = saved_log_tool, saved_log -- restore before leaving the alt screen
  bog.clear_ui, bog.copy_text, bog.approve = nil, nil, nil
  if crash_sub and bog.events and bog.events.off then pcall(bog.events.off, crash_sub) end
  if st.wake then pcall(function() st.wake:stop(); st.wake:close() end) end
  tc.shutdown()
  if not ok then io.stderr:write("tui: ", tostring(err), "\n") end
  return true
end

return M
