-- agentview.lua -- the agent panel.
--
-- A lite View that talks to boggart. The integration rests on one inversion,
-- the same one lua/dash.lua uses for the terminal dashboard: the editor owns
-- the frame loop and pumps the agent, never the other way round. lite calls
-- update() ~60 times a second; each call turns the agent's coroutine a little
-- and returns immediately. Nothing here blocks, so a model thinking for thirty
-- seconds cannot freeze the window.
--
-- The agent runs as a coroutine rather than a thread because boggart's
-- transport was already built to yield: api.stream_async yields ("io", req),
-- proc.run yields ("proc", handle). Resume it, it does a slice and yields, we
-- draw a frame. That is the whole trick, and it is why this needs no locks.
--
-- Approval works the same way. run_tool is a hook boggart already supports, so
-- a gated tool call simply yields ("approve") until the user decides, and the
-- turn continues from exactly where it stopped.
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"
local difflib = require "core.diff"
local marks = require "core.marks"
local command = require "core.command"
local widgets = require "core.widgets"
local tokenizer = require "core.tokenizer"
local syntax = require "core.syntax"

-- The interactive `choose` menu (lua/choose.lua): the agent can raise it
-- mid-turn and the tool PARKS the turn until a front end sets a decision. This
-- view is one such front end. Reachable because boggart's own lua modules are
-- on the require path (registered in C, bogembed) independently of lite's.
local choose = require "choose"
local perm = require "perm"
local complete = require "core.agentcomplete"
local mention = require "mention"
local take = require "take"
local keymap = require "core.keymap"

local AgentView = View:extend()

local ROLE = {
  user      = { prefix = "› ", color = "accent" },
  assistant = { prefix = "",   color = "text" },
  tool      = { prefix = "» ", color = "keyword" },
  diff      = { prefix = "",   color = "text" },
  error     = { prefix = "!! ", color = "error" },
  system    = { prefix = "·  ", color = "dim" },
  thinking  = { prefix = "",   color = "dim" },
}

-- Permission modes and the gated-tool list live in lua/perm.lua so a mode
-- means the same thing in the studio, the cTUI and any other front end.
AgentView.MODES = perm.MODES

function AgentView:new()
  AgentView.super.new(self)
  self.scrollable = true
  self.entries = {}
  self.busy = false
  self.co = nil
  self.status = "idle"
  self.approve_all = false     -- "always allow" for this session
  self.mode = perm.state().mode -- shared with /mode and the cTUI
  self.tool_policy = perm.state().tool_policy
  -- These are process-global hooks that boot.lua's /clear and copy call. Every
  -- AgentView construction used to overwrite them with closures over *its* self,
  -- so a second view left the first one's /clear pointing at a dead view (and
  -- vice versa). Bind late instead: resolve the live agent view (core.studio.view,
  -- kept current by the workspace switch) at call time.
  if bog then
    bog.copy_text = function(s) pcall(system.set_clipboard, s) end
    bog.clear_ui = function()
      local v = (core.studio and core.studio.view) or self
      v.entries = {}
      v:push("system", "conversation cleared")
    end
  end

  -- Mark and reload files ANY agent writes, not just the coordinator. The
  -- run_tool hook below only wraps this turn's own calls, so a spawned worker's
  -- write produced no mark and no reload -- the fleet's edits were the least
  -- reviewed. file:write/file:edit fire for every agent; relay them to the live
  -- view (subscribed once for the class). queue_dirty dedupes by path, so the
  -- coordinator's own writes -- which the hook also queues -- are not doubled.
  if bog and bog.events and not AgentView._file_hook then
    AgentView._file_hook = true
    local function relay(_, data)
      local v = core.studio and core.studio.view
      if v and data and data.path then v:note_file_write(data.path) end
    end
    pcall(bog.events.on, "file:write", relay)
    pcall(bog.events.on, "file:edit", relay)
  end
  self.pending = nil           -- { name, input, diff, path, decision }
  self.history, self.hpos = {}, 0
  self.docked = false
  self.mode_hit, self.model_hit = nil, nil
  self:_load_history()

  -- The composer's modal context, in the neovim sense -- distinct from
  -- self.mode above, which is the approval policy. "insert" is a text field
  -- (every key types, current behaviour); "normal" turns the whole panel into a
  -- viewport the shell's spine can browse with j/k/gg/G. Escape leaves insert,
  -- and i/a/o/c/: (or a click, or the send key) return to it.
  self.edit_mode = "insert"

  -- Input state: a line array plus a caret, so this behaves like a text field
  -- rather than a string you can only backspace through.
  self.lines, self.cy, self.cx = { "" }, 1, 1

  -- Announce an async chooser. With this set the `choose` tool parks the turn
  -- here (like the approval gate) and waits for a decision, instead of degrading
  -- to a text-only fallback. Only ever set it: clearing it would silently turn
  -- the menu back into prose the next time one is raised.
  if bog then bog.choice_ui = true end

  self:push("system", "boggart " .. (bog and bog.version or "?")
    .. "   model " .. self:model())
  self:push("system",
    "enter sends · !cmd runs a shell · shift+enter / ctrl+j newline · tab completes · /commands · esc cancels · shift+tab cycles approval · ? shortcuts")
  if bog and not self:has_creds() then
    -- Tag these so welcomeview can retract them once credentials arrive without
    -- matching on their English text (which drifts the moment the copy changes).
    self:push("system", "No credentials. Command palette: 'agent: set api key',",
      { hint = "no-creds" })
    self:push("system", "or 'agent: set endpoint' for a local server (ds4 on :8000).",
      { hint = "no-creds" })
  end
end

function AgentView:model()
  return (bog and bog.session and bog.session.model) or "?"
end

function AgentView:has_creds()
  local ok, has = pcall(function() return auth.has_key() or auth.base_url() end)
  return ok and has
end

function AgentView:get_name()
  -- ASCII, because the bundled fonts have no pause or bullet glyph and drew
  -- an empty box in the tab. Unicode *content* renders fine now -- there is a
  -- fallback chain for that -- but a label is chrome, and chrome should not
  -- depend on which fonts a machine happens to have.
  if self.pending then return "Agent [?]" end
  return self.busy and "Agent ..." or "Agent"
end

-- ---------------------------------------------------------------------------
-- Transcript
-- ---------------------------------------------------------------------------

function AgentView:push(role, text, extra)
  local e = { role = role, text = text or "" }
  if type(extra) == "table" then for k, v in pairs(extra) do e[k] = v end end
  self.entries[#self.entries + 1] = e
  self.scroll_to_end = true
  core.redraw = true
  return e
end

function AgentView:stream(chunk)
  local last = self.entries[#self.entries]
  if last and last.role == "assistant" and last.open then
    last.text = last.text .. chunk
  else
    self.entries[#self.entries + 1] = { role = "assistant", text = chunk, open = true }
  end
  self.scroll_to_end = true
  core.redraw = true
end

function AgentView:close_stream()
  local last = self.entries[#self.entries]
  if last then last.open = nil end
end

-- @-mentions: "explain @src/lauth.c" attaches the file. Expanded at send
-- time via lua/mention.lua so the cTUI and the studio attach the same files.
function AgentView:expand_mentions(text)
  local expanded, notes = mention.expand(text)
  for _, n in ipairs(notes) do
    if n.ok then
      self:push("system", string.format("attached %s (%d bytes)", n.path, n.bytes))
    else
      self:push("error", "no such file: " .. n.path)
    end
  end
  return expanded
end

-- Repaint the panel from a stored transcript.
--
-- Resuming a session restores the messages the model will see; without this
-- you get a panel that claims to have resumed and shows nothing, which is a
-- worse experience than not resuming at all. Tool results are truncated
-- because the point of scrollback is to remind you what happened, not to
-- replay a 200 KB file read.
local RESULT_PREVIEW = 400

local function brief(v)
  local s = type(v) == "table" and (v.command or v.path or v.pattern or v.file_path)
            or tostring(v)
  s = tostring(s or ""):gsub("%s+", " ")
  if #s > 120 then s = s:sub(1, 120) .. "..." end
  return s
end

function AgentView:repaint(messages)
  self.entries = {}
  for _, m in ipairs(messages or {}) do
    local c = m.content
    if type(c) == "string" then
      self:push(m.role == "user" and "user" or "assistant", c)
    elseif type(c) == "table" then
      for _, b in ipairs(c) do
        if type(b) ~= "table" then
          -- nothing to render
        elseif b.type == "text" then
          if (b.text or ""):match("%S") then
            self:push(m.role == "user" and "user" or "assistant", b.text)
          end
        elseif b.type == "thinking" then
          -- The model's reasoning (extended-thinking, or an OpenAI server's
          -- reasoning_content). It can run to paragraphs, so it lands collapsed
          -- -- a "thought" header you click to expand -- rather than burying the
          -- answer under the working.
          if (b.thinking or ""):match("%S") then
            self:push("thinking", b.thinking, { collapsed = true })
          end
        elseif b.type == "tool_use" then
          self:push("tool", (b.name or "?") .. " " .. brief(b.input), b.name)
        elseif b.type == "tool_result" then
          local text = b.content
          if type(text) == "table" then
            local parts = {}
            for _, blk in ipairs(text) do
              parts[#parts + 1] = type(blk) == "table" and (blk.text or "") or tostring(blk)
            end
            text = table.concat(parts, "\n")
          end
          text = tostring(text or "")
          if #text > RESULT_PREVIEW then
            text = text:sub(1, RESULT_PREVIEW)
              .. string.format("\n... (%d more bytes)", #text - RESULT_PREVIEW)
          end
          if text:match("%S") then self:push("system", text) end
        end
      end
    end
  end
  core.redraw = true
end

-- ---------------------------------------------------------------------------
-- Approval
-- ---------------------------------------------------------------------------

-- Build the record the UI shows and the coroutine waits on.
-- Diffs use the studio differ (patience); the mode/policy decision is perm's.
function AgentView:request_approval(name, input)
  local rec = perm.request(name, input)
  -- An edit whose `old` is not unique is left for the tool to refuse; parking
  -- a review of "we don't know what would change" is worse than letting it
  -- fail with the normal validation error.
  if (name == "write" or name == "edit") and rec.path and not rec.diff then
    return nil
  end
  return rec
end

-- What should happen when the model calls `name`: "allow", "ask" or "deny".
-- An explicit per-tool policy always wins over the mode, which is the point of
-- having one -- "manual approval, except never ask about read" is a reasonable
-- thing to want and a mode alone cannot express it.
function AgentView:policy_for(name)
  return perm.policy_for(name, self)
end

function AgentView:mode_label()
  return perm.mode_at(self.mode).label
end

function AgentView:set_mode(id)
  local found
  for _, m in ipairs(perm.MODES) do if m.id == id then found = m end end
  if not found then return false end
  perm.set_mode(id)
  self.mode = id
  self.approve_all = false   -- a mode change is an explicit re-decision
  perm.state().approve_all = false
  self:push("system", "mode: " .. found.label .. " -- " .. found.help)
  core.redraw = true
  return true
end

function AgentView:cycle_mode()
  return self:set_mode((perm.cycle(self.mode)))
end

function AgentView:decide(decision)
  if not self.pending then return end
  if decision == "always" then
    self.approve_all = true
    perm.state().approve_all = true
    self.pending.decision = "approve"
  else
    self.pending.decision = decision
  end
  core.redraw = true
end

-- ---------------------------------------------------------------------------
-- Running a turn
-- ---------------------------------------------------------------------------

function AgentView:submit(text)
  if self.busy or text == "" then return end
  if not bog or not bog.api then
    self:push("error", "the agent harness is not available in this build")
    return
  end
  self.history[#self.history + 1] = text
  self.hpos = 0
  self:_save_history()
  self:push("user", text)
  self.busy, self.status = true, "thinking"
  self.busy_since = system.get_time()
  self.tool_running = nil

  local fn = function()
    local extra = {}
    -- Same agent record the cTUI/REPL build: skills filter the tool set and
    -- agent_system lands in the prompt. Empty skills still means the whole
    -- registry, including studio-only drawing tools.
    if bog.thread and bog.thread.session_agent then
      local okag, rec = pcall(bog.thread.session_agent, bog.session)
      if okag and rec and rec.opts then extra = rec.opts end
    end
    local okrun, err = pcall(bog.api.run_on, bog.session, text,
      function(chunk) self:stream(chunk) end,
      {
        async = true,
        system = extra.system,
        checkpoint = extra.checkpoint,

        -- Chat-only withholds the schemas rather than only refusing the calls.
        -- Denying a tool the model can see invites it to keep trying; a model
        -- that was never offered one simply answers.
        tools = (self.mode == "chat") and function() return {} end or extra.tools,

        -- Compaction is not a silent event. Losing the earlier conversation
        -- without being told is how you end up puzzled that the agent forgot
        -- something you definitely said.
        on_compact = function()
          self:push("system", string.format(
            "context compacted (%d/%d tokens) -- earlier turns replaced by a summary",
            select(2, bog.api.context_fraction(bog.session)),
            bog.api.context_limit(bog.session)))
        end,

        on_tool = function(name, input)
          self.tool_running = name
          local hint = ""
          if type(input) == "table" then
            local h = input.command or input.path or input.query or input.name
            if h then hint = ": " .. tostring(h):gsub("%s+", " "):sub(1, 90) end
          end
          self:close_stream()
          -- Keep the entry: run_tool hangs the tool's OUTPUT on it the moment
          -- the call returns, so a live turn shows what happened, not just a name.
          self.live_tool = self:push("tool", name .. hint)
        end,

        -- The approval gate. Yielding here suspends the whole turn mid-tool,
        -- which is exactly right: nothing has happened yet, and resuming
        -- continues from the same place whichever way the user decides.
        run_tool = function(name, input)
          input = input or {}
          -- A swarm orchestration tool (spawn/await/send/...) needs the bus and
          -- journal actually attached; stand the engine up the first time one is
          -- used. Lazy on purpose: a turn that never spawns never pays for it.
          if core.studio and core.studio.is_swarm_tool
             and core.studio.is_swarm_tool(name) then
            core.studio.ensure_engine()
          end
          local policy = self:policy_for(name)
          if policy == "deny" then
            self:push("system", "blocked: " .. name)
            return "Tool error: [permission_error] the user's settings do not "
              .. "permit the " .. name .. " tool. Do not retry it; say what you "
              .. "would have done and ask."
          end
          if policy == "ask" then
            local rec = self:request_approval(name, input)
            if rec then
              -- Show the full diff at the DECISION point, not after. You should
              -- be able to read exactly what a write/edit will do before saying
              -- yes -- the core Cursor review loop. It used to be pushed only
              -- once approved, so you approved on the one-line summary and saw
              -- the change too late to stop it.
              if rec.diff and rec.path then
                self:push("diff", "", { diff = rec.diff, path = rec.path })
              end
              self.pending = rec
              self.status = "waiting for approval"
              while rec.decision == nil do coroutine.yield("approve") end
              self.pending = nil
              if rec.decision == "reject" then
                self:push("system", "rejected: " .. name)
                -- A tool error rather than a raised one: the model should see
                -- a refusal it can respond to, not a crashed turn.
                return "Tool error: [permission_error] the user rejected this "
                  .. name .. " call. Do not retry it; ask what to do instead."
              end
            end
          end
          -- What the file said before the tool touched it, so the marks can be
          -- a real diff rather than a guess. Captured here and not from `rec`
          -- because `rec` only exists when the call was gated: an approved-by-
          -- policy write deserves the same annotation as one you clicked.
          local was = (name == "write" or name == "edit") and input.path
            and bog.util.read_file(input.path) or nil

          -- pcall so a raising tool still records its error inline on the entry
          -- rather than vanishing into the harness's catch. The harness treats a
          -- returned "Tool error: ..." string exactly as it would a raise, so
          -- catching here changes nothing the model sees.
          local ok, out = pcall(bog.tools.run, name, input)
          if not ok then out = "Tool error: " .. tostring(out) end
          if self.live_tool then
            self.live_tool.output = type(out) == "string" and out or tostring(out)
            self.live_tool.tool_ok = not (type(out) == "string" and out:find("^Tool error:"))
            self.live_tool = nil
            core.redraw = true
          end
          if (name == "write" or name == "edit") and input.path then
            self:queue_dirty(input.path, was)
          end
          return out
        end,
      })
    self:close_stream()
    if not okrun then self:push("error", tostring(err)) end
    self.busy, self.status, self.pending = false, "idle", nil
    self.turn_id = nil
    if bog.save_session then pcall(bog.save_session) end
    self:maybe_capture_question()
    core.redraw = true
  end

  -- Swarm mode by default: run the turn as coordinator actor 0 in the shared
  -- scheduler. That is the whole integration -- while the scheduler resumes this
  -- coroutine, bog.sched.current() is the turn's id, so the swarm tools resolve
  -- "self" to it and anything it spawns is an actor the studio is already
  -- pumping. The turn's id is its session row's id (sessions and threads are one
  -- table), so a spawned child's result routes back to it over the bus.
  --
  -- tick() must then NOT resume this coroutine -- the studio's pump does, and
  -- resuming a coroutine the scheduler also resumes is an error. Registering it
  -- with the scheduler instead of storing it in self.co is what tells tick which
  -- world it is in.
  --
  -- Fallback: if the engine could not be set up (no store, a require failed), a
  -- turn still runs as a bare coroutine that tick() drives, exactly as before.
  -- A studio that cannot start a scheduler is still a chat window; it just
  -- cannot spawn.
  local id = (core.studio and core.studio.swarm_ok and bog.sched)
    and core.studio.ensure_session() or nil
  if id then
    self.turn_id = id
    self.co = nil
    bog.sched.fatal = nil
    bog.sched.add(id, coroutine.create(fn))
  else
    self.turn_id = nil
    self.co = coroutine.create(fn)
  end
end

-- One path for "send this", whether it came from the return key or the button.
-- The composer's own selection, from a shift-held anchor to the caret.
function AgentView:composer_selection()
  local a = self.sel_anchor
  if not a then return nil end
  local ay, ax, by, bx = a.cy, a.cx, self.cy, self.cx
  if ay > by or (ay == by and ax > bx) then ay, ax, by, bx = by, bx, ay, ax end
  if ay == by then return (self.lines[ay] or ""):sub(ax, bx - 1) end
  local parts = { (self.lines[ay] or ""):sub(ax) }
  for i = ay + 1, by - 1 do parts[#parts + 1] = self.lines[i] or "" end
  parts[#parts + 1] = (self.lines[by] or ""):sub(1, bx - 1)
  return table.concat(parts, "\n")
end

function AgentView:delete_composer_selection()
  local a = self.sel_anchor
  if not a then return false end
  local ay, ax, by, bx = a.cy, a.cx, self.cy, self.cx
  if ay > by or (ay == by and ax > bx) then ay, ax, by, bx = by, bx, ay, ax end
  local head = (self.lines[ay] or ""):sub(1, ax - 1)
  local tail = (self.lines[by] or ""):sub(bx)
  for _ = ay + 1, by do table.remove(self.lines, ay + 1) end
  self.lines[ay] = head .. tail
  self.cy, self.cx = ay, ax
  self.sel_anchor = nil
  core.redraw = true
  return true
end

function AgentView:maybe_capture_question()
  if not bog or bog.choice or self.busy then return end
  local rec = choose.capture_from_session(bog.session)
  if not rec then return end
  choose.present_after_turn(rec, function(decision, r)
    local reply = choose.format_user_reply(r, decision)
    if reply then self:submit(reply) end
  end)
end

function AgentView:send()
  -- A pending choose menu claims the composer: submitting text while it is up is
  -- the user's typed answer, handed to the parked turn via choose.decide, not a
  -- new turn (unless after_turn -- then it starts the next turn). Checked before
  -- the busy guard below, because the turn IS busy when parked inside the choose
  -- tool waiting on exactly this. The tool clears bog.choice and resumes on its
  -- own; we only deliver the text and clear input.
  if bog and bog.choice then
    local a = self:input_text():gsub("^%s+", ""):gsub("%s+$", "")
    if a ~= "" then
      choose.decide(bog.choice, { text = a })
      self:set_input("")
      core.redraw = true
    end
    return
  end
  if self.busy then return end
  local t = self:input_text():gsub("^%s+", ""):gsub("%s+$", "")
  if t == "" then return end
  self:set_input("")
  self:set_edit_mode("insert")   -- sending is composing; land ready to type again
  complete.dismiss(self)
  local p = take.parse(t)
  if p.kind == "slash" then
    self:run_slash(p.line)
    return
  end
  if p.kind == "bash" then
    self:push("user", "!" .. p.command)
    local okb, out = take.run_bash(p.command)
    self:push(okb and "system" or "error", out)
    return
  end
  for _, n in ipairs(p.notes or {}) do
    if n.ok then
      self:push("system", string.format("attached %s (%d bytes)", n.path, n.bytes))
    else
      self:push("error", "no such file: " .. n.path)
    end
  end
  self:submit(p.text)
end

-- Put `text` in the composer and send it, so recipes, automations and the
-- "@ file" picker share slash commands, @-mentions and history with typing
-- Enter. send() is the one door.
function AgentView:send_prompt(text)
  text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return end
  self:set_input(text)
  self:send()
end

-- Run a `/command` and capture io.write/print into a system transcript entry,
-- the same trick the cTUI uses so a cell-grid (or here, a GUI) is not shredded
-- by REPL output. Git, compact and /until yield; they run on a studio thread
-- so the SDL frame loop keeps pumping.
function AgentView:run_slash(line)
  local cmd = line:match("^/(%S+)")
  if cmd == "exit" or cmd == "quit" then
    self:push("system", "this is the studio -- close the window to quit")
    return
  end
  if not (bog and bog.handle_command) then
    self:push("system", "commands are unavailable")
    return
  end
  if self.busy then
    self:push("system", "busy -- cancel the turn first")
    return
  end
  local function body()
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
    if cmd == "new" or cmd == "clear" or cmd == "resume" or cmd == "until"
        or cmd == "react" or cmd == "compact" then
      self:repaint((bog.session and bog.session.messages) or {})
    end
    if out ~= "" then self:push("system", out) end
    if cmd == "mode" then
      self.mode = perm.state().mode
      self.approve_all = perm.state().approve_all
    end
    self.busy, self.status = false, "idle"
    if type(brk) == "table" and brk.run then self:submit(brk.run) end
  end
  -- Already on a studio thread: run here so sys.exec/compact can yield.
  -- Live frame loop: hop off the SDL thread. Headless tests stub add_thread
  -- as a no-op, so we detect that and run inline.
  if coroutine.isyieldable() then
    self.busy, self.status = true, "command"
    body()
    return
  end
  self.busy, self.status = true, "command"
  -- core.add_thread returns a truthy handle when it actually schedules; the
  -- headless test stub is a no-op that returns nil, so fall back to running
  -- inline. (Was a before/after count of core.threads -- same intent, but it
  -- broke the moment anything else touched the table between the two counts.)
  if core.add_thread(body) then return end
  self.busy, self.status = false, "idle"
  body()
end

function AgentView:cancel()
  if self.pending then self:decide("reject"); return end
  if not self.busy then return end
  -- A scheduler-driven turn is stopped by the scheduler forgetting its actors --
  -- there is no way to unwind a suspended coroutine in Lua, so anything already
  -- in flight (an HTTP request, a child process) is abandoned when it next
  -- reports. Every actor is reaped, not just the coordinator: in the studio the
  -- chat turn is the root of everything running, so a cancelled turn must take
  -- its sub-agents with it rather than leave workers running with nobody
  -- watching. The store rows read "error" because that is the truth -- those
  -- agents did not finish.
  if self.turn_id and bog.sched then
    for i = #bog.sched.actors, 1, -1 do
      local aid = bog.sched.actors[i].id
      bog.sched.kill(aid)
      if aid ~= self.turn_id then pcall(bog.store.thread_set_status, aid, "error") end
    end
    pcall(bog.store.thread_set_status, self.turn_id, "idle")
  end
  self.co, self.turn_id, self.busy, self.status = nil, nil, false, "idle"
  self.busy_since, self.tool_running = nil, nil
  self:close_stream()
  self:push("system", "cancelled")
end

-- Reload a buffer the agent just wrote, so you are never reading a stale file
-- while the agent works in it. Runs every frame from tick(), whichever world
-- the turn is in, because run_tool records the write and this retires it.
-- Record a file the agent just wrote so tick() can reload it. A queue, not a
-- single slot: the coordinator can land two writes in one scheduler slice, and
-- a lone slot dropped all but the last. A repeat write to the same path keeps
-- the earliest `was` (the pre-first-write text) so the marks describe the net
-- change, and reloads it once.
function AgentView:queue_dirty(path, was)
  self.dirty_queue = self.dirty_queue or {}
  for _, it in ipairs(self.dirty_queue) do
    if it.path == path then return end
  end
  self.dirty_queue[#self.dirty_queue + 1] = { path = path, was = was }
end

-- A file:write/file:edit event landed (possibly from a sub-agent). The buffer,
-- if open, still holds the pre-write text -- capture it now as the mark's
-- pre-image, since tick()'s reload_dirty will replace it shortly.
function AgentView:note_file_write(path)
  if not path then return end
  local abs = system.absolute_path(path) or path
  local was
  for _, d in ipairs(core.docs) do
    if d.filename and (system.absolute_path(d.filename) or d.filename) == abs then
      was = table.concat(d.lines)
      break
    end
  end
  self:queue_dirty(path, was)
end

function AgentView:reload_dirty()
  local q = self.dirty_queue
  if not q or #q == 0 then return end
  self.dirty_queue = {}
  for _, it in ipairs(q) do
    local path, was = it.path, it.was
    -- Match on the absolute path, not a substring: d.filename:find(path) reloaded
    -- "data.c" when the agent wrote "a.c" (one name contains the other).
    local abs = system.absolute_path(path) or path
    for _, d in ipairs(core.docs) do
      if d.filename and (system.absolute_path(d.filename) or d.filename) == abs
         and not d:is_dirty() then
        pcall(function() d:reload() end)
      end
    end
    -- Mark after the reload, never before: reloading replaces the buffer's lines
    -- outright, and marks laid down first would describe text just thrown away.
    if was then
      pcall(marks.from_edit, path, was, bog.util.read_file(path) or "",
        { path = path, tool = "agent" })
    end
  end
end

-- One slice of agent work per frame. Must always return quickly.
function AgentView:tick()
  -- Scheduler-driven turn (the default). The studio's pump resumes the
  -- coordinator actor, so tick only OBSERVES: it maps the actor's yield-state to
  -- a status word (the pump has no view to talk to) and does the dirty-file
  -- reload. It must never resume the coroutine -- that is the scheduler's job,
  -- and doing it here as well is the single error this whole design avoids.
  if self.turn_id then
    local a = bog.sched and bog.sched.by_id and bog.sched.by_id[self.turn_id]
    if a and not self.pending then
      if a.status == "io" then self.status = "streaming"
      elseif a.status == "proc" then self.status = "running a command"
      elseif a.status == "recv" then self.status = "waiting for sub-agents" end
    end
    -- Safety net. The coroutine body clears busy before it returns, so normally
    -- the actor is already gone by the time busy is false. If it instead
    -- crashed inside the scheduler (an uncaught error past the body's own
    -- pcall), the actor vanishes with busy still set; retire the turn rather
    -- than leave the panel wedged "thinking" with nothing running.
    if self.busy and not a
       and not (self.pending and self.pending.decision == nil) then
      self.busy, self.status, self.turn_id = false, "idle", nil
    end
    self:reload_dirty()
    return
  end

  -- Fallback turn: no scheduler, so tick drives the bare coroutine itself,
  -- exactly as the studio did before the swarm was unified.
  if not self.co then return end
  if coroutine.status(self.co) == "dead" then self.co = nil; return end
  -- While a decision is outstanding there is nothing to advance, and resuming
  -- would spin the coroutine at frame rate for no reason.
  if self.pending and self.pending.decision == nil then return end

  local ok, kind = coroutine.resume(self.co)
  if not ok then
    self:push("error", tostring(kind))
    self.co, self.busy, self.status = nil, false, "idle"
    return
  end

  if kind == "io" then
    self.status = "streaming"
    pcall(http.pump, 0)
  elseif kind == "proc" then
    self.status = "running a command"
    local okuv, uv = pcall(require, "uv")
    if okuv then pcall(uv.run, "nowait") end
  end

  self:reload_dirty()
end

function AgentView:get_target_size(axis)
  if axis ~= "x" then return nil end
  if not self.docked then return nil end
  if self.visible == false then return 0 end
  return config.chat_dock_size or (360 * SCALE)
end

function AgentView:update()
  if self.docked then
    local dest = self:get_target_size("x") or 0
    self.size.x = dest
    self.init_size = false
  end
  self:tick()
  -- One place that retires the progress state, rather than a clear beside
  -- every path that can end a turn -- there are several, and the one I missed
  -- left the widget's start time and the tool it was running set after the
  -- answer had arrived. Nothing draws them then, which is exactly why it would
  -- have gone unnoticed until something else read them.
  if not self.busy and (self.busy_since or self.tool_running) then
    self.busy_since, self.tool_running = nil, nil
  end
  -- A choose menu is born at the bottom of a transcript that may already be
  -- scrolled to the last message; nudge the follow once, on the transition, so
  -- the card the user has to act on is not below the fold. Only on the change,
  -- so scrolling up to read the conversation while it waits still sticks.
  local ch = (bog and bog.choice) or nil
  if ch and ch ~= self.saw_choice then self.scroll_to_end = true end
  self.saw_choice = ch
  if self.busy then core.redraw = true end
  AgentView.super.update(self)
end

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

function AgentView:input_text()
  return table.concat(self.lines, "\n")
end

function AgentView:set_input(s)
  self.lines = difflib.lines(s)
  if #self.lines == 0 then self.lines = { "" } end
  self.cy = #self.lines
  self.cx = #self.lines[self.cy] + 1
  complete.dismiss(self)
end

function AgentView:_hist_path()
  return (bog and bog.userdir or "") .. "/history"
end

function AgentView:_load_history()
  local f = io.open(self:_hist_path(), "r")
  if not f then return end
  for line in f:lines() do
    if line ~= "" then self.history[#self.history + 1] = line end
  end
  f:close()
end

function AgentView:_save_history()
  local h = self.history
  while #h > 200 do table.remove(h, 1) end
  local f = io.open(self:_hist_path(), "w")
  if not f then return end
  f:write(table.concat(h, "\n"))
  if #h > 0 then f:write("\n") end
  f:close()
end

function AgentView:jump_user(dir)
  local idxs = {}
  for i, e in ipairs(self.entries) do
    if e.role == "user" then idxs[#idxs + 1] = i end
  end
  if #idxs == 0 then return end
  local cur = self._user_i or (#idxs + (dir < 0 and 1 or 0))
  cur = math.max(1, math.min(#idxs, cur + dir))
  self._user_i = cur
  local e = self.entries[idxs[cur]]
  if e and e.content_y then
    self.scroll.to.y = math.max(0, e.content_y)
    self.scroll_to_end = false
    core.redraw = true
  end
end

-- Caret arithmetic. self.cx is a byte offset into the line -- the same index
-- string.sub wants -- but it must always sit on a character boundary.
function AgentView:prev_char(line, i)
  i = i - 1
  while i > 1 do
    local b = line:byte(i)
    if b < 0x80 or b >= 0xc0 then break end
    i = i - 1
  end
  return math.max(1, i)
end

function AgentView:next_char(line, i)
  local len = #line
  i = i + 1
  while i <= len do
    local b = line:byte(i)
    if b < 0x80 or b >= 0xc0 then break end
    i = i + 1
  end
  return math.min(i, len + 1)
end

-- Keep the caret inside the current line and on a boundary, after a move that
-- changed which line it is on.
function AgentView:clamp_caret()
  local l = self.lines[self.cy] or ""
  if self.cx > #l + 1 then self.cx = #l + 1 end
  if self.cx < 1 then self.cx = 1 end
  if self.cx <= #l then
    local b = l:byte(self.cx)
    if b >= 0x80 and b < 0xc0 then self.cx = self:prev_char(l, self.cx + 1) end
  end
end

-- Switch the composer's modal context. Kept separate from set_mode (approval)
-- on purpose: they share the word "mode" but nothing else, and folding them
-- would let a normal-mode toggle rewrite the approval policy.
function AgentView:set_edit_mode(m)
  if m ~= "insert" and m ~= "normal" then return end
  if self.edit_mode == m then return end
  self.edit_mode = m
  -- A one-line affordance in the status bar, the same place the leader menu
  -- announces itself. The border colour (draw()) carries it while you look at
  -- the panel; this carries it at the moment of the switch.
  if core.status_view and core.status_view.show_message then
    if m == "normal" then
      core.status_view:show_message("N", style.accent,
        "normal -- j/k scroll, gg/G ends, i/a/o/c or : to edit")
    else
      core.status_view:show_message("i", style.dim, "insert -- esc for normal mode")
    end
  end
  core.redraw = true
end

function AgentView:on_text_input(text)
  -- Normal mode: the composer is a viewport, not a field. A keystroke that means
  -- "start writing" (i/a/o/c, or : for a command) drops back to insert; the
  -- spine's motions (j/k/gg/G) are claimed before they reach here, and anything
  -- else is swallowed rather than typed into the draft.
  if self.edit_mode == "normal" then
    if text:match("^[iaoc:]$") then self:set_edit_mode("insert")
    elseif text == "{" then self:jump_user(-1)
    elseif text == "}" then self:jump_user(1)
    end
    return
  end
  -- Typing over a selection replaces it, which is what every text field does
  -- and therefore what fingers expect; without it the new text lands beside
  -- the highlighted text and the selection silently survives.
  if self.sel_anchor then self:delete_composer_selection() end
  local l = self.lines[self.cy]
  self.lines[self.cy] = l:sub(1, self.cx - 1) .. text .. l:sub(self.cx)
  self.cx = self.cx + #text
  complete.refresh(self)
  core.redraw = true
end

function AgentView:on_key_pressed(key)
  -- An outstanding approval owns the keyboard: nothing else can be typed
  -- while a destructive change is waiting on a yes or no.
  if self.pending and self.pending.decision == nil then
    if key == "a" or key == "y" or key == "return" then self:decide("approve"); return true end
    if key == "r" or key == "n" or key == "escape" then self:decide("reject"); return true end
    if key == "shift+a" then self:decide("always"); return true end
    return true
  end

  -- A pending choose menu takes letter keys and Escape the way the approval gate
  -- above takes yes/no -- but only when the composer is a viewport, not a
  -- half-typed draft: with text in it a letter IS that text, and Enter sends it
  -- as a typed answer (see send()). Escape always dismisses the menu. A key that
  -- matches no option falls through, so a non-option letter starts a typed reply.
  if bog and bog.choice then
    local rec = bog.choice
    if key == "escape" then
      choose.decide(rec, { cancel = true }); core.redraw = true; return true
    end
    if #key == 1 and (self.edit_mode == "normal" or self:input_text() == "") then
      local i = choose.index_for_key(rec, key)
      if i then
        choose.decide(rec, { index = i }); core.redraw = true; return true
      end
    end
  end

  -- Tab completion overlay (and Shift-Tab mode cycle when the menu is closed).
  -- Claimed before clipboard/history so a visible menu owns up/down/enter/esc.
  if complete.on_key(self, key) then core.redraw = true; return true end
  if key == "shift+tab" then
    self:cycle_mode()
    return true
  end

  -- ---- clipboard ---------------------------------------------------------
  --
  -- Copy takes the transcript selection when there is one and the composer's
  -- otherwise, which is what the eye expects: whatever is highlighted.
  if key == "ctrl+c" or key == "cmd+c" then
    local text = self:selected_text() or self:composer_selection()
    if text and text ~= "" then system.set_clipboard(text) end
    return true

  elseif key == "ctrl+x" or key == "cmd+x" then
    local text = self:composer_selection()
    if text and text ~= "" then
      system.set_clipboard(text)
      self:delete_composer_selection()
    end
    return true

  elseif key == "ctrl+v" or key == "cmd+v" then
    local text = system.get_clipboard()
    if text and text ~= "" then
      self:delete_composer_selection()
      -- Paste is multi-line more often than not -- a stack trace, a diff, a
      -- log. Splitting it into the composer's lines keeps the caret arithmetic
      -- and the height calculation honest; a newline left inside one line
      -- would render as a glyph and never wrap.
      local lines = {}
      for piece in (text:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = piece
      end
      if #lines > 0 and lines[#lines] == "" then table.remove(lines) end
      if #lines == 0 then return true end
      local cur = self.lines[self.cy] or ""
      local head, tail = cur:sub(1, self.cx - 1), cur:sub(self.cx)
      if #lines == 1 then
        self.lines[self.cy] = head .. lines[1] .. tail
        self.cx = #head + #lines[1] + 1
      else
        self.lines[self.cy] = head .. lines[1]
        for i = 2, #lines do
          table.insert(self.lines, self.cy + i - 1, lines[i])
        end
        self.cy = self.cy + #lines - 1
        self.lines[self.cy] = self.lines[self.cy] .. tail
        self.cx = #lines[#lines] + 1
      end
      self.sel_anchor = nil
      complete.refresh(self)
      core.redraw = true
    end
    return true

  elseif key == "ctrl+a" or key == "cmd+a" then
    -- One selection at a time. Two highlighted regions means copy has to guess
    -- which you meant, and it will guess wrong half the time.
    self:clear_selection()
    self.sel_anchor = { cy = 1, cx = 1 }
    self.cy = #self.lines
    self.cx = #(self.lines[self.cy] or "") + 1
    core.redraw = true
    return true

  elseif key == "escape" and (self.sel or self.sel_anchor) then
    self:clear_selection()
    self.sel_anchor = nil
    return true
  end

  if key == "return" then
    self:send()
    return true

  elseif key == "shift+return" or key == "ctrl+j" then
    local l = self.lines[self.cy]
    local rest = l:sub(self.cx)
    self.lines[self.cy] = l:sub(1, self.cx - 1)
    table.insert(self.lines, self.cy + 1, rest)
    self.cy, self.cx = self.cy + 1, 1
    core.redraw = true
    return true

  elseif key == "backspace" then
    if self.sel_anchor then self:delete_composer_selection(); return true end
    if self.cx > 1 then
      local l = self.lines[self.cy]
      local prev = self:prev_char(l, self.cx)
      self.lines[self.cy] = l:sub(1, prev - 1) .. l:sub(self.cx)
      self.cx = prev
    elseif self.cy > 1 then
      local prev = self.lines[self.cy - 1]
      self.cx = #prev + 1
      self.lines[self.cy - 1] = prev .. self.lines[self.cy]
      table.remove(self.lines, self.cy)
      self.cy = self.cy - 1
    end
    complete.refresh(self)
    core.redraw = true
    return true

  elseif key == "ctrl+backspace" or key == "alt+backspace" then
    -- The tail has to be taken before the caret moves. Reading l:sub(self.cx)
    -- after reassigning self.cx put the deleted word straight back: this key
    -- did nothing at all except walk the caret backwards, so a second press
    -- silently left the caret in the middle of the line.
    local l = self.lines[self.cy]
    local head = l:sub(1, self.cx - 1):gsub("%s*%S+%s*$", "")
    self.lines[self.cy] = head .. l:sub(self.cx)
    self.cx = #head + 1
    complete.refresh(self)
    core.redraw = true
    return true

  -- Shift+motion extends a keyboard selection in the composer. Without this the
  -- ONLY way to select was a mouse drag, so a keyboard user could never cmd+c /
  -- cmd+x typed text. The anchor drops on the first shift-move and is kept across
  -- further shift-moves; a plain motion (below) collapses it.
  elseif key == "shift+left" then
    self.sel_anchor = self.sel_anchor or { cy = self.cy, cx = self.cx }
    if self.cx > 1 then self.cx = self:prev_char(self.lines[self.cy], self.cx)
    elseif self.cy > 1 then self.cy = self.cy - 1; self.cx = #self.lines[self.cy] + 1 end
    core.redraw = true; return true

  elseif key == "shift+right" then
    self.sel_anchor = self.sel_anchor or { cy = self.cy, cx = self.cx }
    if self.cx <= #self.lines[self.cy] then self.cx = self:next_char(self.lines[self.cy], self.cx)
    elseif self.cy < #self.lines then self.cy = self.cy + 1; self.cx = 1 end
    core.redraw = true; return true

  elseif key == "shift+up" then
    self.sel_anchor = self.sel_anchor or { cy = self.cy, cx = self.cx }
    if self.cy > 1 then self.cy = self.cy - 1; self:clamp_caret() end
    core.redraw = true; return true

  elseif key == "shift+down" then
    self.sel_anchor = self.sel_anchor or { cy = self.cy, cx = self.cx }
    if self.cy < #self.lines then self.cy = self.cy + 1; self:clamp_caret() end
    core.redraw = true; return true

  elseif key == "shift+home" then
    self.sel_anchor = self.sel_anchor or { cy = self.cy, cx = self.cx }
    self.cx = 1; core.redraw = true; return true

  elseif key == "shift+end" then
    self.sel_anchor = self.sel_anchor or { cy = self.cy, cx = self.cx }
    self.cx = #self.lines[self.cy] + 1; core.redraw = true; return true

  -- Caret motion steps whole characters. Stepping bytes let the caret settle
  -- inside a codepoint, where backspace would delete half of one and the drawn
  -- line -- which splices the caret glyph in at that offset -- became invalid
  -- UTF-8 for the renderer. A plain motion also collapses any shift-selection.
  elseif key == "left" then
    self.sel_anchor = nil
    if self.cx > 1 then self.cx = self:prev_char(self.lines[self.cy], self.cx)
    elseif self.cy > 1 then self.cy = self.cy - 1; self.cx = #self.lines[self.cy] + 1 end
    core.redraw = true; return true

  elseif key == "right" then
    self.sel_anchor = nil
    if self.cx <= #self.lines[self.cy] then
      self.cx = self:next_char(self.lines[self.cy], self.cx)
    elseif self.cy < #self.lines then self.cy = self.cy + 1; self.cx = 1 end
    core.redraw = true; return true

  elseif key == "home" then
    self.sel_anchor = nil
    self.cx = 1; core.redraw = true; return true

  elseif key == "end" or key == "ctrl+e" then
    self.sel_anchor = nil
    self.cx = #self.lines[self.cy] + 1; core.redraw = true; return true

  elseif key == "ctrl+u" then
    self.lines[self.cy] = self.lines[self.cy]:sub(self.cx)
    self.cx = 1; core.redraw = true; return true

  -- History, but only from a single-line input, so up/down move the caret in a
  -- multi-line draft. They used to do nothing there at all -- the comment
  -- claimed the caret moved and no branch ever moved it, so a shift+enter draft
  -- could only be navigated with left and right.
  elseif key == "up" then
    if #self.lines > 1 then
      if self.cy > 1 then self.cy = self.cy - 1; self:clamp_caret() end
      core.redraw = true
      return true
    end
    if #self.history > 0 then
      self.hpos = math.min(self.hpos + 1, #self.history)
      self:set_input(self.history[#self.history - self.hpos + 1] or "")
    end
    return true

  elseif key == "down" then
    if #self.lines > 1 then
      if self.cy < #self.lines then self.cy = self.cy + 1; self:clamp_caret() end
      core.redraw = true
      return true
    end
    if self.hpos > 1 then
      self.hpos = self.hpos - 1
      self:set_input(self.history[#self.history - self.hpos + 1] or "")
    else
      self.hpos = 0; self:set_input("")
    end
    return true

  elseif key == "ctrl+g" then
    self:set_mode(self.mode == "auto" and "smart" or "auto")
    return true

  elseif key == "escape" then
    -- A turn in flight is what Escape cancels first (the system hint promises
    -- "esc cancels"). With nothing to interrupt -- the pending gate and any
    -- selection were handled above, and we are not busy -- Escape is instead the
    -- neovim "leave insert" gesture: drop into normal mode so the spine's
    -- motions can browse the transcript.
    if self.busy then self:cancel()
    else self:set_edit_mode("normal") end
    return true
  end
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Layout: markdown-ish, with real syntax highlighting inside fences
-- ---------------------------------------------------------------------------
--
-- The panel is where a coding agent's output actually lands, and most of that
-- output is code. lite already ships a tokenizer and a set of language
-- definitions, so highlighting a fenced block costs a table lookup rather than
-- a new dependency: map the fence's language onto a filename the syntax table
-- already recognises, then run the same tokenizer a DocView runs.
--
-- Everything here draws in style.code_font, which is monospace, so widths are
-- counted in grid cells. That is what makes wrapping a token row cheap.
--
-- Three measures have been tried here and only the third is right. Bytes came
-- first: "café" measured five cells wide, and a word too long for the column
-- was cut with string.sub at a byte offset, which lands in the middle of a
-- codepoint -- the renderer got a fragment starting with a continuation byte,
-- so a wrapped run of "é" grew a stray "À" at each break, and in C the decoder
-- produced a negative codepoint and indexed the glyphset array below zero.
--
-- Codepoints came second and fixed all of that, but a Japanese ideograph is
-- one codepoint and two cells. A paragraph of Japanese wrapped at 96 codepoints
-- drew 192 cells wide and ran off the right of the panel with no way to scroll
-- to it.
--
-- Cells are the third, and are what a monospace grid actually has. sys.width
-- and sys.wtake are C, over the Unicode tables in src/utf8width.h, so this
-- agrees with the renderer's own advances by construction rather than by two
-- pieces of code being kept in step by hand.
--
-- What is still not right, and is not fixable here: no grapheme clustering, so
-- a ZWJ emoji sequence measures as its parts and wraps as if it were several
-- characters; and no bidi, so Hebrew and Arabic wrap correctly by width while
-- being drawn in logical rather than visual order.

-- Display cells occupied by s, which is not #s (bytes) and not utf8.len(s)
-- (characters).
local function cols_of(s) return sys.width(s) end

-- Split s at n cells: the part that fits, the rest, and the cells that part
-- took.
--
-- The head comes back empty when the next character is two cells wide and only
-- one cell is left, and callers have to treat that as "start a new row" rather
-- than as "no progress" -- a loop that waits for a wide glyph to fit in one
-- cell does not end. See first_char for the case where there is no new row to
-- start either.
local function split(s, n)
  local head, w = sys.wtake(s, n)
  return head, s:sub(#head + 1), w
end

-- The first character of s whatever it costs. The escape hatch for a two-cell
-- glyph in a one-cell column: it overflows by a cell, which is visible, and
-- the alternative is a hang, which is not.
local function first_char(s)
  local i = 2
  while i <= #s do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xc0 then break end
    i = i + 1
  end
  return s:sub(1, i - 1)
end

-- Everything past the first n cells of s.
local function cdrop(s, n) return select(2, split(s, n)) end

-- A laid-out row's plain text, and the pieces selection needs from it. Rows
-- are lists of coloured tokens; the text is their concatenation, and every
-- measurement is in display cells because that is the unit the layout wrapped
-- in and the unit a column on screen corresponds to.
local function row_text(row)
  local parts = {}
  for _, t in ipairs(row or {}) do parts[#parts + 1] = t[2] end
  return table.concat(parts)
end

local function cell_len(str) return cols_of(str) end

-- s, from cell `from` up to cell `to` (or the end).
local function cell_slice(str, from, to)
  local rest = (from and from > 0) and cdrop(str, from) or str
  if not to then return rest end
  local take = to - (from or 0)
  if take <= 0 then return "" end
  return (split(rest, take))
end

local EXT = {
  lua = "lua", c = "c", h = "h", cpp = "cpp", cc = "cpp", ["c++"] = "cpp",
  py = "py", python = "py", js = "js", javascript = "js", jsx = "js",
  ts = "js", json = "json", sh = "sh", bash = "sh", zsh = "sh", shell = "sh",
  html = "html", xml = "xml", css = "css", md = "md", markdown = "md",
}

local function syntax_for(lang)
  if not lang or lang == "" then return nil end
  local ext = EXT[lang:lower()] or lang:lower():match("^%w+$")
  if not ext then return nil end
  local syn = syntax.get("code." .. ext)
  -- syntax.get falls back to a plain-text table rather than failing, and
  -- tokenizing with that is pure waste, so no patterns means no highlighter.
  if syn and syn.patterns and #syn.patterns > 0 then return syn end
  return nil
end

-- Break a coloured token row to fit `cols` cells, splitting between tokens
-- where possible and inside one only when a single token is too wide.
local function fit(tokens, cols)
  local rows, cur, used = {}, {}, 0
  for _, t in ipairs(tokens) do
    local col, text = t[1], t[2]
    while #text > 0 do
      if used >= cols then rows[#rows + 1] = cur; cur, used = {}, 0 end
      local room = cols - used
      local n = cols_of(text)
      if n <= room then
        cur[#cur + 1] = { col, text }; used = used + n; text = ""
      else
        local head, tail, w = split(text, room)
        if head == "" and used > 0 then
          -- A wide glyph with one cell left. The row is done; the next one
          -- has the whole column to offer it.
          rows[#rows + 1] = cur; cur, used = {}, 0
        else
          -- `used` becomes what was actually taken, not `cols`. Assuming the
          -- row filled exactly is what let a wide glyph left out of one row be
          -- accounted for as though it had been drawn in it.
          if head == "" then
            head = first_char(text)
            tail = text:sub(#head + 1)
            w = cols_of(head)
          end
          cur[#cur + 1] = { col, head }
          text, used = tail, used + w
        end
      end
    end
  end
  rows[#rows + 1] = cur
  return rows
end

-- ---- inline markdown -------------------------------------------------------
--
-- Models write markdown, so the panel reads markdown. Deliberately a scanner
-- rather than a parser: it finds the earliest of a handful of spans, emits it,
-- and continues. No nesting, no reference links, no tables. The failure mode of
-- a scanner is that unusual markup renders as its own source, which is exactly
-- what you want here -- the text is still there and still legible. The failure
-- mode of a half-finished parser is swallowed text.
--
-- Bold is drawn by stamping the glyphs twice a pixel apart. There is one
-- monospace font in this application and no bold cut of it, and faux-bold is
-- more honest than pretending emphasis does not exist.
local SPANS = {
  { pat = "`([^`]+)`",                    kind = "code"   },
  { pat = "%*%*([^*]+)%*%*",              kind = "bold"   },
  { pat = "__([^_]+)__",                  kind = "bold"   },
  { pat = "%[([^%]]+)%]%(([^)]+)%)",      kind = "link"   },
  { pat = "%*([^*]+)%*",                  kind = "italic" },
}

local function inline(text, base)
  local toks, i = {}, 1
  while i <= #text do
    local best
    for _, sp in ipairs(SPANS) do
      local s1, e1, cap = text:find(sp.pat, i)
      if s1 and (not best or s1 < best.s) then
        best = { s = s1, e = e1, cap = cap, kind = sp.kind }
      end
    end
    if not best then
      toks[#toks + 1] = { base, text:sub(i) }
      break
    end
    if best.s > i then toks[#toks + 1] = { base, text:sub(i, best.s - 1) } end
    if best.kind == "code" then
      toks[#toks + 1] = { style.inline_code or style.error, best.cap }
    elseif best.kind == "bold" then
      toks[#toks + 1] = { base, best.cap, bold = true }
    elseif best.kind == "italic" then
      toks[#toks + 1] = { style.dim, best.cap }
    else
      toks[#toks + 1] = { style.link or style.accent, best.cap, link = true }
    end
    i = best.e + 1
  end
  return toks
end

-- Word-wrap a coloured token row. Breaks at spaces where it can and inside a
-- token only when a single word is wider than the column.
-- `hang` is an optional {color, text} prefix: it leads the first wrapped row
-- and a blank indent of the same width leads continuations, so numbered and
-- lettered lists keep their marker in a column instead of wrapping into the
-- body. Matches termrender's wrap_runs hanging indent.
local function wrap_tokens(tokens, cols, hang)
  local hang_w = (hang and hang[2] and cols_of(hang[2])) or 0
  if hang_w >= cols then hang, hang_w = nil, 0 end
  local inner = math.max(1, cols - hang_w)
  local rows, cur, used = {}, {}, 0
  local function flush()
    if #cur > 0 then rows[#rows + 1] = cur; cur, used = {}, 0 end
  end
  for _, t in ipairs(tokens) do
    -- Whitespace-only tokens still occupy a column. Dropping them is what ate
    -- the space between an inline span and the word after it -- "**bounded**
    -- retry" rendered as "boundedretry", because the span ended the token and
    -- the next token began with the space that got skipped.
    if t[2] ~= "" and t[2]:match("^%s*$") then
      cur[#cur + 1] = { t[1], t[2] }
      used = used + cols_of(t[2])
    end
    for lead, chunk in t[2]:gmatch("(%s*)(%S+)") do
      -- Copied out of the loop variable: Lua 5.5 makes the control variable
      -- read-only, and this loop consumes it.
      local word = lead .. chunk
      local wlen = cols_of(word)
      if used + wlen > inner and used > 0 then
        flush()
        word = word:gsub("^%s+", "")   -- no leading space at the start of a row
        wlen = cols_of(word)
      end
      while wlen > inner do   -- a single word longer than the column
        local head, tail = split(word, inner)
        -- Only when the column is one cell wide and the character is two.
        -- Without it this loop takes nothing and runs forever.
        if head == "" then head = first_char(word); tail = word:sub(#head + 1) end
        cur[#cur + 1] = { t[1], head, bold = t.bold, link = t.link }
        rows[#rows + 1] = cur; cur, used = {}, 0
        word = tail; wlen = cols_of(word)
      end
      cur[#cur + 1] = { t[1], word, bold = t.bold, link = t.link }
      used = used + wlen
    end
    -- ...and the trailing whitespace, which gmatch never yields either. That
    -- is the space *before* the next span: "add a **bounded**" would otherwise
    -- come out as "add abounded".
    local tail = t[2]:match("%s+$")
    if tail and t[2]:match("%S") then
      cur[#cur + 1] = { t[1], tail }
      used = used + cols_of(tail)
    end
  end
  flush()
  if #rows == 0 then rows[1] = { { style.text, "" } } end
  if hang then
    local hung = {}
    for i, row in ipairs(rows) do
      local nr = {}
      if i == 1 then nr[1] = hang
      else nr[1] = { hang[1], string.rep(" ", hang_w) } end
      for j, tok in ipairs(row) do nr[#nr + 1] = tok end
      hung[i] = nr
    end
    rows = hung
  end
  return rows
end

-- Rows for one entry, cached against (cols, text). Keyed on the string itself
-- rather than its length: identical strings are the same object here, so the
-- comparison is a pointer test in the common case, and a rewritten entry of the
-- same length -- which a length key silently kept stale -- invalidates. Streams
-- append constantly, and re-laying-out a growing reply sixty times a second is
-- exactly what this cache exists to avoid.
function AgentView:layout(e, cols)
  local c = e._layout
  if c and c.cols == cols and c.text == e.text
     and c.out == e.output and c.collapsed == e.collapsed then return c.rows end

  -- Thinking collapses to a one-line "thought" header (click to expand): a
  -- model's reasoning can dwarf its answer, so it must not bury the reply, but
  -- it should still be there to read.
  if e.role == "thinking" then
    local rows = {}
    local words = select(2, (e.text or ""):gsub("%S+", ""))
    local head = e.collapsed and ("\u{25b8} thought (" .. words .. " words)") or "\u{25be} thought"
    for _, row in ipairs(wrap_tokens({ { style.dim, head } }, cols)) do
      row.thinking_head = true
      rows[#rows + 1] = row
    end
    if not e.collapsed then
      for line in ((e.text or "") .. "\n"):gmatch("(.-)\n") do
        for _, row in ipairs(wrap_tokens({ { style.dim, line } }, cols)) do
          rows[#rows + 1] = row
        end
      end
    end
    e._layout = { cols = cols, text = e.text, out = e.output, collapsed = e.collapsed, rows = rows }
    return rows
  end

  local r = ROLE[e.role] or ROLE.assistant
  local base = style[r.color] or style.text
  local text = e.text

  -- Incremental layout for the append-only common case: a streaming reply grows
  -- one chunk at a time, and re-tokenising + re-wrapping the whole entry every
  -- frame is O(n) per frame, O(n^2) over a long reply. Instead keep the rows for
  -- the text up to the last "safe" line boundary -- one where no code block is
  -- open, so no earlier row can still be mutated (the copy-button finalise) --
  -- and only lay out the growing tail past it. `inc.rows` is the very array we
  -- return, grown in place; `nrows`/`bytes` mark how far is finalised.
  local inc = e._inc
  if not (inc and inc.cols == cols and inc.role == e.role
          and inc.collapsed == e.collapsed and inc.base == base
          and #text >= inc.bytes and text:sub(1, inc.bytes) == inc.prefix) then
    inc = nil
  end

  local rows, startpos
  local in_code, syn, state, fence_len, first, code_lines, code_first
  if inc then
    rows = inc.rows
    for i = #rows, inc.nrows + 1, -1 do rows[i] = nil end   -- drop the stale tail
    in_code, syn, state = inc.in_code, inc.syn, inc.state
    fence_len, first = inc.fence_len, inc.first
    code_lines, code_first = inc.code_lines, inc.code_first
    startpos = inc.bytes + 1
  else
    rows = {}
    in_code, syn, state = false, nil, nil
    fence_len, first = 0, true
    -- Per code block: accumulate the raw lines and remember the first drawn row,
    -- so the draw loop can hang a "copy" button on the block (the defining
    -- affordance of a coding chat -- otherwise the only way to lift a snippet is
    -- a careful drag-select). Finalised onto the first row when the fence closes.
    code_lines, code_first = nil, nil
    startpos = 1
  end

  local commit_bytes = inc and inc.bytes or 0
  local commit_rows  = inc and inc.nrows or 0
  -- The finalised parser state at commit_bytes. Seeded from inc when resuming,
  -- else the initial state (bytes 0 -> first line still pending, first == true).
  local commit_state = inc or {
    in_code = false, syn = nil, state = nil, fence_len = 0,
    first = true, code_lines = nil, code_first = nil,
  }

  local pos = startpos
  while true do
    local nl = text:find("\n", pos, true)
    local terminated = nl ~= nil
    local line = text:sub(pos, terminated and nl - 1 or #text)
    local fence, lang = line:match("^%s*(```+)%s*([%w_+#%-]*)")
    -- A fence only closes one at least as long as the one that opened it,
    -- which is how a ````-fenced markdown block can contain a ``` block. Any
    -- fence closing any other ate the inner block's contents: they rendered as
    -- prose, with the markers gone and no sign anything had been dropped.
    if fence and (not in_code or #fence >= fence_len) then
      -- The fence is markup, not content. Every chat UI worth using shows the
      -- block, not the backticks that delimit it; a band behind the code says
      -- the same thing without spending three rows on punctuation.
      if in_code then
        in_code, syn, state, fence_len = false, nil, nil, 0
        -- Fence closed: finalise the block's copy text onto its first row.
        if code_first then code_first.copy_block = table.concat(code_lines or {}, "\n") end
        code_lines, code_first = nil, nil
      else
        in_code, syn, state, fence_len = true, syntax_for(lang), nil, #fence
        code_lines, code_first = {}, nil
      end
    elseif in_code and syn then
      -- The newline matters. Several of lite's patterns are anchored to it --
      -- Lua's line comment is "%-%-.-\n" -- because a DocView's lines keep
      -- their terminator. Tokenize without it and a trailing comment comes
      -- back as an operator followed by symbols.
      local res, next_state = tokenizer.tokenize(syn, line .. "\n", state)
      state = next_state
      local toks = {}
      for _, type, text in tokenizer.each_token(res) do
        text = text:gsub("\n$", "")
        if text ~= "" then toks[#toks + 1] = { style.syntax[type] or style.text, text } end
      end
      if #toks == 0 then toks[1] = { style.text, "" } end
      if code_lines then code_lines[#code_lines + 1] = line end
      for _, row in ipairs(fit(toks, cols)) do
        row.code = true
        if code_lines and not code_first then code_first = row end
        rows[#rows + 1] = row
      end
    elseif in_code then
      if code_lines then code_lines[#code_lines + 1] = line end
      for _, row in ipairs(fit({ { style.text, line } }, cols)) do
        row.code = true
        if code_lines and not code_first then code_first = row end
        rows[#rows + 1] = row
      end
    elseif line:match("^%s*[-*_][-*_ ]*$") and #line:gsub("%s", "") >= 3 then
      -- A horizontal rule, drawn as one.
      rows[#rows + 1] = { rule = true }
    else
      -- Block markup first: it decides the colour and the prefix. Then the
      -- rest of the line goes through the inline scanner.
      local col, bold, prefix = base, false, nil
      local body = line
      local hashes, htext = line:match("^(#+)%s+(.*)$")
      local quote = line:match("^%s*>%s?(.*)$")
      local ind, bullet = line:match("^(%s*)[-*+]%s+()")
      local numlead, numbody = line:match("^(%s*%d+[.)]%s+)(.*)$")
      local letlead, letbody = line:match("^(%s*%l[.)]%s+)(.*)$")

      if hashes then
        body, col, bold = htext, style.accent, true
      elseif quote then
        body, col = quote, style.dim
        prefix = { style.divider, "| " }
      elseif bullet then
        body = line:sub(bullet)
        prefix = { style.accent, ind .. "- " }
      elseif numlead then
        body = numbody
        prefix = { style.accent, numlead }
      elseif letlead then
        body = letbody
        prefix = { style.accent, letlead }
      end

      local toks = inline(body, col)
      if bold then for _, t in ipairs(toks) do t.bold = true end end
      local hang = prefix
      -- Role prefix (› etc.) only on the first wrapped row of the entry, and
      -- not mixed into a list hang -- lists already have their marker.
      local role_prefix = (first and r.prefix ~= "") and { col, r.prefix } or nil
      local wrap_hang = hang or role_prefix
      if hang and role_prefix then
        -- Keep the role glyph on the first list row by widening the hang.
        wrap_hang = { hang[1], role_prefix[2] .. hang[2] }
      end
      for _, row in ipairs(wrap_tokens(toks, cols, wrap_hang)) do rows[#rows + 1] = row end
      if hashes and #hashes <= 2 then rows[#rows + 1] = { rule = true, thin = true } end
    end
    first = false

    -- A completed line (real newline) with no open code block is a safe cut:
    -- every row so far is final. Snapshot the parser state and how far we got so
    -- the next frame resumes from here instead of re-parsing the whole entry.
    if terminated and not in_code then
      commit_bytes, commit_rows = nl, #rows
      commit_state = {
        in_code = in_code, syn = syn, state = state, fence_len = fence_len,
        first = first, code_lines = code_lines, code_first = code_first,
      }
    end
    if not terminated then break end
    pos = nl + 1
  end

  e._inc = {
    cols = cols, role = e.role, collapsed = e.collapsed, base = base,
    rows = rows, bytes = commit_bytes, nrows = commit_rows,
    prefix = text:sub(1, commit_bytes),
    in_code = commit_state.in_code, syn = commit_state.syn,
    state = commit_state.state, fence_len = commit_state.fence_len,
    first = commit_state.first,
    code_lines = commit_state.code_lines, code_first = commit_state.code_first,
  }

  -- Tool entries carry their result inline: the whole point of watching a turn
  -- is seeing what a call RETURNED, not just that it ran (and not only after a
  -- session resume). Rendered in the code band, monospace; capped so a huge log
  -- or file read can't flood the transcript, with a tail note of what was elided.
  -- Error output (a raised or "Tool error:" result) draws in the error colour.
  if e.role == "tool" and e.output and e.output ~= "" and not e.collapsed then
    local MAX = 24
    local out_col = (e.tool_ok == false) and style.error or style.dim
    local body = e.output:gsub("\r\n", "\n"):gsub("\n$", "")
    local total = 0
    for line in (body .. "\n"):gmatch("(.-)\n") do
      total = total + 1
      if total <= MAX then
        for _, row in ipairs(fit({ { out_col, line } }, cols)) do
          row.code = true
          rows[#rows + 1] = row
        end
      end
    end
    if total > MAX then
      for _, row in ipairs(fit({ { style.dim, ("  … +%d more lines"):format(total - MAX) } }, cols)) do
        rows[#rows + 1] = row
      end
    end
  end

  e._layout = { cols = cols, text = e.text, out = e.output, collapsed = e.collapsed, rows = rows }
  return rows
end

-- ---------------------------------------------------------------------------
-- Mouse
-- ---------------------------------------------------------------------------
--
-- The buttons' rects are rebuilt by draw() every frame and hit-tested here.
-- Recomputing them on click instead would mean duplicating the layout, and two
-- copies of a layout drift apart the first time one is edited.

-- ---- selecting text in the transcript --------------------------------------
--
-- The panel could not be selected from at all: a transcript you cannot copy an
-- error message out of is a transcript you end up retyping.
--
-- A position is (entry index, row within that entry, column), not a pixel or a
-- screen row. Screen rows move when the view scrolls or the window resizes, and
-- a selection anchored to one would slide off the text it was made on. Columns
-- are display cells, the same unit the layout wraps in, so a CJK character
-- counts as the two it occupies.
--
-- draw() records the rectangle of every row it puts on screen; hit-testing and
-- highlighting both read that, so what you can select is exactly what you can
-- see, and neither can drift from the layout.

local function pos_le(a, b)
  if a.e ~= b.e then return a.e < b.e end
  if a.r ~= b.r then return a.r < b.r end
  return a.c <= b.c
end

-- The row under a point, and the column within it.
function AgentView:pos_at(x, y)
  local best, best_dy
  for _, r in ipairs(self.rows_drawn or {}) do
    local dy = (y < r.y) and (r.y - y) or ((y > r.y + r.h) and (y - r.y - r.h) or 0)
    if not best_dy or dy < best_dy then best, best_dy = r, dy end
  end
  if not best then return nil end
  local col = math.floor((x - best.x) / self.char_w + 0.5)
  if col < 0 then col = 0 end
  if col > best.cells then col = best.cells end
  return { e = best.e, r = best.r, c = col }
end

-- The composer position under a point: which line, and the byte offset that
-- the display column corresponds to. Columns are cells and self.cx is a byte
-- index, so the conversion goes through the same cell-splitting the layout
-- uses rather than assuming one byte per column.
function AgentView:composer_pos_at(x, y)
  local rows = self.composer_rows
  if not rows or #rows == 0 then return nil end
  local best, best_dy
  for _, r in ipairs(rows) do
    local dy = (y < r.y) and (r.y - y) or ((y > r.y + r.h) and (y - r.y - r.h) or 0)
    if not best_dy or dy < best_dy then best, best_dy = r, dy end
  end
  if not best then return nil end
  local cells = math.floor((x - best.x) / self.char_w + 0.5)
  if cells < 0 then cells = 0 end
  local head = (split(best.line, cells))
  return best.i, #head + 1
end

-- Is this point inside the composer box at all?
function AgentView:in_composer(x, y)
  local rows = self.composer_rows
  if not rows or #rows == 0 then return false end
  local first, last = rows[1], rows[#rows]
  return y >= first.y - self.char_w and y <= last.y + last.h + self.char_w
end

function AgentView:clear_selection()
  if self.sel then self.sel = nil; core.redraw = true end
end

-- The selected text, in reading order.
function AgentView:selected_text()
  if not self.sel or not self.sel.b then return nil end
  local a, b = self.sel.a, self.sel.b
  if not pos_le(a, b) then a, b = b, a end
  local parts = {}
  for ei = a.e, b.e do
    local e = self.entries[ei]
    if e then
      local rows = e._layout and e._layout.rows
      if rows then
        local r1 = (ei == a.e) and a.r or 1
        local r2 = (ei == b.e) and b.r or #rows
        for ri = r1, math.min(r2, #rows) do
          local text = row_text(rows[ri])
          local from = (ei == a.e and ri == a.r) and a.c or 0
          local to = (ei == b.e and ri == b.r) and b.c or nil
          parts[#parts + 1] = cell_slice(text, from, to)
        end
      end
    end
  end
  return table.concat(parts, "\n")
end

function AgentView:on_mouse_moved(x, y, dx, dy)
  AgentView.super.on_mouse_moved(self, x, y, dx, dy)
  local was = self.hover_id
  self.mouse = { x = x, y = y }
  local item = widgets.hit(self.hits, x, y)
  self.hover_id = item and item.label or nil
  if self.hover_id ~= was then core.redraw = true end
  self.cursor = item and "arrow" or "ibeam"
  if self.selecting then
    local p = self:pos_at(x, y)
    if p then self.sel.b = p; core.redraw = true end
  elseif self.composer_selecting then
    local cy, cx = self:composer_pos_at(x, y)
    if cy then self.cy, self.cx = cy, cx; core.redraw = true end
  end
end

function AgentView:on_mouse_pressed(button, x, y, clicks)
  if AgentView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  local item = widgets.hit(self.hits, x, y)
  if item then
    core.set_active_view(self)
    if item.action then item.action() elseif item.command then
      command.perform(item.command)
    end
    return true
  end
  core.set_active_view(self)

  -- The composer is checked first: its rows overlap the region the transcript
  -- hit-test would otherwise claim, and a click in the box means the box.
  if self:in_composer(x, y) then
    self:set_edit_mode("insert")      -- clicking into the draft is editing it
    local cy, cx = self:composer_pos_at(x, y)
    if cy then
      self:clear_selection()          -- one selection at a time
      if clicks and clicks >= 2 then
        -- Word, which is the unit for editing a draft, rather than the whole
        -- row the transcript uses for copying one out.
        local line = self.lines[cy] or ""
        local from, to = cx, cx
        while from > 1 and line:sub(from - 1, from - 1):match("[%w_]") do
          from = from - 1
        end
        while to <= #line and line:sub(to, to):match("[%w_]") do to = to + 1 end
        self.sel_anchor = { cy = cy, cx = from }
        self.cy, self.cx = cy, to
        self.composer_selecting = false
      else
        self.sel_anchor = { cy = cy, cx = cx }
        self.cy, self.cx = cy, cx
        self.composer_selecting = true
      end
      core.redraw = true
    end
    return true
  end

  local p = self:pos_at(x, y)
  if p then
    self.sel_anchor = nil   -- selecting the transcript drops the composer's
    if clicks and clicks >= 2 then
      -- Double click takes the whole row, which is the unit people want out of
      -- a transcript far more often than a word: a path, a command, an error.
      local e = self.entries[p.e]
      local rows = e and e._layout and e._layout.rows
      local cells = rows and rows[p.r] and cell_len(row_text(rows[p.r])) or 0
      self.sel = { a = { e = p.e, r = p.r, c = 0 },
                   b = { e = p.e, r = p.r, c = cells } }
      self.selecting = false
    else
      self.sel = { a = p, b = p }
      self.selecting = true
    end
    core.redraw = true
  else
    self:clear_selection()
  end
  return true
end

function AgentView:on_mouse_released(button, x, y)
  AgentView.super.on_mouse_released(self, button, x, y)
  self.selecting = false
  self.composer_selecting = false
  -- A drag that went nowhere is a click, and a click should not leave an empty
  -- selection behind for copy to find.
  local a = self.sel_anchor
  if a and a.cy == self.cy and a.cx == self.cx then self.sel_anchor = nil end
end

function AgentView:get_scrollable_size()
  return self.content_height or math.huge
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------
--
-- The shape is a chat application's, not an editor's: a toolbar of the things
-- you can do, a centred column of conversation, and a composer at the bottom
-- with its controls inside it. The column is capped because a chat line
-- stretched across a 2000px monitor is genuinely hard to read -- the limit is
-- the same reason a newspaper has columns, not a stylistic tic.

local COLUMN_COLS = 96   -- widest the conversation column gets, in characters

function AgentView:toolbar_items()
  local busy = self.busy
  local studio = core.studio
  -- The rail owns navigation. The legacy attach still has no rail, so it
  -- keeps the long strip that used to be the only way to reach those surfaces.
  if studio and studio.legacy then
    local sidebar = studio.sidebar
    return {
      { label = (sidebar and sidebar.visible) and "<" or ">",
        command = "studio:toggle-sidebar" },
      { label = "New chat", command = "agent:new-session" },
      { label = "Chats",    command = "agent:resume-session" },
      { label = "Prompts",  command = "agent:run-recipe" },
      { label = "Files",    command = "studio:toggle-files" },
      { label = "Open",     command = "studio:open-folder" },
      { label = "Tools",    command = "agent:show-tools" },
      { label = "MCP",      command = "agent:list-mcp-servers" },
      { label = "Settings", command = "agent:settings" },
      { label = busy and "Stop" or "Compact",
        command = busy and "agent:cancel" or "agent:compact-now",
        tone = busy and (style.warn or style.accent) or nil },
    }
  end
  if studio and studio.legacy == false then
    return {
      { label = "New", command = "agent:new-session" },
      { label = busy and "Stop" or "Compact",
        command = busy and "agent:cancel" or "agent:compact-now",
        tone = busy and (style.warn or style.accent) or nil },
    }
  end
  local sidebar = studio and studio.sidebar
  local items = {}
  if sidebar then
    items[#items + 1] = { label = sidebar.visible and "<" or ">",
      command = "studio:toggle-sidebar" }
  end
  local rest = {
    { label = "New chat", command = "agent:new-session" },
    { label = "Chats",    command = "agent:resume-session" },
    { label = "Prompts",  command = "agent:run-recipe" },
    { label = "Files",    command = "studio:toggle-files" },
    { label = "Open",     command = "studio:open-folder" },
    { label = "Tools",    command = "agent:show-tools" },
    { label = "MCP",      command = "agent:list-mcp-servers" },
    { label = "Settings", command = "agent:settings" },
    { label = busy and "Stop" or "Compact",
      command = busy and "agent:cancel" or "agent:compact-now",
      tone = busy and (style.warn or style.accent) or nil },
  }
  for i = 1, #rest do items[#items + 1] = rest[i] end
  return items
end

function AgentView:composer_items()
  return {
    { label = "@ file",   command = "agent:attach-file" },
    { label = self:mode_label(), command = "agent:set-mode",
      tone = (self.mode == "auto") and (style.warn or style.accent) or nil },
    { label = self:model(), command = "agent:set-model", dim = true },
  }
end

-- What the agent is doing, while it is doing it.
--
-- The panel showed a word in the Send button and nothing else, so a turn that
-- thought for thirty seconds was indistinguishable from a turn that had died.
-- The bar is indeterminate on purpose: nothing here knows how long a model
-- will take, and a progress bar that invents a percentage is worse than none
-- -- it makes a promise the program cannot keep. A moving segment says "still
-- working" and claims nothing else.
--
-- Drawn rather than spun from characters because the bundled fonts have no
-- spinner glyphs, and this renderer draws rectangles well.
function AgentView:draw_working(x, y, w, font)
  local lh = font:get_height() * config.line_height
  local elapsed = self.busy_since and (system.get_time() - self.busy_since) or 0

  local what = self.status or "working"
  if self.pending then what = "waiting for you to approve " .. self.pending.name
  elseif self.tool_running then what = "running " .. self.tool_running end

  local label = string.format("%s  %.0fs", what, elapsed)
  common.draw_text(font, style.dim, label, "left", x, y, w, lh)

  -- The track, and a segment sliding along it. Two seconds a lap: fast enough
  -- to read as alive, slow enough not to nag.
  local track_y = y + lh
  local h = math.max(2, SCALE * 2)
  renderer.draw_rect(x, track_y, w, h, style.background2)
  if not self.pending then
    local period = 2.0
    local t = (system.get_time() % period) / period
    local seg = w * 0.18
    -- Ease at the ends so it looks like motion rather than a jump.
    local travel = (w + seg) * t - seg
    local sx = math.max(x, x + travel)
    local sw = math.min(x + w, x + travel + seg) - sx
    if sw > 0 then
      renderer.draw_rect(sx, track_y, sw, h, style.accent)
    end
  else
    -- Nothing is moving while it waits for a person; a bar that kept sliding
    -- would say the opposite.
    renderer.draw_rect(x, track_y, w, h, style.warn or style.accent)
  end
  return lh + h + style.padding.y
end

-- The approval bar. The one piece of the UI that must be read rather than
-- glanced at, so its buttons are buttons: clicking Approve should not require
-- knowing that "a" means approve.
function AgentView:draw_pending(x, y, w, font)
  local p = self.pending
  local lh = font:get_height() * config.line_height
  local pad = style.padding.y
  local bh = widgets.height(font)
  local h = lh + bh + pad * 3

  renderer.draw_rect(self.position.x, y, self.size.x, h, style.selection)
  renderer.draw_rect(self.position.x, y, math.max(2, style.padding.x / 3), h,
    style.warn or style.accent)

  -- Truncated from the left, keeping the tail. This is a security question --
  -- "apply what, to which file?" -- and the answer lives at the end of a path,
  -- so a long one used to run off the right edge of the panel and hide exactly
  -- the filename you were being asked to approve.
  local verb = (p.name == "bash" and "run: " or "apply: ")
  local body = p.summary or p.name
  local room = math.floor(w / font:get_width("0")) - #verb
  if room > 4 and cols_of(body) > room then
    body = "..." .. cdrop(body, cols_of(body) - (room - 3))
  end
  common.draw_text(font, style.accent, verb .. body, "left", x, y + pad, w, lh)

  local hits = widgets.row(font, {
    { label = "Approve", action = function() self:decide("approve") end },
    { label = "Reject",  action = function() self:decide("reject") end },
    { label = "Always allow", action = function() self:decide("always") end },
  }, x, y + pad * 2 + lh, self.mouse)
  for _, hit in ipairs(hits) do self.hits[#self.hits + 1] = hit end
  return h
end

-- The choose menu. Where the approval bar above is a yes/no on something about
-- to happen, this is a fork the model handed back to you mid-turn, so it reads
-- as a card in the conversation column rather than a bar: the prompt, then one
-- clickable row per option with its letter in accent, and -- when free input is
-- allowed -- a hint that the composer below will carry a typed answer. Answering
-- is choose.decide(rec, ...); lua/choose.lua clears bog.choice and resumes the
-- parked turn itself, so nothing here executes the outcome. Drawn inside the
-- transcript's clip band (the caller's push_clip_rect), so it wraps, clips and
-- scrolls like every other entry. Returns the height it consumed.
function AgentView:draw_choice(rec, x, y, w, cols, font, visible)
  local lh = font:get_height() * config.line_height
  local voff = (lh - font:get_height()) / 2
  local pad = style.padding.x
  local vpad = style.padding.y

  -- Measured up front: the card gets one background band the height of all its
  -- rows, so the rect needs the total before any row is drawn. Labels can wrap,
  -- so an option is however many rows wrap_tokens gives it, not always one.
  local prompt_rows = wrap_tokens(inline(rec.prompt or "Choose:", style.accent), cols)
  local opt_rows = {}
  for _, o in ipairs(rec.options) do
    opt_rows[#opt_rows + 1] = wrap_tokens(
      inline(o.label, style.text), cols,
      { style.accent, o.key .. ") " })
  end
  local nrows = #prompt_rows
  for _, rs in ipairs(opt_rows) do nrows = nrows + #rs end
  if rec.allow_input then nrows = nrows + 1 end
  local h = nrows * lh + vpad * 2

  -- The card: a tinted fill so it lifts out of the transcript, and a rule down
  -- the left edge -- the approval bar's "this one is yours" signal, in accent
  -- rather than warn because a choice is a fork, not a hazard.
  renderer.draw_rect(x - pad / 2, y, w + pad, h, style.background2)
  renderer.draw_rect(x - pad / 2, y, math.max(2, pad / 3), h, style.accent)

  local ty = y + vpad
  local function draw_row(row)
    local tx = x
    for _, t in ipairs(row) do
      tx = renderer.draw_text(font, t[2], tx, ty + voff, t[1])
    end
    ty = ty + lh
  end

  for _, row in ipairs(prompt_rows) do draw_row(row) end

  for i, rs in ipairs(opt_rows) do
    local oy, oh = ty, #rs * lh
    -- Only a row actually on screen is a hover/hit target. The card is clipped
    -- to the band, but a hit rect is not: one left below the fold would sit over
    -- the composer and steal that click. (The code-block copy button hedges the
    -- same way -- register the hit only when the row is visible.)
    local shown = visible(oy)
    if shown and self.mouse and self.mouse.x and widgets.inside(
        { x = x - pad / 2, y = oy, w = w + pad, h = oh }, self.mouse.x, self.mouse.y) then
      renderer.draw_rect(x - pad / 2, oy, w + pad, oh, style.line_highlight)
    end
    for _, row in ipairs(rs) do draw_row(row) end
    if shown then
      self.hits[#self.hits + 1] = {
        x = x - pad / 2, y = oy, w = w + pad, h = oh,
        item = { label = "choose-" .. i, action = function()
          choose.decide(rec, { index = i })
          core.redraw = true
        end },
      }
    end
  end

  if rec.allow_input then
    common.draw_text(font, style.dim,
      "(click one, press its letter, or type your own answer below)",
      "left", x, ty, w, lh)
  end

  return h
end

function AgentView:draw()
  self.hits = {}
  if self.docked and self.size.x < 20 then return end
  self:draw_background(style.background)
  local font = style.code_font
  local lh = font:get_height() * config.line_height
  local pad = style.padding.x
  local vpad = style.padding.y
  local charw = font:get_width("0")

  -- ---- toolbar ------------------------------------------------------------
  local bh = widgets.height(font)
  local top = self.position.y
  local toolbar_h = bh + vpad * 2
  renderer.draw_rect(self.position.x, top, self.size.x, toolbar_h, style.background2)
  renderer.draw_rect(self.position.x, top + toolbar_h - 1, self.size.x, 1, style.divider)
  for _, hit in ipairs(widgets.row(font, self:toolbar_items(),
      self.position.x + pad, top + vpad, self.mouse)) do
    self.hits[#self.hits + 1] = hit
  end

  -- ---- composer -----------------------------------------------------------
  local input_lines = math.min(math.max(#self.lines, 1), 8)
  -- Controls wrap onto a second row when the pickers and Send cannot share
  -- one. Height has to be reserved up front: body_bottom is derived from it,
  -- and a wrap that grew after the transcript was clipped would draw the
  -- extra row over the last message.
  local send_label = (self.busy and not (bog and bog.choice))
    and (self.status or "working") or "Send"
  local send_w = widgets.width(font, send_label)
  local gap = style.padding.x * widgets.GAP
  local col_w = math.max(20, math.min(COLUMN_COLS,
    math.floor((self.size.x - pad * 4) / charw))) * charw
  local one_row_w, wrap_rows, row_w = 0, 1, 0
  for _, it in ipairs(self:composer_items()) do
    local iw = widgets.width(font, it.label)
    one_row_w = one_row_w + iw + gap
    if row_w > 0 and row_w + iw > col_w then
      wrap_rows = wrap_rows + 1
      row_w = 0
    end
    row_w = row_w + iw + gap
  end
  local controls_wrap = one_row_w + send_w > col_w
  -- One shared row when everything fits; otherwise pickers wrap and Send
  -- sits on a row of its own so the two never share pixels.
  local control_rows = controls_wrap and (wrap_rows + 1) or 1
  local composer_h = lh * input_lines + vpad * 4
    + control_rows * bh + (control_rows - 1) * gap
  local pending_h = self.pending
    and (lh + widgets.height(font) + vpad * 3) or 0
  local body_top = top + toolbar_h
  local body_bottom = self.position.y + self.size.y - composer_h - pending_h

  -- ---- the conversation column -------------------------------------------
  local cols = math.max(20, math.min(COLUMN_COLS,
    math.floor((self.size.x - pad * 4) / charw)))
  local colw = cols * charw
  local x = self.position.x + math.max(pad, (self.size.x - colw) / 2)
  local w = colw
  local voff = (lh - font:get_height()) / 2

  local y = body_top + vpad - self.scroll.y

  local function visible(yy) return yy + lh > body_top and yy < body_bottom end

  -- The transcript is clipped to the band between the toolbar and the composer.
  -- Without this a row straddling either edge is drawn whole -- half of it over
  -- the toolbar's buttons, or sliced through the middle where the composer's
  -- fill happens to end.
  core.push_clip_rect(self.position.x, body_top, self.size.x,
    math.max(0, body_bottom - body_top))

  -- Selection bounds, ordered once per frame rather than per row.
  local sel_lo, sel_hi
  if self.sel and self.sel.b then
    sel_lo, sel_hi = self.sel.a, self.sel.b
    if not pos_le(sel_lo, sel_hi) then sel_lo, sel_hi = sel_hi, sel_lo end
  end
  self.rows_drawn = {}
  self.char_w = charw

  for ei, e in ipairs(self.entries) do
    e.content_y = (y + self.scroll.y) - body_top
    if e.role == "diff" and e.diff then
      if visible(y) then
        common.draw_text(font, style.dim, difflib.summary(e.diff, e.path or ""),
          "left", x, y, w, lh)
      end
      y = y + lh
      for _, row in ipairs(e.diff.hunk) do
        local kind, text = row[1], row[2]
        local col = (kind == "+" and style.good) or (kind == "-" and style.error)
                    or style.dim
        if visible(y) then
          renderer.draw_rect(x - pad / 2, y, w + pad, lh, style.background2)
          common.draw_text(font, col or style.text, kind .. " " .. text,
            "left", x, y, w, lh)
        end
        y = y + lh
      end
    else
      local rows = self:layout(e, cols)

      -- Rows are a fixed height, so an entry that is entirely above or below
      -- the band can be stepped over in one addition. That is what keeps a
      -- thousand-turn transcript at frame rate: the per-frame cost follows what
      -- is on screen, not what is in the session. It also replaces a hard stop
      -- at 600 rows, which quietly dropped the rest of a long entry *and* left
      -- content_height too small to scroll to it.
      local eh = #rows * lh
      if y + eh < body_top or y > body_bottom then
        y = y + eh
      else
        -- A user turn is a bubble, sized to its own text and pushed to the
        -- right; everything the agent says is plain and full width. That
        -- asymmetry is what makes a transcript skimmable -- the eye finds
        -- "where did I last say something" by shape, without reading a word.
        local ex = x
        if e.role == "user" then
          local widest = 0
          for _, row in ipairs(rows) do
            local n = 0
            for _, t in ipairs(row) do n = n + cols_of(t[2]) end
            widest = math.max(widest, n)
          end
          local bw = math.min(w, widest * charw + pad)
          ex = x + w - bw
          -- Drawn whenever any part of the bubble is in the band, not only
          -- when its first row is: a bubble scrolled halfway off the top used
          -- to lose its background entirely and read as an agent message.
          renderer.draw_rect(ex - pad / 2, y - vpad / 2, bw + pad,
            eh + vpad, style.selection)
        end

        for ri, row in ipairs(rows) do
          if visible(y) then
            if row.code then
              renderer.draw_rect(x - pad / 2, y, w + pad, lh, style.background2)
            end
            if row.copy_block then
              -- A copy affordance at the block's top-right: the fast path for
              -- lifting a snippet, brightening on hover, flips to "copied" after
              -- a click. Registered as a hit so on_mouse_pressed dispatches it.
              local label = (self.copied_block == row.copy_block) and "copied" or "copy"
              local bw = font:get_width(label) + pad
              local bx = x + w - bw
              local hov = self.mouse and widgets.inside(
                { x = bx, y = y, w = bw, h = lh }, self.mouse.x, self.mouse.y)
              local rct = widgets.button(font, label, bx, y,
                { w = bw, hover = hov, tone = style.dim })
              rct.item = { label = "copy-code", action = function()
                system.set_clipboard(row.copy_block)
                self.copied_block = row.copy_block
                core.redraw = true
              end }
              self.hits[#self.hits + 1] = rct
            end
            if row.thinking_head then
              -- The whole header row toggles the thought open/closed.
              self.hits[#self.hits + 1] = {
                x = ex, y = y, w = w, h = lh,
                item = { label = "toggle-think", action = function()
                  e.collapsed = not e.collapsed
                  e._layout = nil
                  core.redraw = true
                end },
              }
            end
            -- What is on screen, in the coordinates selection works in.
            -- Recorded rather than recomputed, so hit-testing cannot disagree
            -- with the layout it is testing against.
            local rtext = row_text(row)
            local cells = cell_len(rtext)
            self.rows_drawn[#self.rows_drawn + 1] = {
              e = ei, r = ri, x = ex, y = y, h = lh, cells = cells,
            }
            if sel_lo then
              -- The part of this row inside the selection, as two columns.
              local from, to = 0, cells
              local before = (ei < sel_lo.e) or (ei == sel_lo.e and ri < sel_lo.r)
              local after = (ei > sel_hi.e) or (ei == sel_hi.e and ri > sel_hi.r)
              if not before and not after then
                if ei == sel_lo.e and ri == sel_lo.r then from = sel_lo.c end
                if ei == sel_hi.e and ri == sel_hi.r then to = sel_hi.c end
                if to > from then
                  renderer.draw_rect(ex + from * charw, y,
                    (to - from) * charw, lh, style.selection)
                end
              end
            end
            if row.rule then
              renderer.draw_rect(ex, y + lh / 2, row.thin and (w / 3) or w,
                math.max(1, SCALE), style.divider)
            end
            local tx = ex
            for _, t in ipairs(row) do
              local nx = renderer.draw_text(font, t[2], tx, y + voff, t[1])
              -- Faux-bold: the same glyphs a pixel to the right. Cheap, and the
              -- only way to show emphasis with one font cut.
              if t.bold then
                renderer.draw_text(font, t[2], tx + math.max(1, SCALE * 0.5),
                  y + voff, t[1])
              end
              if t.link then
                renderer.draw_rect(tx, y + voff + font:get_height(),
                  nx - tx, math.max(1, SCALE), t[1])
              end
              tx = nx
            end
          end
          y = y + lh
        end
      end
    end
    y = y + lh * 0.4
  end

  -- The pending choose menu (lua/choose.lua parked the turn on it) draws here,
  -- inside the transcript band, right where the reply will resume -- so it
  -- clips and scrolls like every other entry. It clears itself once answered,
  -- so this simply stops drawing then; no bookkeeping beyond rendering it.
  local pending_choice = bog and bog.choice or nil
  if pending_choice then
    y = y + vpad
    y = y + self:draw_choice(pending_choice, x, y, w, cols, font, visible)
  end

  core.pop_clip_rect()

  -- The working indicator sits where the answer will appear, so the eye is
  -- already in the right place when it does. While a choose menu is up the turn
  -- is parked on the user, not on the model, so the card above stands in for the
  -- indeterminate bar rather than sliding away beside it.
  if self.busy and not pending_choice then
    if visible(y) then
      self:draw_working(x, y + vpad, w, font)
    end
    y = y + lh * 2 + vpad
  end

  -- An empty panel should say what to do, not sit there blankly.
  if #self.entries == 0 then
    common.draw_text(font, style.dim, "Ask boggart anything about this project.",
      "center", self.position.x, body_top, self.size.x, body_bottom - body_top)
  end

  -- The scrollable height, in the terms lite's View uses: it clamps scrolling
  -- at get_scrollable_size() - size.y, so this must be the height that makes
  -- that expression the real maximum.
  --
  -- The body is not the view. Three bands are subtracted from it -- the
  -- toolbar above, the composer below, and the approval bar when there is one
  -- -- so the visible body is size.y - toolbar_h - composer_h - pending_h, and
  -- the maximum scroll is the content height minus THAT. This line used to
  -- omit toolbar_h, which made the maximum short by exactly the toolbar's
  -- height: the last inch of the transcript could not be scrolled to, and the
  -- newest message sat under the composer no matter how far you scrolled. The
  -- trailing vpad is so the final line clears the composer instead of touching
  -- it.
  -- Where the transcript actually ended this frame, in screen coordinates, and
  -- the band it had to fit inside. Recorded rather than recomputed by the
  -- checks: a test that derives these from the same arithmetic it is testing
  -- agrees with a wrong answer. tools/uishot.lua asserts the first is above
  -- the second once scrolled to the end.
  self.content_bottom_y = y
  self.body_bottom_y = body_bottom

  -- "Were we at the bottom?" has to be asked of the layout the user was
  -- looking at, which is last frame's, not the one just computed.
  --
  -- This compared the scroll position against the NEW maximum, after the new
  -- content had already made it taller. Anything arriving that was taller than
  -- the six-line slack -- a code block, a diff, most real answers -- moved the
  -- bottom further than the test allowed, so the panel decided the user had
  -- scrolled away and stopped following, exactly when the newest text was the
  -- thing worth seeing. Streaming hid it, because chunks arrive a few
  -- characters at a time; a message pushed whole did not.
  local prev_max = math.max(0, (self.content_height or 0) - self.size.y)
  local was_at_bottom = self.scroll.to.y >= prev_max - lh * 2

  self.content_height = (y + self.scroll.y) - body_top
    + toolbar_h + composer_h + pending_h + vpad

  if self.scroll_to_end then
    self.scroll_to_end = false
    -- While a turn is running, follow regardless: the user has not scrolled,
    -- they are watching it arrive.
    if was_at_bottom or self.busy then
      self.scroll.to.y = math.max(0, self.content_height - self.size.y)
    end
  end

  if self.pending then
    self:draw_pending(x, body_bottom, w, font)
  end

  -- ---- composer box -------------------------------------------------------
  local iy = self.position.y + self.size.y - composer_h
  local focused = core.active_view == self
  -- Normally the composer looks disabled while a turn runs -- dim text, no
  -- caret -- because there is nothing to send to. A pending choose menu is the
  -- exception: the turn is parked waiting for a typed answer, so the box has to
  -- read as live even though we are busy.
  local composing = not self.busy or (bog and bog.choice)
  renderer.draw_rect(self.position.x, iy, self.size.x, composer_h, style.background)
  local bx, bw = x - pad / 2, w + pad
  renderer.draw_rect(bx, iy + vpad, bw, composer_h - vpad * 2, style.background2)
  -- A border rather than a fill change, so focus is visible without the box
  -- appearing to change size. Normal mode borrows the warn colour, the same
  -- signal the approval bar uses, so "the composer is not taking text right now"
  -- reads at a glance without a label.
  local border = focused
    and (self.edit_mode == "normal" and (style.warn or style.accent) or style.accent)
    or style.divider
  renderer.draw_rect(bx, iy + vpad, bw, 1, border)
  renderer.draw_rect(bx, iy + composer_h - vpad - 1, bw, 1, border)
  renderer.draw_rect(bx, iy + vpad, 1, composer_h - vpad * 2, border)
  renderer.draw_rect(bx + bw - 1, iy + vpad, 1, composer_h - vpad * 2, border)

  -- The box shows at most eight lines, so a longer draft has to scroll to the
  -- caret. It did not: it always drew lines 1..8, and from the ninth line on
  -- you were typing into a line that was not on screen, with no caret to say
  -- where you were.
  local top_line = math.max(1, math.min(self.cy - input_lines + 1,
    #self.lines - input_lines + 1))
  -- The composer's rows, in the coordinates a pointer arrives in, so it can be
  -- dragged through like any other text. Recorded here for the same reason the
  -- transcript's are: hit-testing that recomputes the layout eventually
  -- disagrees with the layout.
  self.composer_rows = {}
  local csel_lo, csel_hi
  if self.sel_anchor then
    local a = self.sel_anchor
    csel_lo, csel_hi = a, { cy = self.cy, cx = self.cx }
    if csel_lo.cy > csel_hi.cy
       or (csel_lo.cy == csel_hi.cy and csel_lo.cx > csel_hi.cx) then
      csel_lo, csel_hi = csel_hi, csel_lo
    end
  end

  local ty = iy + vpad * 2
  for i = top_line, top_line + input_lines - 1 do
    local line = self.lines[i] or ""
    self.composer_rows[#self.composer_rows + 1] =
      { i = i, x = x, y = ty, h = lh, line = line }

    -- Highlight before the text, so the glyphs sit on top of it.
    if csel_lo and i >= csel_lo.cy and i <= csel_hi.cy then
      local from = (i == csel_lo.cy) and cols_of(line:sub(1, csel_lo.cx - 1)) or 0
      local to = (i == csel_hi.cy) and cols_of(line:sub(1, csel_hi.cx - 1))
                 or cols_of(line)
      -- A selection that runs to the end of a line includes the newline, and
      -- showing a sliver past the last glyph is how that reads.
      if i < csel_hi.cy then to = to + 1 end
      if to > from then
        renderer.draw_rect(x + from * charw, ty, (to - from) * charw, lh,
          style.selection)
      end
    end

    local shown = line
    -- No text caret in normal mode: nothing you type lands here, so a caret
    -- would promise an insertion point that is not listening.
    if i == self.cy and composing and focused and self.edit_mode ~= "normal" then
      shown = line:sub(1, self.cx - 1) .. "|" .. line:sub(self.cx)
    end
    if i == 1 and line == "" and #self.lines == 1 and composing then
      common.draw_text(font, style.dim,
        (bog and bog.choice and bog.choice.allow_input)
          and "Type your own answer..." or "Reply to boggart...",
        "left", x, ty, w, lh)
    else
      common.draw_text(font, (not composing) and style.dim or style.text,
        shown, "left", x, ty, w, lh)
    end
    ty = ty + lh
  end

  -- controls inside the box: attachments and pickers left, send right.
  -- When they cannot share a row, the pickers wrap and Send sits on the
  -- next row -- never drawn on top of a picker.
  local crow = iy + composer_h - vpad * 2
    - control_rows * bh - (control_rows - 1) * gap
  local sw = send_w
  local sx = x + w - sw
  local limit = controls_wrap and (x + w) or (sx - gap)
  local chits, below = widgets.wrap_row(font, self:composer_items(), x, crow,
    self.mouse, limit)
  for _, hit in ipairs(chits) do
    self.hits[#self.hits + 1] = hit
    if hit.item and hit.item.command == "agent:set-mode" then
      self.mode_hit = hit
    elseif hit.item and hit.item.command == "agent:set-model" then
      self.model_hit = hit
    end
  end
  local send_y = controls_wrap and below + gap or crow
  local shit = widgets.button(font, send_label, sx, send_y, {
    w = sw,
    active = composing and self:input_text() ~= "",
    dim = not composing,
    hover = self.mouse and widgets.inside({ x = sx, y = send_y, w = sw, h = bh },
      self.mouse.x, self.mouse.y),
  })
  shit.item = { label = send_label, action = function()
    -- A typed answer to a pending choose menu goes through send() even though
    -- the turn is busy; otherwise the busy branch would cancel it instead.
    if bog and bog.choice then self:send()
    elseif self.busy then self:cancel()
    else self:send() end
  end }
  self.hits[#self.hits + 1] = shit

  complete.draw(self, {
    font = font, x = x, w = w, y = iy, lh = lh, pad = pad,
  })

  self:draw_scrollbar()
end

command.add(AgentView, {
  ["agent:history-search"] = function()
    local v = core.active_view
    if not v or not v.history then return end
    local items = {}
    for i = #v.history, 1, -1 do items[#items + 1] = v.history[i] end
    core.command_view:enter("History:", function(text, item)
      v:set_input(item or text or "")
      core.set_active_view(v)
    end, function(text)
      return common.fuzzy_match(items, text)
    end)
  end,
})
keymap.add { ["ctrl+r"] = "agent:history-search" }

return AgentView
