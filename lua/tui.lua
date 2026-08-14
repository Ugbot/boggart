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
}

-- ---- painting helpers ------------------------------------------------------

local function blit(x, y, runs)
  for _, r in ipairs(runs or {}) do
    x = tc.puts(x, y, r.text or "", r.fg, r.bg, r.attr)
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
local function pane_width(st, w)
  if not (bog.sched and bog.sched.count and bog.sched.count() > 0) then return 0 end
  if not M._Agents then
    local ok, A = pcall(require, "tui.agents")
    M._Agents = ok and A or false
  end
  if not M._Agents then return 0 end
  return math.min(38, math.max(24, w // 3))
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
local function draw(st)
  local w, h = tc.size()
  if h < 3 or w < 8 then return end
  tc.clear()
  local body = h - 2

  local pw = pane_width(st, w)
  local tw = pw > 0 and (w - pw - 1) or w

  -- transcript, left column, pinned to newest unless scrolled up
  local lines = transcript_lines(st.entries, tw)
  st.total = #lines
  local top = math.max(0, #lines - body - st.scroll)
  for i = 0, body - 1 do
    local ln = lines[top + i + 1]
    if ln then blit(0, i, ln) end
  end

  -- agents pane, right column
  if pw > 0 then
    local dx = w - pw - 1
    for y = 0, body - 1 do tc.set(dx, y, 0x2502, C.divider, nil, nil) end -- vertical rule
    local ok, prunes = pcall(M._Agents.runs, agent_snapshot(st), { width = pw, height = body })
    if ok and prunes then
      for i, ln in ipairs(prunes) do
        if i > body then break end
        blit(dx + 1, i - 1, ln)
      end
    end
  end

  -- status row, then the input row with a block cursor
  fill_row(h - 2, w, C.bar_bg)
  blit(0, h - 2, status_runs(st))
  local iruns, cursor_col = st.box:runs(w)
  blit(0, h - 1, iruns)
  local cx = math.min(math.max(0, cursor_col or 0), w - 1)
  tc.set(cx, h - 1, 32, nil, C.cursor, nil)

  tc.flush()
end

-- ---- swarm setup + turns ---------------------------------------------------
-- The cTUI runs the agent layer the way swarm mode does: the scheduler and the
-- coordination tools loaded, the fanout cap raised so the chat may spawn a
-- fleet, and one coordinator agent whose session is the conversation.
local function setup_swarm()
  bog.sched = bog.sched or require("sched")
  bog.tools_swarm = bog.tools_swarm or require("tools_swarm")
  if swarm and swarm.attach then pcall(swarm.attach, bog.db) end
  pcall(bog.tools_swarm.register)
  bog.thread.max_agents = tonumber(os.getenv("BOGGART_MAX_AGENTS")) or 16
end

local function page(st) local _, h = tc.size(); return math.max(1, h - 3) end

-- Run one turn under the scheduler. The coordinator streams into a live entry;
-- the should_stop hook paints one frame per iteration and lets the user scroll
-- or interrupt (Ctrl-C) while the fleet works.
local function run_turn(st, text)
  st.entries[#st.entries + 1] = { role = "user", text = text }
  local e = { role = "assistant", text = "" }
  st.entries[#st.entries + 1] = e
  st.scroll, st.running, st.t0, st.abort = 0, true, os.time(), false

  local co = coroutine.create(function()
    bog.api.run_on(st.coord.session, text,
      function(chunk) e.text = e.text .. chunk end, st.coord.opts)
  end)
  bog.sched.add(st.coord.id, co)

  local ok, err = pcall(bog.sched.run, {
    should_stop = function()
      local ev = tc.poll(0)
      if ev.type == "key" then
        if ev.key == "ctrl" and ev.char == "c" then st.abort = true end
        if ev.key == "pageup" then st.scroll = st.scroll + page(st) end
        if ev.key == "pagedown" then st.scroll = math.max(0, st.scroll - page(st)) end
      end
      draw(st)
      return st.abort
    end,
  })

  if st.abort then
    for _, a in ipairs(bog.sched.actors) do pcall(bog.sched.kill, a.id) end
    st.entries[#st.entries + 1] = { role = "system", text = "(interrupted)" }
  elseif not ok then
    st.entries[#st.entries + 1] = { role = "error", text = tostring(err) }
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

  local ok0, coord = pcall(function()
    setup_swarm()
    return bog.thread.new_agent{ agent = "coordinator", title = "coordinator", model = bog.session.model }
  end)
  if not ok0 or not coord then tc.shutdown(); return false end
  bog.swarm_root = coord

  local st = { coord = coord, entries = {}, box = Input.new{}, scroll = 0,
               total = 0, running = false }

  local ok, err = pcall(function()
    draw(st)
    while true do
      local ev = tc.poll(100)
      if ev.type == "resize" then
        draw(st)
      elseif ev.type == "key" then
        if ev.key == "ctrl" and ev.char == "q" then break end
        if ev.key == "pageup" then
          st.scroll = math.min(st.total, st.scroll + page(st)); draw(st)
        elseif ev.key == "pagedown" then
          st.scroll = math.max(0, st.scroll - page(st)); draw(st)
        else
          local action, value = st.box:key(ev)
          if action == "cancel" then
            break
          elseif action == "submit" then
            if value and value:match("%S") then run_turn(st, value) end
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
