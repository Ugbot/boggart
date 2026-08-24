-- dash.lua -- an opt-in swarm dashboard drawn with the vendored ltui.
--
-- Shows every concurrent agent as a row (id / kind / state / elapsed / output
-- volume / a tail of what it just said or did), a detail pane for the selected
-- agent, and a totals bar. Enabled only for `boggart swarm --tui`; the REPL,
-- oneshot and --headless paths never touch it, so piping keeps working and
-- scrollback stays the transcript.
--
-- THE SCHEDULER OWNS THE LOOP. ltui's application:loop() wants to run the
-- process (getch, draw, napms, repeat), which would stall every agent's
-- in-flight HTTP the moment it blocked. So we never call it. Instead
-- dash.start() returns the opts table for lua/sched.lua's `run`, whose
-- should_stop hook fires once per scheduler iteration; that hook pumps ltui
-- input and paints exactly one frame, then returns false so the scheduler keeps
-- driving coroutines and http.pump(). One frame per scheduler turn, never the
-- other way round. sched.lua itself is untouched.
--
-- Getting the data out of the swarm without rewiring it: the dashboard observes
-- rather than being plumbed in. While it is up it wraps three `bog.*` entry
-- points (api.run_on's text sink, bog.log, bog.log_tool), attributing every
-- chunk to bog.sched.current() -- i.e. to the agent whose coroutine is running
-- -- and restores all three on stop. Scheduler state comes from
-- bog.sched.actors, agent kind/status from bog.store.thread_list().
--
-- ltui is loaded lazily (inside start) and via strict.without: all 32 ltui
-- modules do `local view = view or object()`, which strict.lua rejects. Nothing
-- here initialises curses at load time, so this module is inert under ctest.
local M = {}

M.MAXLINES = 400          -- per-agent scrollback kept in memory
M.MIN_COLS = 24           -- below this we decline to start (plain streaming)
M.MIN_LINES = 6

M.agents = {}             -- id -> record
M.order = {}              -- ids, in the order we first saw them

-- ---------------------------------------------------------------------------
-- Pure helpers. No terminal, no globals, no ltui -- unit-tested in tests/ltui.lua.
-- ---------------------------------------------------------------------------

-- Strip ANSI/OSC escapes and control characters; normalise CR and tabs.
function M.strip(s)
  s = tostring(s or "")
  s = s:gsub("\27%[[%d;?]*[%a]", "")          -- CSI ... final byte
  s = s:gsub("\27%][^\7\27]*[\7\27]?", "")    -- OSC ... BEL/ESC
  s = s:gsub("\27[%(%)][%w]", "")             -- charset selection
  s = s:gsub("\r\n", "\n"):gsub("\r", "\n")
  s = s:gsub("\t", "  ")
  s = s:gsub("[\1-\8\11\12\14-\31\127]", "")
  return s
end

-- True when byte b is a UTF-8 continuation byte (10xxxxxx).
local function is_cont(b) return b and b >= 0x80 and b < 0xC0 end

-- Widths here are terminal cells, not bytes and not characters.
--
-- This used to measure in bytes, which is exact for ASCII and wrong for
-- everything else in two directions at once: a three-byte CJK ideograph
-- counted as three cells when it occupies two, and an accented Latin letter
-- counted as two when it occupies one. Both under- or over-filled the row and
-- pushed the columns out of line. sys.width/sys.wtake carry the Unicode
-- East Asian Width table from C, so the terminal dashboard and the GUI now
-- measure the same way -- which matters, since a swarm can be watched through
-- either.
function M.clip(s, w)
  s = tostring(s or "")
  w = math.floor(w or 0)
  if w <= 0 then return "" end
  if sys.width(s) <= w then return s end
  if w <= 2 then return (sys.wtake(s, w)) end
  return (sys.wtake(s, w - 2)) .. ".."
end

-- Right-pad to exactly w cells (used so a highlighted row fills its line).
function M.pad(s, w)
  s = tostring(s or "")
  w = math.floor(w or 0)
  local n = sys.width(s)
  if n >= w then return s end
  return s .. string.rep(" ", w - n)
end

-- Split on newlines, keeping empty lines.
function M.lines_of(s)
  local out, from = {}, 1
  s = tostring(s or "")
  while true do
    local i = s:find("\n", from, true)
    if not i then break end
    out[#out + 1] = s:sub(from, i - 1)
    from = i + 1
  end
  out[#out + 1] = s:sub(from)
  return out
end

-- Hard-wrap text to w cells per line, on UTF-8 boundaries.
function M.wrap(s, w)
  w = math.floor(w or 0)
  if w < 1 then return { "" } end
  local out = {}
  for _, line in ipairs(M.lines_of(s)) do
    if line == "" then
      out[#out + 1] = ""
    else
      local rest = line
      while #rest > 0 do
        local head = sys.wtake(rest, w)
        if head == "" then
          -- A two-cell glyph asked to fit in a one-cell column. Emitting it
          -- overflows by one; emitting nothing loops forever. Overflow is the
          -- lesser problem, and a one-column pane is already lost.
          local i = 2
          while i <= #rest and is_cont(rest:byte(i)) do i = i + 1 end
          head = rest:sub(1, i - 1)
        end
        out[#out + 1] = head
        rest = rest:sub(#head + 1)
      end
    end
  end
  return out
end

-- Last n entries of a line array.
function M.tail(lines, n)
  local out = {}
  n = math.floor(n or 0)
  if n <= 0 then return out end
  for i = math.max(1, #lines - n + 1), #lines do out[#out + 1] = lines[i] end
  return out
end

function M.human(n)
  n = tonumber(n) or 0
  if n < 1024 then return string.format("%d", math.floor(n)) end
  if n < 1024 * 1024 then return string.format("%.1fk", n / 1024) end
  return string.format("%.1fM", n / (1024 * 1024))
end

function M.mmss(sec)
  sec = math.max(0, math.floor(tonumber(sec) or 0))
  if sec >= 3600 then
    return string.format("%d:%02d:%02d", sec // 3600, (sec % 3600) // 60, sec % 60)
  end
  return string.format("%02d:%02d", sec // 60, sec % 60)
end

-- Screen layout. Body occupies everything but the last row (the totals bar);
-- inside it: an optional header row, the agent roster, a divider, the detail
-- pane. Degrades by dropping the detail pane, then the header, as h shrinks.
function M.layout(w, h, n)
  n = math.max(1, math.floor(n or 1))
  local L = { w = w, h = h, compact = w < 60 }
  local body = math.max(1, h - 1)
  L.header = body >= 5 and 1 or 0
  local avail = body - L.header
  if avail < 1 then avail = body; L.header = 0 end
  if avail <= 4 then
    L.rows = math.min(n, avail)
    L.detail_h = 0
  else
    L.rows = math.max(1, math.min(n, avail - 4))  -- leave divider + >=3 detail
    L.detail_h = avail - L.rows - 1
  end
  L.roster_y = L.header
  if L.detail_h > 0 then
    L.divider_y = L.roster_y + L.rows
    L.detail_y = L.divider_y + 1
  end
  L.more = n - L.rows                              -- agents that did not fit
  return L
end

-- Scheduler/store state -> one short word.
--   runnable -> run, io -> io (waiting on http), recv -> mail (waiting on mail)
function M.status_word(rec)
  local s = rec.sched
  if s == "runnable" then return "run" end
  if s == "io" then return "io" end
  if s == "recv" then return "mail" end
  if s == "blocked" then return "wait" end   -- parked on an approval / chooser
  if s then return tostring(s) end
  if rec.db == "error" then return "err" end
  if rec.db == "idle" then return "idle" end
  return rec.seen_sched and "done" or "new"
end

local ATTR = {
  run = "green", io = "cyan", mail = "yellow",
  done = "white", err = "red", idle = "blue", new = "white",
}

function M.attr_for(status, selected)
  if selected then return "black onwhite" end
  return ATTR[status] or "white"
end

-- The most recent thing this agent said or did, as a single line.
function M.activity(rec)
  if rec.partial and rec.partial:match("%S") then
    return (rec.partial:gsub("%s+", " "))
  end
  local lines = rec.lines or {}
  for i = #lines, math.max(1, #lines - 16), -1 do
    if lines[i] and lines[i]:match("%S") then return (lines[i]:gsub("%s+", " ")) end
  end
  return ""
end

function M.header_text(w, compact)
  if compact then
    return M.pad(M.clip(string.format(" %3s %-4s %s", "id", "st", "activity"), w), w)
  end
  return M.pad(M.clip(string.format(" %4s %-11s %-5s %5s %6s  %s",
    "id", "kind", "state", "time", "out", "activity"), w), w)
end

-- One roster row.
function M.row(rec, w, selected, now, compact)
  local marker = selected and ">" or " "
  local st = M.status_word(rec)
  local el = (rec.t_end or now or rec.t0 or 0) - (rec.t0 or 0)
  local act = M.activity(rec)
  local head
  if compact then
    head = string.format("%s%3s %-4s ", marker, tostring(rec.id), st:sub(1, 4))
  else
    head = string.format("%s%4s %-11s %-5s %5s %6s  ", marker, tostring(rec.id),
      M.clip(rec.kind or "agent", 11), st, M.mmss(el), M.human(rec.bytes))
  end
  return M.pad(M.clip(head .. act, w), w)
end

function M.statusline(t, w, elapsed)
  local left = string.format(" %d agent%s  %d run  %d io  %d mail  %d done%s  %s out  %s",
    t.n, t.n == 1 and "" or "s", t.run, t.io, t.mail, t.done,
    t.err > 0 and ("  " .. t.err .. " err") or "", M.human(t.bytes), M.mmss(elapsed))
  local right = "q detach  up/down select "
  if w >= #left + #right + 1 then
    return left .. string.rep(" ", w - #left - #right) .. right
  end
  return M.pad(M.clip(left, w), w)
end

-- Aggregate counters. `list` defaults to the live agent records.
local COUNTED = { run = true, io = true, mail = true, done = true, err = true }
function M.totals(list)
  if not list then
    list = {}
    for _, id in ipairs(M.order) do list[#list + 1] = M.agents[id] end
  end
  local t = { n = 0, run = 0, io = 0, mail = 0, done = 0, err = 0, bytes = 0, tools = 0 }
  for _, rec in ipairs(list) do
    t.n = t.n + 1
    t.bytes = t.bytes + (rec.bytes or 0)
    t.tools = t.tools + (rec.tools or 0)
    local s = M.status_word(rec)
    if COUNTED[s] then t[s] = t[s] + 1 end
  end
  return t
end

function M.detail_text(rec, w, h)
  if not rec then return "(no agents yet)" end
  local head = string.format("agent %d  %s  %s%s  %s out  %d tool call%s",
    rec.id, rec.kind or "agent", M.status_word(rec),
    rec.parent and ("  parent " .. rec.parent) or "",
    M.human(rec.bytes), rec.tools or 0, (rec.tools or 0) == 1 and "" or "s")
  local out = { M.pad(M.clip(head, w), w) }
  if h <= 1 then return out[1] end
  -- only the last few source lines can possibly survive the tail
  local src = M.tail(rec.lines or {}, h * 2 + 4)
  if rec.partial and rec.partial ~= "" then src[#src + 1] = rec.partial end
  local wrapped = {}
  for _, l in ipairs(src) do
    for _, x in ipairs(M.wrap(l, w)) do wrapped[#wrapped + 1] = x end
  end
  for _, x in ipairs(M.tail(wrapped, h - 1)) do out[#out + 1] = x end
  return table.concat(out, "\n")
end

-- ---------------------------------------------------------------------------
-- Agent state (fed by the observation wrappers; still terminal-free)
-- ---------------------------------------------------------------------------

function M.touch(id, now)
  local rec = M.agents[id]
  if not rec then
    rec = { id = id, kind = "agent", lines = {}, partial = "", bytes = 0, tools = 0,
            t0 = now or os.time() }
    M.agents[id] = rec
    M.order[#M.order + 1] = id
    M._dirty = true
  end
  return rec
end

function M.addline(rec, line)
  local lines = rec.lines
  lines[#lines + 1] = line
  while #lines > M.MAXLINES do table.remove(lines, 1) end
end

-- Streaming model text: append, splitting into lines as they complete.
function M.feed(id, chunk)
  if id == nil then return end
  local rec = M.touch(id)
  rec.bytes = rec.bytes + #tostring(chunk or "")
  local buf = rec.partial .. M.strip(chunk)
  local from = 1
  while true do
    local i = buf:find("\n", from, true)
    if not i then break end
    M.addline(rec, buf:sub(from, i - 1))
    from = i + 1
  end
  rec.partial = buf:sub(from)
  if #rec.partial > 4096 then M.addline(rec, rec.partial); rec.partial = "" end
  M.sel_auto = id
  M._dirty = true
end

-- A complete one-off line (a log message, a tool call).
function M.emit(id, line)
  if id == nil then return end
  local rec = M.touch(id)
  if rec.partial ~= "" then M.addline(rec, rec.partial); rec.partial = "" end
  M.addline(rec, M.strip(line))
  M.sel_auto = id
  M._dirty = true
end

-- Refresh live state from the scheduler (free) and the store (>= 1s apart).
function M.observe(now)
  now = now or os.time()
  local live = {}
  if bog.sched and bog.sched.actors then
    for _, a in ipairs(bog.sched.actors) do
      live[a.id] = true
      local rec = M.touch(a.id, now)
      rec.sched = a.status
      rec.seen_sched = true
      rec.t_end = nil
    end
  end
  for _, id in ipairs(M.order) do
    local rec = M.agents[id]
    if not live[id] then
      if rec.sched then M._dirty = true end
      rec.sched = nil
      if rec.seen_sched and not rec.t_end then rec.t_end = now end
    end
  end
  if M._polled ~= now and bog.store then
    M._polled = now
    local ok, rows = pcall(bog.store.thread_list, true)
    if ok and type(rows) == "table" then
      for _, r in ipairs(rows) do
        local rec = M.agents[r.id]
        if rec then
          rec.db = r.status
          rec.parent = r.parent_id
          -- Not shown in a terminal row (there is no width for it), but an
          -- agent can be spawned with its own model, so the fact is worth
          -- carrying: studio's swarm view has a column for it.
          rec.model = r.model
          if not rec.kind_locked and r.title then rec.kind = M.kind_of(r.title) end
        end
      end
    end
  end
end

-- A spawned agent's thread title is its standard-agent name (thread.new_agent
-- defaults title to the agent spec), so it doubles as the "kind" column.
function M.kind_of(title)
  title = tostring(title or "")
  if bog.agents then
    for _, name in ipairs(bog.agents.list()) do
      if title == name then return name end
    end
  end
  if title:match("^[%w_%-]+$") and #title <= 11 then return title end
  return "agent"
end

function M.sel_index()
  local want = M.sel_manual or M.sel_auto
  for i, id in ipairs(M.order) do if id == want then return i end end
  return #M.order > 0 and #M.order or 1
end

function M.selected() return M.order[M.sel_index()] end

function M.select_delta(d)
  local n = #M.order
  if n == 0 then return end
  local i = math.max(1, math.min(n, M.sel_index() + d))
  M.sel_manual = M.order[i]
  M._dirty = true
end

-- ---------------------------------------------------------------------------
-- Opt-in
-- ---------------------------------------------------------------------------

-- `boggart swarm -- --tui`, or BOGGART_TUI=1. (The C argv parser silently drops
-- unrecognised leading-dash flags and only forwards what follows `--` into
-- boggart.args, so a bare `--tui` cannot reach Lua without a src/boggart.c
-- change -- see the note in the report/README.)
function M.wanted()
  -- `boggart swarm --tui`: parsed in src/boggart.c's configure() and handed
  -- over as a field, the same way --model and --resume are. Previously the C
  -- argv parser dropped unrecognised leading-dash flags on the floor, so the
  -- bare form could never reach Lua at all.
  if boggart.tui then return true end
  -- Still accepted: `boggart swarm -- --tui` (anything after -- lands in
  -- boggart.args) and the env var, which is handy for scripts and tests.
  for _, a in ipairs(boggart.args or {}) do
    if a == "--tui" or a == "-tui" or a == "tui" then return true end
  end
  local e = os.getenv("BOGGART_TUI")
  return e ~= nil and e ~= "" and e ~= "0" and e ~= "false"
end

function M.active() return M._live == true end

-- ---------------------------------------------------------------------------
-- Observation wrappers (installed only while the dashboard is up)
-- ---------------------------------------------------------------------------

function M._patch(root)
  M._orig_run_on = bog.api.run_on
  bog.api.run_on = function(sess, user_text, on_text, opts)
    return M._orig_run_on(sess, user_text, function(s)
      local id = bog.sched.current() or (sess and sess.id) or M.root_id
      M.feed(id, s)
      if M._live and id == M.root_id then
        -- the coordinator's sink is io.write; buffer it and replay to stdout on
        -- stop so the scrollback transcript survives the alternate screen
        M._root_raw[#M._root_raw + 1] = s
      else
        on_text(s)
      end
    end, opts)
  end

  M._orig_log = bog.log
  bog.log = function(msg)
    if not M._live then return M._orig_log(msg) end
    M._logs[#M._logs + 1] = msg
    while #M._logs > 200 do table.remove(M._logs, 1) end
    M.emit(bog.sched.current() or M.root_id, "* " .. tostring(msg))
  end

  M._orig_log_tool = bog.log_tool
  bog.log_tool = function(name, input)
    if not M._live then return M._orig_log_tool(name, input) end
    local preview = ""
    if type(input) == "table" then
      local hint = input.command or input.path or input.query or input.name or input.title
      if hint then preview = ": " .. tostring(hint) end
    end
    local id = bog.sched.current() or M.root_id
    local rec = M.touch(id)
    rec.tools = rec.tools + 1
    M.emit(id, "> " .. tostring(name) .. preview)
  end

  -- thread.new_agent captures bog.log_tool into rec.opts.on_tool at creation
  -- time, and the coordinator is built before we exist. Re-point it at the
  -- late-bound global so its tool calls do not print through the curses screen.
  if root and root.opts then
    M._root_on_tool = root.opts.on_tool
    root.opts.on_tool = function(n, i) return bog.log_tool(n, i) end
  end
end

function M._unpatch(root)
  if M._orig_run_on then bog.api.run_on = M._orig_run_on; M._orig_run_on = nil end
  if M._orig_log then bog.log = M._orig_log; M._orig_log = nil end
  if M._orig_log_tool then bog.log_tool = M._orig_log_tool; M._orig_log_tool = nil end
  if root and root.opts and M._root_on_tool then
    root.opts.on_tool = M._root_on_tool
    M._root_on_tool = nil
  end
end

-- Replay everything the dashboard swallowed, so piping/scrollback still get it.
function M._flush()
  if M._orig_log then return end -- unpatch must have run first
  for _, m in ipairs(M._logs) do bog.log(m) end
  M._logs = {}
  local out = table.concat(M._root_raw)
  M._root_raw = {}
  if out ~= "" then io.write(out); io.flush() end
end

-- ---------------------------------------------------------------------------
-- ltui plumbing
-- ---------------------------------------------------------------------------

local function build_app(ltui)
  local App = ltui.application()
  function App:init()
    ltui.application.init(self, "boggart-dash")
    self:background_set("black")
    self._BODY = ltui.panel:new("body",
      ltui.rect{0, 0, self:width(), math.max(1, self:height() - 1)})
    self._BODY:background_set("black")
    self:insert(self._BODY)
    self:insert(self:statusbar())
  end
  function App:body() return self._BODY end
  function App:on_resize()
    M.geometry(self)
    ltui.panel.on_resize(self)
  end
  return App
end

function M.mklabel(body, name, attr)
  local v = M.ltui.label:new(name, M.ltui.rect{0, 0, 1, 1})
  v:textattr_set(attr)
  body:insert(v)
  return v
end

-- Size/position every view for the current terminal. Called from App:on_resize
-- (before ltui.panel.on_resize, so children already have their new bounds).
function M.geometry(app)
  app = app or M.app
  if not app or not M.ltui then return end
  local rect = M.ltui.rect
  local w, h = app:width(), app:height()
  local L = M.layout(w, h, #M.order)
  M.L, M._geo_n = L, #M.order

  local body = app:body()
  body:bounds_set(rect{0, 0, w, math.max(1, h - 1)})
  app:statusbar():bounds_set(rect{0, math.max(0, h - 1), w, h})

  if L.header > 0 then
    M.header = M.header or M.mklabel(body, "header", "cyan")
    M.header:bounds_set(rect{0, 0, w, 1}); M.header:show(true)
  elseif M.header then
    M.header:show(false)
  end

  M.rowviews = M.rowviews or {}
  for i = 1, L.rows do
    M.rowviews[i] = M.rowviews[i] or M.mklabel(body, "row" .. i, "white")
    M.rowviews[i]:bounds_set(rect{0, L.roster_y + i - 1, w, L.roster_y + i})
    M.rowviews[i]:show(true)
  end
  for i = L.rows + 1, #M.rowviews do M.rowviews[i]:show(false) end

  if L.detail_h > 0 then
    M.divider = M.divider or M.mklabel(body, "divider", "blue")
    M.divider:bounds_set(rect{0, L.divider_y, w, L.divider_y + 1}); M.divider:show(true)
    M.detail = M.detail or M.mklabel(body, "detail", "white")
    M.detail:bounds_set(rect{0, L.detail_y, w, L.detail_y + L.detail_h}); M.detail:show(true)
  else
    if M.divider then M.divider:show(false) end
    if M.detail then M.detail:show(false) end
  end
  M._dirty = true
end

local function set_text(v, s) if v and v:text() ~= s then v:text_set(s) end end
local function set_attr(v, a) if v and v:textattr() ~= a then v:textattr_set(a) end end

function M.render(now)
  local L = M.L
  if not L or not M.app then return end
  local w = L.w
  set_text(M.header, M.header_text(w, L.compact))
  if M.divider then
    local more = L.more > 0 and (" " .. L.more .. " more agent(s) ") or ""
    set_text(M.divider, M.pad(M.clip(string.rep("-", math.max(0, w - #more)) .. more, w), w))
  end

  local sel = M.selected()
  local n, start = #M.order, 1
  if n > L.rows then
    start = math.max(1, math.min(M.sel_index() - (L.rows // 2), n - L.rows + 1))
  end
  for i = 1, L.rows do
    local v = M.rowviews[i]
    local rec = M.agents[M.order[start + i - 1] or -1]
    if rec then
      set_text(v, M.row(rec, w, rec.id == sel, now, L.compact))
      set_attr(v, M.attr_for(M.status_word(rec), rec.id == sel))
    else
      set_text(v, M.pad("", w))
      set_attr(v, "white")
    end
  end
  if M.detail and L.detail_h > 0 then
    set_text(M.detail, M.detail_text(M.agents[sel or -1], w, L.detail_h))
  end
  set_text(M.app:statusbar():info(),
    M.statusline(M.totals(), w, (now or os.time()) - (M.t0 or now or 0)))
end

-- Drain pending key events (getch is non-blocking: program:init sets nodelay).
function M.poll()
  local ltui = M.ltui
  for _ = 1, 8 do
    local e = M.app:event()
    if not e then return end
    if e.type == ltui.event.ev_keyboard then
      local k = e.key_name
      if k == "q" or k == "Q" or k == "Esc" or k == "CtrlC" then
        M.stop(); return
      elseif k == "Up" or k == "k" then M.select_delta(-1)
      elseif k == "Down" or k == "j" or k == "Tab" then M.select_delta(1)
      elseif k == "Home" then M.sel_manual = M.order[1]; M._dirty = true
      elseif k == "End" then M.sel_manual = M.order[#M.order]; M._dirty = true
      elseif k == "a" then M.sel_manual = nil; M._dirty = true -- back to auto-follow
      elseif k == "Resize" then
        M.app:bounds_set(ltui.rect{0, 0, ltui.curses.columns(), ltui.curses.lines()})
      elseif k == "Refresh" or k == "CtrlL" then
        M.app:invalidate(true)
      end
    end
  end
end

-- One frame. This is the scheduler's should_stop hook: it must never block and
-- must always return false, so lua/sched.lua stays in charge of when to stop.
function M.tick()
  if not M._live then return false end
  local ok, err = pcall(M._frame)
  if not ok then
    M.stop()
    bog.log("dash: " .. tostring(err) .. " (dashboard detached, output resumed)")
  end
  return false
end

function M._frame()
  M.poll()
  if not M._live then return end
  local now = os.time()
  if M._dirty or now ~= M._frame_second then
    M._frame_second = now
    M.observe(now)
    if #M.order ~= M._geo_n then M.app:invalidate(true) end
    if M.app:state("resize") then M.app:on_resize() end
    M.render(now)
    M._dirty = false
  end
  M.app:on_draw()
  if M.app:state("refresh") then M.app:on_refresh() end
end

-- Start the dashboard for one coordinator turn. Returns the opts table to hand
-- to bog.sched.run (or nil if the TUI could not start, in which case the caller
-- just streams to stdout as usual).
function M.start(root)
  if M._live then return M._opts end
  M._root = root
  M._logs, M._root_raw = {}, {}
  M.t0 = os.time()
  M.sel_manual, M.sel_auto = nil, nil
  M._geo_n, M._frame_second, M._polled = -1, nil, nil
  local ok, err = bog.try(M._start, root)
  if not ok then
    M._live = false
    M._unpatch(root)
    if M.app then pcall(function() M.app:exit() end); M.app = nil end
    bog.log("dash: could not start the TUI, streaming plainly instead: "
      .. (tostring(err):match("^[^\n]*") or "?"))
    return nil
  end
  return M._opts
end

function M._start(root)
  local strict = require("strict")
  M.ltui = M.ltui or strict.without(require, "ltui")
  local ltui = M.ltui
  M.App = M.App or build_app(ltui)
  M.app = M.App:new({})
  -- ltui busy-waits up to 400ms after a bare Esc, distinguishing it from an
  -- Alt-sequence. That loop runs inside our scheduler hook, so for that whole
  -- time no agent is resumed and no HTTP is pumped. 20ms is still ample to
  -- catch a real Alt-sequence, which arrives in one terminal read.
  M.app._esc_delay = 20
  if M.app:width() < M.MIN_COLS or M.app:height() < M.MIN_LINES then
    local w, h = M.app:width(), M.app:height()
    M.app:exit(); M.app = nil
    error(string.format("terminal too small (%dx%d)", w, h), 0)
  end
  M.app:statusbar():info():textattr_set("blue")

  M.root_id = root and root.id
  if M.root_id then
    local rec = M.touch(M.root_id)
    rec.kind, rec.kind_locked = "coordinator", true
  end

  M._live = true
  M._dirty = true
  M._patch(root)
  M._opts = { should_stop = function() return M.tick() end }
  M._frame()
end

-- Tear the dashboard down: last frame, leave curses, restore the wrappers, and
-- replay everything that was swallowed to stdout/stderr. Idempotent.
function M.stop()
  if not M._live then return end
  M._live = false
  pcall(function()
    M.render(os.time())
    M.app:on_draw()
    if M.app:state("refresh") then M.app:on_refresh() end
  end)
  pcall(function() M.app:exit() end)
  M.app, M.L = nil, nil
  M.rowviews, M.header, M.divider, M.detail = nil, nil, nil, nil
  M._unpatch(M._root)
  M._flush()
  M._root = nil
end

return M
