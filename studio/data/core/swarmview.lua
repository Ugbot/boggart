-- swarmview.lua -- boggart's multi-agent mode, live, in the window.
--
-- The swarm is real and has always been headless: `boggart swarm` builds a
-- coordinator, the coordinator spawns sub-agents, they message each other over
-- the C bus (src/lswarm.c), and everything crossing it is journalled to
-- SQLite. The only view of it was lua/dash.lua, a curses dashboard for the
-- terminal. This is that information in the window, plus the two things a
-- terminal dashboard cannot reasonably offer: buttons, and a swarm you can
-- start without leaving the app.
--
-- THE EDITOR OWNS THE LOOP -- and here it owns it in the harder direction.
-- lua/dash.lua could leave the loop with the scheduler and paint one frame
-- from its should_stop hook. lite owns the process, so the inversion runs the
-- other way: update() calls bog.sched.step(false) once per frame, which
-- advances every actor by one slice, polls curl and libuv without waiting on
-- either, and returns. That non-blocking half of the scheduler is why
-- lua/sched.lua grew a `step` -- the CLI still calls step(true) and is still
-- allowed to sleep inside libuv, because nothing is drawing sixty times a
-- second behind it.
--
-- OBSERVATION, NOT PLUMBING. The roster's state model is lua/dash.lua's --
-- literally: that module is required and its records are reused. dash learns
-- what each agent is doing by wrapping three bog.* entry points and
-- attributing every chunk to whichever actor's coroutine is running; that
-- mechanism exists, is tested (tests/ltui.lua), and writing a second one would
-- guarantee the two views eventually disagreed about the same swarm. What is
-- not reused is dash's curses half: requiring it does not load ltui, and
-- nothing here touches its ltui plumbing or its stdout replay.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"
local widgets = require "core.widgets"

local dash = require "dash"

local SwarmView = View:extend()

-- One view per window. The swarm is process-global -- one bus, one scheduler,
-- one journal -- so a second view would be a second set of controls for the
-- same thing, and two update()s stepping the same scheduler would silently
-- double its rate.
local instance = nil

local JOURNAL_ROWS = 200   -- bus entries held in memory; only the tail is drawn
local WIDE_COLS    = 96    -- roster gets its full column set above this width
local SPLIT_COLS   = 116   -- ...and the lower pane splits into two columns
local TRANSCRIPT_LINES = 400

-- The scheduler's yield kinds, in words. lua/dash.lua maps them to the
-- three-letter forms a terminal row has space for; a window has space for the
-- sentence, and "io" meaning "parked on an HTTP request" is not guessable.
--
-- "waiting on approval" cannot occur today. Swarm agents are built by
-- lua/thread.lua, which installs no approval gate, and lua/sched.lua treats an
-- unrecognised yield as runnable -- so nothing ever reports it. It is listed
-- because that is the word the engine would report if a gate were added, and a
-- roster that rendered a blank for a real status would be worse than one that
-- is ready for it.
local STATE = {
  run      = { "running",             "good"    },
  io       = { "waiting on io",       "link"    },
  mail     = { "waiting on mail",     "warn"    },
  proc     = { "running a command",   "keyword" },
  approve  = { "waiting on approval", "warn"    },
  stopping = { "stopping",            "warn"    },
  paused   = { "paused",              "warn"    },
  stopped  = { "stopped",             "dim"     },
  done     = { "done",                "dim"     },
  err      = { "crashed",             "error"   },
  idle     = { "idle",                "dim"     },
  new      = { "new",                 "dim"     },
}

function SwarmView:new()
  SwarmView.super.new(self)
  self.hits = {}
  self.journal = {}        -- bus entries, oldest first (newest last on screen)
  self.transcripts = {}    -- id -> persisted transcript lines, for dead agents
  self.killed = {}         -- ids this view stopped, so they don't read "crashed"
  self.last_poll = 0
  self.running = false
  self.coord = nil
  self.selected = nil
  self.t0 = nil
end

function SwarmView:get_name()
  return self.running and "Swarm *" or "Swarm"
end

-- This view is the swarm's only frame loop. Closing it while a run is in
-- flight would leave the actors suspended with nobody to resume them and the
-- bog.* wrappers still installed over the chat panel's own turns -- so closing
-- stops the run. It is not a silent stop: the roster says so, right up until
-- the tab goes away.
function SwarmView:try_close(do_close)
  if self.running then self:stop() end
  if instance == self then instance = nil end
  do_close()
end

-- ---------------------------------------------------------------------------
-- The engine
-- ---------------------------------------------------------------------------

-- Swarm mode's own wiring. lua/boot.lua does this on its `swarm` branch only:
-- the studio boots as "embedded", which loads the harness and stops, so the
-- actor layer is not there until someone asks for it. Same modules and same
-- two calls as lua/swarmmode.run, deliberately -- if that list grows, this is
-- the file that has to grow with it.
function SwarmView:setup_engine()
  if self.engine then return end
  bog.sched       = bog.sched       or require("sched")
  bog.skills      = bog.skills      or require("skills")
  bog.agents      = bog.agents      or require("agents")
  bog.thread      = bog.thread      or require("thread")
  bog.tools_swarm = bog.tools_swarm or require("tools_swarm")
  -- Journal to the store's own connection and start the writer thread
  -- (src/jwriter.c). Both are idempotent; a second call is a no-op.
  swarm.attach(bog.db)
  self.engine = true
end

-- The swarm tools (spawn/await/send/publish/subscribe/inbox/threads) go into
-- the one process-global registry, and the chat panel offers the model every
-- tool in it. So they are added for the duration of a run and taken away
-- again: `boggart swarm` never has to think about this because it is its own
-- process, and a chat session that can silently spawn actors nobody is
-- scheduling is a bug, not a feature.
function SwarmView:tools_on()  bog.tools_swarm.register() end
function SwarmView:tools_off()
  for name in pairs(bog.tools_swarm.defs) do bog.tools.registry[name] = nil end
end

-- Attribution, exactly as lua/dash.lua does it: wrap the three places output
-- comes out of and ask the scheduler whose coroutine is running. bog.sched
-- .current() is nil outside a resume, which is what keeps the chat panel's own
-- turns out of the roster -- they are not actors and must not appear as any.
--
-- Installed before the coordinator is built, so thread.new_agent captures the
-- wrapped log_tool into every agent's opts.on_tool. (dash has to re-point the
-- coordinator's by hand precisely because it starts up after one exists.)
function SwarmView:observe_on()
  if self._orig_run_on then return end

  self._orig_run_on = bog.api.run_on
  bog.api.run_on = function(sess, text, on_text, opts)
    return self._orig_run_on(sess, text, function(s)
      local id = bog.sched.current()
      if id then dash.feed(id, s); core.redraw = true end
      if on_text then on_text(s) end
    end, opts)
  end

  self._orig_log = bog.log
  bog.log = function(msg)
    local id = bog.sched.current()
    if id then dash.emit(id, "* " .. tostring(msg)) end
    -- Still says it somewhere findable: bog.log writes to stderr, which in a
    -- windowed app goes to whatever terminal happened to launch it.
    core.log_quiet("swarm: %s", tostring(msg))
    core.redraw = true
  end

  self._orig_log_tool = bog.log_tool
  bog.log_tool = function(name, input)
    local id = bog.sched.current()
    if not id then return self._orig_log_tool(name, input) end
    local hint = ""
    if type(input) == "table" then
      local h = input.command or input.path or input.query or input.name or input.task
      if h then hint = ": " .. tostring(h):gsub("%s+", " "):sub(1, 90) end
    end
    local rec = dash.touch(id)
    rec.tools = (rec.tools or 0) + 1
    dash.emit(id, "> " .. tostring(name) .. hint)
    core.redraw = true
  end
end

function SwarmView:observe_off()
  if self._orig_run_on then bog.api.run_on = self._orig_run_on; self._orig_run_on = nil end
  if self._orig_log then bog.log = self._orig_log; self._orig_log = nil end
  if self._orig_log_tool then bog.log_tool = self._orig_log_tool; self._orig_log_tool = nil end
end

function SwarmView:note(text, bad)
  self.notice = { text = text, bad = bad }
  core.redraw = true
end

-- ---------------------------------------------------------------------------
-- Running a swarm
-- ---------------------------------------------------------------------------

function SwarmView:ask_task()
  if self.running then return end
  core.command_view:enter("Swarm task:", function(text)
    if text == "" then return end
    self:start(text)
  end, function() return {} end)
end

-- Start (or continue) a coordinator turn. This is lua/swarmmode.run_turn's
-- opening: build the coroutine, hand it to the scheduler, let it drain. The
-- draining is the part that cannot be borrowed -- run_turn calls sched.run,
-- which owns the loop until the swarm is finished, and a view that did that
-- would freeze the window for the length of the whole task.
function SwarmView:start(task)
  if self.running then return end
  local ok, err = core.try(function()
    self:setup_engine()
    self:tools_on()
    self:observe_on()

    if not self.coord then
      -- A fresh swarm gets a fresh roster: dash's records are module state and
      -- would otherwise still describe the previous run's agents.
      dash.agents, dash.order = {}, {}
      self.killed, self.transcripts = {}, {}
      self.coord = bog.thread.new_agent{
        agent = "coordinator", title = "coordinator", model = bog.session.model }
      bog.swarm_root = self.coord
      local rec = dash.touch(self.coord.id)
      rec.kind, rec.kind_locked = "coordinator", true
      -- The thread title doubles as the roster's "kind" column for spawned
      -- agents, so the coordinator's is pinned above and the row is titled
      -- with the task instead -- same as run_turn's first-turn rename.
      bog.store.thread_save(self.coord.id,
        { title = task:gsub("%s+", " "):sub(1, 60), status = "running" })
    else
      bog.store.thread_set_status(self.coord.id, "running")
    end

    local coord = self.coord
    bog.sched.fatal, bog.sched.idle = nil, 0
    bog.sched.add(coord.id, coroutine.create(function()
      -- No sink: the run_on wrapper above already routes every chunk to the
      -- agent it belongs to.
      bog.api.run_on(coord.session, task, function() end, coord.opts)
    end))
  end)
  if not ok then
    self:observe_off()
    self:tools_off()
    self:note("could not start: " .. tostring(err):match("^[^\n]*"), true)
    return
  end
  self.running = true
  self.t0 = os.time()
  self.selected = self.selected or self.coord.id
  self:note("swarm running: " .. task:gsub("%s+", " "):sub(1, 60))
  self:refresh(true)
end

-- The run drained (or wedged, or hit a fatal condition). Persist the
-- coordinator the way run_turn does, and hand the globals back.
function SwarmView:finish(word)
  if not self.running then return end
  self.running = false
  if self.coord then
    pcall(bog.store.thread_save, self.coord.id,
      { messages = self.coord.session.messages, status = "idle" })
  end
  self:observe_off()
  self:tools_off()
  local fatal = bog.sched and bog.sched.fatal
  if fatal then
    self:note(tostring(fatal), true)
  else
    self:note(word or "swarm finished")
  end
  self:refresh(true)
end

-- Stop everything. There is no way to unwind a suspended coroutine in Lua, so
-- "stop" is the scheduler forgetting the actors: their frames are collected,
-- and any HTTP request already in flight is abandoned when curl next reports
-- it. The store rows say "error" because that is the truth -- those agents did
-- not finish -- while the roster says "stopped", because the view knows which
-- ones it stopped and "crashed" would be a lie.
function SwarmView:stop()
  if not self.running then return end
  for i = #bog.sched.actors, 1, -1 do
    local id = bog.sched.actors[i].id
    bog.sched.kill(id)
    self.killed[id] = true
    if not self.coord or id ~= self.coord.id then
      pcall(bog.store.thread_set_status, id, "error")
    end
  end
  self:finish("stopped")
end

function SwarmView:kill(id)
  if not (bog.sched and bog.sched.kill(id)) then return end
  self.killed[id] = true
  pcall(bog.store.thread_set_status, id, "error")
  self:note("killed agent " .. tostring(id))
  -- Killing the last actor (usually the coordinator) ends the run; nothing
  -- else would ever notice, because step() only returns false when it runs.
  if #bog.sched.actors == 0 then self:finish("stopped") end
end

function SwarmView:toggle_pause(id)
  local a = bog.sched and bog.sched.by_id and bog.sched.by_id[id]
  if not a then return end
  -- Read before the flip: `a` is the scheduler's own record, so asking it
  -- afterwards reports the state we just set and the message comes out
  -- inverted. (It did.)
  local was = a.paused
  bog.sched.pause(id, not was)
  self:note((was and "resumed " or "paused ") .. "agent " .. tostring(id))
end

-- ---------------------------------------------------------------------------
-- Polling
-- ---------------------------------------------------------------------------

-- The bus journal, and the thread rows behind the roster.
--
-- Once a second, not once a frame, for two reasons. It is a SQLite query, like
-- SidebarView's session list. And reading the journal means flushing first:
-- src/lswarm.c hands rows to the writer thread in src/jwriter.c, which batches
-- them into one transaction, so a message sent a millisecond ago may not be in
-- the table yet -- store.journal_list calls swarm.flush() for exactly that
-- reason, and that call waits on the writer's semaphore until the batch
-- commits. It is short, but it is a wait, and a wait has no business in a
-- frame that is drawn sixty times a second.
function SwarmView:refresh(force)
  local now = os.time()
  if not force and now == self.last_poll then return end
  self.last_poll = now

  local ok, rows = pcall(bog.store.journal_list, JOURNAL_ROWS)
  if ok and type(rows) == "table" then
    -- journal_list is newest-first (ORDER BY id DESC); the pane reads like a
    -- log, so reverse it once here rather than counting backwards when drawing.
    local out = {}
    for i = #rows, 1, -1 do out[#out + 1] = rows[i] end
    self.journal = out
  end
end

function SwarmView:update()
  if self.running then
    -- One slice of the whole swarm. step(false) never waits: it polls curl and
    -- libuv, resumes whoever can run, and comes back.
    local ok, alive = pcall(bog.sched.step, false)
    if not ok then
      self:note("scheduler: " .. tostring(alive):match("^[^\n]*"), true)
      self:finish("stopped after a scheduler error")
    elseif not alive then
      self:finish()
    end
    core.redraw = true
  end
  -- Cheap: it walks the actor list, and its own store poll is already limited
  -- to once a wall second (dash.observe's _polled guard). A new actor's kind
  -- and model only exist in its thread row, though, so when the roster grows
  -- we clear that guard and let it read once now -- otherwise a freshly
  -- spawned agent sits there as an anonymous "agent  ?" for up to a second,
  -- which is exactly the second you are watching it.
  if self.engine then
    if #dash.order ~= self._seen_n then
      self._seen_n = #dash.order
      dash._polled = nil
    end
    pcall(dash.observe, os.time())
    self:refresh()   -- nothing has ever been on the bus until the engine exists
  end
  SwarmView.super.update(self)
end

-- ---------------------------------------------------------------------------
-- What a row says
-- ---------------------------------------------------------------------------

function SwarmView:state_of(rec)
  if self.killed[rec.id] then return "stopped" end
  local a = bog.sched and bog.sched.by_id and bog.sched.by_id[rec.id]
  if a and a.paused then return "paused" end
  return dash.status_word(rec)
end

local function state_word(s)
  local e = STATE[s]
  return e and e[1] or s, style[(e and e[2]) or "text"] or style.text
end

function SwarmView:records()
  local out = {}
  for _, id in ipairs(dash.order) do
    local rec = dash.agents[id]
    if rec then out[#out + 1] = rec end
  end
  return out
end

function SwarmView:selected_record()
  for _, rec in ipairs(self:records()) do
    if rec.id == self.selected then return rec end
  end
end

-- What a dead agent said, from the store. Live agents never come through here:
-- their output is in dash's record, streamed. This is for the ones that
-- finished (lua/thread._run persists the transcript on the way out) and for
-- anything left over from an earlier run.
function SwarmView:transcript(id)
  local cached = self.transcripts[id]
  if cached then return cached end
  local out = {}
  local ok, t = pcall(bog.store.thread_load, id)
  if ok and t then
    for _, m in ipairs(t.messages or {}) do
      local c = m.content
      if type(c) == "string" then
        for _, l in ipairs(dash.lines_of(dash.strip(c))) do out[#out + 1] = l end
      elseif type(c) == "table" then
        for _, b in ipairs(c) do
          if type(b) == "table" then
            if b.type == "text" and (b.text or ""):match("%S") then
              for _, l in ipairs(dash.lines_of(dash.strip(b.text))) do out[#out + 1] = l end
            elseif b.type == "tool_use" then
              out[#out + 1] = "> " .. tostring(b.name or "?")
            end
          end
        end
      end
      while #out > TRANSCRIPT_LINES do table.remove(out, 1) end
    end
  end
  if #out > 0 then self.transcripts[id] = out end
  return out
end

-- ---------------------------------------------------------------------------
-- Mouse and keys
-- ---------------------------------------------------------------------------
--
-- The hit rects are rebuilt by draw() every frame and tested here, the same
-- contract AgentView uses: two copies of a layout drift apart the first time
-- one of them is edited.

function SwarmView:on_mouse_moved(x, y, dx, dy)
  SwarmView.super.on_mouse_moved(self, x, y, dx, dy)
  local was = self.hover
  self.mouse = { x = x, y = y }
  local item = widgets.hit(self.hits, x, y)
  self.hover = item and (item.id or item.label) or nil
  if self.hover ~= was then core.redraw = true end
  self.cursor = "arrow"
end

function SwarmView:on_mouse_pressed(button, x, y, clicks)
  if SwarmView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  core.set_active_view(self)
  local item = widgets.hit(self.hits, x, y)
  if item then
    if item.action then item.action()
    elseif item.command then command.perform(item.command) end
  end
  return true
end

function SwarmView:select_delta(d)
  local recs = self:records()
  if #recs == 0 then return end
  local i = 1
  for k, rec in ipairs(recs) do if rec.id == self.selected then i = k end end
  self.selected = recs[common.clamp(i + d, 1, #recs)].id
  core.redraw = true
end

function SwarmView:on_key_pressed(key)
  if key == "up" then self:select_delta(-1); return true end
  if key == "down" then self:select_delta(1); return true end
  if key == "escape" and self.running then self:stop(); return true end
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------
--
-- Laid out in character columns, because style.code_font is monospace and
-- every pane here is a table. Same limitation lua/dash.lua has for the same
-- reason: a multi-byte character measures as its byte length, which is exact
-- for the ASCII this renders and slightly narrow for anything else.

local function cell(font, charw, x, y, col, text, colour, width)
  if width then text = dash.clip(text, width) end
  renderer.draw_text(font, text, x + col * charw, y, colour or style.text)
end

function SwarmView:toolbar_items()
  local items = {}
  if self.running then
    items[#items + 1] = { label = "Stop", tone = style.warn,
                          action = function() self:stop() end }
  else
    items[#items + 1] = { label = self.coord and "New task" or "Start swarm",
                          action = function() self:ask_task() end }
    if self.coord then
      items[#items + 1] = { label = "New swarm", action = function()
        self.coord, self.selected = nil, nil
        self:ask_task()
      end }
    end
  end
  items[#items + 1] = { label = (bog.session and bog.session.model) or "?",
                        command = "agent:set-model", dim = true }
  items[#items + 1] = { label = "Close", action = function()
    local node = core.root_view:get_primary_node()
    node:close_active_view(core.root_view.root_node)
  end }
  return items
end

function SwarmView:draw_roster(font, charw, x, y, lh, voff, cols, rows)
  local recs = self:records()
  local wide = cols >= WIDE_COLS
  -- Column starts, in characters. Two sets: the full table, and one that keeps
  -- id / agent / state / activity when the pane is narrow.
  local C = wide and { id = 1, kind = 6, state = 19, model = 40, time = 58, out = 65, act = 72 }
                  or { id = 1, kind = 6, state = 17, act = 38 }

  cell(font, charw, x, y + voff, C.id, "id", style.dim)
  cell(font, charw, x, y + voff, C.kind, "agent", style.dim)
  cell(font, charw, x, y + voff, C.state, "state", style.dim)
  if wide then
    cell(font, charw, x, y + voff, C.model, "model", style.dim)
    cell(font, charw, x, y + voff, C.time, "time", style.dim)
    cell(font, charw, x, y + voff, C.out, "out", style.dim)
  end
  cell(font, charw, x, y + voff, C.act, "activity", style.dim)
  y = y + lh

  if #recs == 0 then
    cell(font, charw, x, y + voff, C.id,
      self.engine and "(no agents yet)" or "(no swarm running -- Start swarm)", style.dim)
    return y + lh
  end

  -- Window the list around the selection when there are more agents than rows,
  -- so the one you are reading about cannot scroll out from under you.
  local start = 1
  if #recs > rows then
    local i = 1
    for k, rec in ipairs(recs) do if rec.id == self.selected then i = k end end
    start = common.clamp(i - rows // 2, 1, #recs - rows + 1)
  end

  local now = os.time()
  for n = 1, math.min(rows, #recs) do
    local rec = recs[start + n - 1]
    if not rec then break end
    local sel = rec.id == self.selected
    local hov = self.mouse and widgets.inside(
      { x = x, y = y, w = self.size.x - (x - self.position.x) * 2, h = lh },
      self.mouse.x, self.mouse.y)
    if sel or hov then
      renderer.draw_rect(x, y, self.size.x - (x - self.position.x) * 2, lh,
        sel and style.selection or style.line_highlight)
    end
    local word, colour = state_word(self:state_of(rec))
    local el = (rec.t_end or now) - (rec.t0 or now)
    -- style.dim is chosen to recede against style.background; on the selection
    -- fill it recedes all the way out of legibility, so the secondary columns
    -- step up a shade on the row you are actually reading.
    local quiet = sel and style.text or style.dim
    if sel and colour == style.dim then colour = style.text end
    cell(font, charw, x, y + voff, C.id, tostring(rec.id), style.text, 4)
    cell(font, charw, x, y + voff, C.kind, rec.kind or "agent", style.accent,
         (C.state - C.kind) - 1)
    cell(font, charw, x, y + voff, C.state, word, colour,
         ((wide and C.model or C.act) - C.state) - 1)
    if wide then
      cell(font, charw, x, y + voff, C.model, rec.model or "?", quiet, 17)
      cell(font, charw, x, y + voff, C.time, dash.mmss(el), quiet, 6)
      cell(font, charw, x, y + voff, C.out, dash.human(rec.bytes), quiet, 6)
    end
    cell(font, charw, x, y + voff, C.act, dash.activity(rec), style.text, cols - C.act)
    local id = rec.id
    self.hits[#self.hits + 1] = {
      x = x, y = y, w = self.size.x - (x - self.position.x) * 2, h = lh,
      item = { id = "agent" .. id, action = function()
        self.selected = id
        core.redraw = true
      end },
    }
    y = y + lh
  end
  if #recs > rows then
    cell(font, charw, x, y + voff, 1,
      string.format("... %d more agent(s)", #recs - rows), style.dim)
    y = y + lh
  end
  return y
end

-- The bus. Journal rows carry the payload the C bus wrote, which the Lua layer
-- JSON-encodes, so the interesting part is one decode away; a row that will
-- not decode is shown raw rather than dropped.
function SwarmView:draw_journal(font, charw, x, y, lh, voff, cols, rows)
  cell(font, charw, x, y + voff, 0, "BUS", style.dim)
  y = y + lh
  local n = #self.journal
  if n == 0 then
    cell(font, charw, x, y + voff, 0, "(nothing on the bus yet)", style.dim)
    return
  end
  for i = math.max(1, n - rows + 1), n do
    local r = self.journal[i]
    local route = (r.from_id or 0) .. (r.to_id and ("->" .. r.to_id)
                  or (r.topic and (" #" .. r.topic) or ""))
    local text = r.payload or ""
    local ok, m = pcall(bog.json.decode, text)
    if ok and type(m) == "table" then
      text = tostring(m.text or m.kind or "")
      if m.kind == "result" then
        text = string.format("result%s: %s", m.ok == false and " [error]" or "",
          tostring(m.text or ""))
      end
    end
    text = dash.strip(text):gsub("%s+", " ")
    -- A row still waiting to be marked processed is a message in flight; dim
    -- is for the ones the receiving agent has already consumed.
    local colour = r.processed_at and style.dim or style.text
    cell(font, charw, x, y + voff, 0, os.date("%H:%M:%S", r.ts or 0), style.dim, 8)
    cell(font, charw, x, y + voff, 9, r.kind or "?", style.keyword, 10)
    cell(font, charw, x, y + voff, 20, route, style.accent, 10)
    cell(font, charw, x, y + voff, 31, text, colour, math.max(4, cols - 31))
    y = y + lh
  end
end

function SwarmView:draw_detail(font, charw, x, y, lh, voff, cols, rows)
  local rec = self:selected_record()
  if not rec then
    cell(font, charw, x, y + voff, 0, "AGENT", style.dim)
    cell(font, charw, x, y + lh + voff, 0,
      "(click an agent above to read what it is saying)", style.dim)
    return
  end

  local word = select(1, state_word(self:state_of(rec)))
  cell(font, charw, x, y + voff, 0, string.format(
    "AGENT %d  %s  %s%s  %s out  %d tool call%s", rec.id, rec.kind or "agent", word,
    rec.parent and ("  parent " .. rec.parent) or "", dash.human(rec.bytes),
    rec.tools or 0, (rec.tools or 0) == 1 and "" or "s"), style.dim, cols)
  y = y + lh

  -- Per-actor controls, and only the ones the engine actually has: pause and
  -- kill are lua/sched.lua's, and there is nothing here to approve because
  -- swarm agents have no approval gate (see STATE above).
  local a = bog.sched and bog.sched.by_id and bog.sched.by_id[rec.id]
  if a then
    local items = {
      { label = a.paused and "Resume" or "Pause",
        action = function() self:toggle_pause(rec.id) end },
      { label = "Kill", tone = style.error, action = function() self:kill(rec.id) end },
    }
    for _, hit in ipairs(widgets.row(font, items, x, y, self.mouse)) do
      self.hits[#self.hits + 1] = hit
    end
    y = y + widgets.height(font)
    rows = rows - math.ceil(widgets.height(font) / lh)
  end

  local src = rec.lines or {}
  if #src == 0 and (rec.partial or "") == "" then src = self:transcript(rec.id) end
  -- Only the last few source lines can survive the tail once wrapped, so wrap
  -- those rather than the whole scrollback.
  local tail = dash.tail(src, rows * 2 + 4)
  if rec.partial and rec.partial ~= "" then tail[#tail + 1] = rec.partial end
  local wrapped = {}
  for _, line in ipairs(tail) do
    for _, piece in ipairs(dash.wrap(line, cols)) do wrapped[#wrapped + 1] = piece end
  end
  if #wrapped == 0 then wrapped = { "(nothing yet)" } end
  for _, line in ipairs(dash.tail(wrapped, rows)) do
    local colour = style.text
    if line:sub(1, 2) == "> " then colour = style.keyword
    elseif line:sub(1, 2) == "* " then colour = style.dim end
    cell(font, charw, x, y + voff, 0, line, colour)
    y = y + lh
  end
end

-- Short forms for the totals bar, where "3 waiting on io" would crowd out
-- everything else.
local TALLY = {
  { "run", "running" }, { "io", "io" }, { "mail", "mail" },
  { "proc", "in a command" }, { "paused", "paused" }, { "stopped", "stopped" },
  { "done", "done" }, { "err", "crashed" },
}
local ALWAYS = { run = true, io = true, mail = true, done = true, err = true }

function SwarmView:draw_totals(font, charw, x, y, cols)
  local t = dash.totals()   -- the aggregates: how many, and how much came out
  -- The states are counted from the same state_of() the roster rows use, so
  -- the bar and the rows cannot disagree. dash.totals counts only the five it
  -- has words for, which is why a stopped swarm read "3 done, 1 crashed" under
  -- four rows that all said "stopped".
  local n = {}
  for _, rec in ipairs(self:records()) do
    local s = self:state_of(rec)
    n[s] = (n[s] or 0) + 1
  end
  local parts = { { string.format("%d agent%s", t.n, t.n == 1 and "" or "s"), style.text } }
  for _, e in ipairs(TALLY) do
    local c = n[e[1]] or 0
    if c > 0 or ALWAYS[e[1]] then
      local colour = select(2, state_word(e[1]))
      parts[#parts + 1] = { string.format("%d %s", c, e[2]),
                            c > 0 and colour or style.dim }
    end
  end
  parts[#parts + 1] = { dash.human(t.bytes) .. " out", style.dim }
  parts[#parts + 1] = { dash.mmss(self.t0
    and ((self.running and os.time() or self.last_poll) - self.t0) or 0), style.dim }
  local col = 0
  for _, p in ipairs(parts) do
    if col >= cols then break end
    cell(font, charw, x, y, col, p[1], p[2], cols - col)
    col = col + #p[1] + 2
  end
  -- The last thing that happened, in the space that is left. Clipped rather
  -- than allowed to run off the window: a message that leaves the frame is a
  -- message nobody can read the end of.
  if self.notice and col + 8 < cols then
    cell(font, charw, x, y, col + 1, self.notice.text,
      self.notice.bad and style.error or style.good, cols - col - 1)
  end
end

function SwarmView:draw()
  self:draw_background(style.background)
  local font = style.code_font
  local lh = font:get_height() * config.line_height
  local voff = (lh - font:get_height()) / 2
  local charw = font:get_width("0")
  local pad, vpad = style.padding.x, style.padding.y
  local bh = widgets.height(font)
  self.hits = {}

  -- ---- toolbar ------------------------------------------------------------
  local top = self.position.y
  local tb_h = bh + vpad * 2
  renderer.draw_rect(self.position.x, top, self.size.x, tb_h, style.background2)
  renderer.draw_rect(self.position.x, top + tb_h - 1, self.size.x, 1, style.divider)
  local endx = self.position.x + pad
  for _, hit in ipairs(widgets.row(font, self:toolbar_items(),
      self.position.x + pad, top + vpad, self.mouse)) do
    self.hits[#self.hits + 1] = hit
    endx = math.max(endx, hit.x + hit.w)
  end
  -- What this swarm can spawn, stated rather than offered: nothing here is
  -- pressable because there is nothing to press -- the coordinator decides
  -- what to spawn, not the person watching.
  local names = bog.agents and table.concat(bog.agents.list(), " ")
  if names then
    endx = endx + pad
    local room = math.floor((self.position.x + self.size.x - pad - endx) / charw)
    renderer.draw_text(font, dash.clip("spawns: " .. names, room), endx,
      top + vpad + (bh - font:get_height()) / 2, style.dim)
  end

  -- ---- totals bar ---------------------------------------------------------
  local sb_h = lh + vpad
  local sb_y = self.position.y + self.size.y - sb_h
  renderer.draw_rect(self.position.x, sb_y, self.size.x, sb_h, style.background2)
  renderer.draw_rect(self.position.x, sb_y, self.size.x, 1, style.divider)
  local x = self.position.x + pad
  local w = self.size.x - pad * 2
  local cols = math.max(20, math.floor(w / charw))
  self:draw_totals(font, charw, x, sb_y + vpad / 2 + voff, cols)
  local body_y = top + tb_h + vpad
  local body_h = math.max(lh * 3, sb_y - body_y - vpad)

  -- ---- roster -------------------------------------------------------------
  -- Capped at just under half the body: the roster is the index, and the pane
  -- underneath is where the reading happens.
  local n = math.max(#dash.order, 1)
  local roster_rows = math.max(1, math.min(n, math.floor(body_h * 0.45 / lh) - 1))
  local y = self:draw_roster(font, charw, x, body_y, lh, voff, cols, roster_rows)

  y = y + vpad / 2
  renderer.draw_rect(x, y, w, math.max(1, SCALE), style.divider)
  y = y + vpad

  -- ---- detail + bus -------------------------------------------------------
  -- Side by side when there is room for two readable columns, stacked when
  -- there is not. Nothing here scrolls: both panes show their tail, which is
  -- the part of a live log anyone is actually looking at.
  local pane_h = math.max(lh * 2, self.position.y + self.size.y - sb_h - vpad - y)
  local pane_rows = math.max(1, math.floor(pane_h / lh))
  if cols >= SPLIT_COLS then
    local left_cols = math.floor(cols * 0.55)
    local right_x = x + (left_cols + 2) * charw
    renderer.draw_rect(right_x - charw, y, math.max(1, SCALE), pane_h, style.divider)
    self:draw_detail(font, charw, x, y, lh, voff, left_cols - 1, pane_rows - 1)
    self:draw_journal(font, charw, right_x, y, lh, voff, cols - left_cols - 2, pane_rows - 1)
  else
    local half = math.max(1, pane_rows // 2)
    self:draw_detail(font, charw, x, y, lh, voff, cols, half - 1)
    self:draw_journal(font, charw, x, y + half * lh, lh, voff, cols,
      pane_rows - half - 1)
  end
end

function SwarmView.open()
  local node = core.root_view:get_primary_node()
  if instance and node:get_node_for_view(instance) then
    node:set_active_view(instance)
    core.set_active_view(instance)
    return instance
  end
  instance = SwarmView()
  node:add_view(instance)
  core.set_active_view(instance)
  return instance
end

function SwarmView.current() return instance end

command.add(nil, {
  ["swarm:open"] = function() SwarmView.open() end,
  ["swarm:start"] = function() SwarmView.open():ask_task() end,
  ["swarm:stop"] = function()
    if instance and instance.running then instance:stop()
    else core.log("no swarm running") end
  end,
})

return SwarmView
