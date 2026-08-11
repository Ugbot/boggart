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
local command = require "core.command"
local widgets = require "core.widgets"
local tokenizer = require "core.tokenizer"
local syntax = require "core.syntax"

local AgentView = View:extend()

local ROLE = {
  user      = { prefix = "› ", color = "accent" },
  assistant = { prefix = "",   color = "text" },
  tool      = { prefix = "» ", color = "keyword" },
  diff      = { prefix = "",   color = "text" },
  error     = { prefix = "!! ", color = "error" },
  system    = { prefix = "·  ", color = "dim" },
}

-- Tools that change the world. These are what an approval gate is for; read,
-- list and the model's own helpers are not worth interrupting for.
local GATED = { write = true, edit = true, bash = true }

-- Permission modes. The same four goose settled on, because the space really
-- does have four useful points in it: never ask, always ask, ask about the
-- things that can break something, and do not use tools at all.
--
-- "smart" is the default and is not a risk model -- it is the GATED list
-- above. Calling it a judgement about risk would be overselling a table.
local MODES = {
  { id = "auto",   label = "Autonomous",     help = "tools run without asking" },
  { id = "smart",  label = "Smart approval", help = "ask before writes, edits and commands" },
  { id = "manual", label = "Manual approval", help = "ask before every tool" },
  { id = "chat",   label = "Chat only",      help = "no tools at all" },
}
local MODE_BY_ID = {}
for _, m in ipairs(MODES) do MODE_BY_ID[m.id] = m end
AgentView.MODES = MODES

function AgentView:new()
  AgentView.super.new(self)
  self.scrollable = true
  self.entries = {}
  self.busy = false
  self.co = nil
  self.status = "idle"
  self.approve_all = false     -- "always allow" for this session
  self.mode = "smart"          -- approval on by default, like goose/codex
  self.tool_policy = {}        -- name -> "allow" | "ask" | "deny", overrides mode
  self.pending = nil           -- { name, input, diff, path, decision }
  self.history, self.hpos = {}, 0

  -- Input state: a line array plus a caret, so this behaves like a text field
  -- rather than a string you can only backspace through.
  self.lines, self.cy, self.cx = { "" }, 1, 1

  self:push("system", "boggart " .. (bog and bog.version or "?")
    .. "   model " .. self:model())
  self:push("system",
    "enter sends · shift+enter newline · esc cancels · ctrl+g toggles approval")
  if bog and not self:has_creds() then
    self:push("system", "No credentials. Command palette: 'agent: set api key',")
    self:push("system", "or 'agent: set endpoint' for a local server (ds4 on :8000).")
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
  if self.pending then return "Agent ⏸" end
  return self.busy and "Agent ●" or "Agent"
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

-- @-mentions: "explain @src/lauth.c" attaches the file.
--
-- Expanded here, at the keystroke, rather than inside submit(): submit() is
-- also how studio sends a selection, and that payload is already a fenced
-- block which may legitimately contain an @. Attaching inline costs a turn of
-- context but saves a round trip through the read tool, which is the trade
-- every other coding agent makes for the file you have explicitly named.
local MENTION_MAX = 64 * 1024

function AgentView:expand_mentions(text)
  local seen, attach = {}, {}
  for path in text:gmatch("@([%w%._%-/~]+)") do
    if not seen[path] then
      seen[path] = true
      local real = path:gsub("^~", sys.home())
      -- Relative paths need no base: lite chdirs to the project directory at
      -- startup, so the process cwd is already the project root.
      local body = bog.util.read_file(real)
      if body then
        local note = ""
        if #body > MENTION_MAX then
          body = body:sub(1, MENTION_MAX)
          note = string.format("\n... (truncated at %d KB)", MENTION_MAX // 1024)
        end
        attach[#attach + 1] = string.format("--- %s ---\n%s%s", path, body, note)
        self:push("system", string.format("attached %s (%d bytes)", path, #body))
      else
        -- Not silently: an @ that did not resolve is nearly always a typo, and
        -- the model answering confidently about a file it never saw is worse
        -- than being told the path was wrong.
        self:push("error", "no such file: " .. path)
      end
    end
  end
  if #attach == 0 then return text end
  return text .. "\n\n" .. table.concat(attach, "\n\n")
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
function AgentView:request_approval(name, input)
  local rec = { name = name, input = input, decision = nil }
  if name == "write" or name == "edit" then
    local path = input.path
    rec.path = path
    local old = (path and bog.util.read_file(path)) or ""
    local new
    if name == "write" then
      new = input.content or ""
    else
      -- Show what the edit would produce, without performing it. If `old`
      -- does not occur exactly once the tool will refuse anyway, so we let it
      -- through unreviewed and the model gets its normal validation error.
      local first = old:find(input.old or "", 1, true)
      local second = first and old:find(input.old or "", first + 1, true)
      if not first or second then return nil end
      new = old:sub(1, first - 1) .. (input.new or "")
          .. old:sub(first + #(input.old or ""))
    end
    rec.diff = difflib.compute(old, new)
    rec.summary = difflib.summary(rec.diff, path or "(no path)")
  else
    rec.summary = tostring(input.command or "")
  end
  return rec
end

-- What should happen when the model calls `name`: "allow", "ask" or "deny".
-- An explicit per-tool policy always wins over the mode, which is the point of
-- having one -- "manual approval, except never ask about read" is a reasonable
-- thing to want and a mode alone cannot express it.
function AgentView:policy_for(name)
  local explicit = self.tool_policy[name]
  if explicit then return explicit end
  if self.mode == "chat" then return "deny" end
  if self.mode == "auto" then return "allow" end
  if self.approve_all then return "allow" end
  if self.mode == "manual" then return "ask" end
  return GATED[name] and "ask" or "allow"   -- smart
end

function AgentView:mode_label()
  local m = MODE_BY_ID[self.mode]
  return m and m.label or self.mode
end

function AgentView:set_mode(id)
  if not MODE_BY_ID[id] then return false end
  self.mode = id
  self.approve_all = false   -- a mode change is an explicit re-decision
  self:push("system", "mode: " .. self:mode_label()
    .. " -- " .. MODE_BY_ID[id].help)
  core.redraw = true
  return true
end

function AgentView:decide(decision)
  if not self.pending then return end
  if decision == "always" then
    self.approve_all = true
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
  self:push("user", text)
  self.busy, self.status = true, "thinking"

  self.co = coroutine.create(function()
    local okrun, err = pcall(bog.api.run_on, bog.session, text,
      function(chunk) self:stream(chunk) end,
      {
        async = true,

        -- Chat-only withholds the schemas rather than only refusing the calls.
        -- Denying a tool the model can see invites it to keep trying; a model
        -- that was never offered one simply answers.
        tools = (self.mode == "chat") and function() return {} end or nil,

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
          local hint = ""
          if type(input) == "table" then
            local h = input.command or input.path or input.query or input.name
            if h then hint = ": " .. tostring(h):gsub("%s+", " "):sub(1, 90) end
          end
          self:close_stream()
          self:push("tool", name .. hint)
        end,

        -- The approval gate. Yielding here suspends the whole turn mid-tool,
        -- which is exactly right: nothing has happened yet, and resuming
        -- continues from the same place whichever way the user decides.
        run_tool = function(name, input)
          input = input or {}
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
              if rec.diff and rec.path then
                self:push("diff", "", { diff = rec.diff, path = rec.path })
              end
            end
          end
          local out = bog.tools.run(name, input)
          if name == "write" or name == "edit" then
            self.dirty_path = input.path
          end
          return out
        end,
      })
    self:close_stream()
    if not okrun then self:push("error", tostring(err)) end
    self.busy, self.status, self.pending = false, "idle", nil
    if bog.save_session then pcall(bog.save_session) end
    core.redraw = true
  end)
end

-- One path for "send this", whether it came from the return key or the button.
function AgentView:send()
  if self.busy then return end
  local t = self:input_text():gsub("^%s+", ""):gsub("%s+$", "")
  if t == "" then return end
  self:set_input("")
  self:submit(self:expand_mentions(t))
end

function AgentView:cancel()
  if self.pending then self:decide("reject"); return end
  if not self.busy then return end
  self.co, self.busy, self.status = nil, false, "idle"
  self:close_stream()
  self:push("system", "cancelled")
end

-- One slice of agent work per frame. Must always return quickly.
function AgentView:tick()
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

  -- Reload a buffer the agent just wrote, so you are never reading a stale
  -- file while the agent works in it.
  if self.dirty_path then
    local path = self.dirty_path
    self.dirty_path = nil
    for _, d in ipairs(core.docs) do
      if d.filename and d.filename:find(path, 1, true) and not d:is_dirty() then
        pcall(function() d:reload() end)
      end
    end
  end
end

function AgentView:update()
  self:tick()
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
end

function AgentView:on_text_input(text)
  local l = self.lines[self.cy]
  self.lines[self.cy] = l:sub(1, self.cx - 1) .. text .. l:sub(self.cx)
  self.cx = self.cx + #text
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

  if key == "return" then
    self:send()
    return true

  elseif key == "shift+return" then
    local l = self.lines[self.cy]
    local rest = l:sub(self.cx)
    self.lines[self.cy] = l:sub(1, self.cx - 1)
    table.insert(self.lines, self.cy + 1, rest)
    self.cy, self.cx = self.cy + 1, 1
    core.redraw = true
    return true

  elseif key == "backspace" then
    if self.cx > 1 then
      local l = self.lines[self.cy]
      self.lines[self.cy] = l:sub(1, self.cx - 2) .. l:sub(self.cx)
      self.cx = self.cx - 1
    elseif self.cy > 1 then
      local prev = self.lines[self.cy - 1]
      self.cx = #prev + 1
      self.lines[self.cy - 1] = prev .. self.lines[self.cy]
      table.remove(self.lines, self.cy)
      self.cy = self.cy - 1
    end
    core.redraw = true
    return true

  elseif key == "ctrl+backspace" or key == "alt+backspace" then
    local l = self.lines[self.cy]
    local head = l:sub(1, self.cx - 1):gsub("%s*%S+%s*$", "")
    self.cx = #head + 1
    self.lines[self.cy] = head .. l:sub(self.cx + (#l:sub(1, self.cx - 1) - #head))
    self.lines[self.cy] = head .. l:sub(self.cx)
    core.redraw = true
    return true

  elseif key == "left" then
    if self.cx > 1 then self.cx = self.cx - 1
    elseif self.cy > 1 then self.cy = self.cy - 1; self.cx = #self.lines[self.cy] + 1 end
    core.redraw = true; return true

  elseif key == "right" then
    if self.cx <= #self.lines[self.cy] then self.cx = self.cx + 1
    elseif self.cy < #self.lines then self.cy = self.cy + 1; self.cx = 1 end
    core.redraw = true; return true

  elseif key == "home" or key == "ctrl+a" then
    self.cx = 1; core.redraw = true; return true

  elseif key == "end" or key == "ctrl+e" then
    self.cx = #self.lines[self.cy] + 1; core.redraw = true; return true

  elseif key == "ctrl+u" then
    self.lines[self.cy] = self.lines[self.cy]:sub(self.cx)
    self.cx = 1; core.redraw = true; return true

  -- History, but only from a single-line empty-ish input, so up/down still
  -- move the caret in a multi-line draft.
  elseif key == "up" and #self.lines == 1 then
    if #self.history > 0 then
      self.hpos = math.min(self.hpos + 1, #self.history)
      self:set_input(self.history[#self.history - self.hpos + 1] or "")
    end
    return true

  elseif key == "down" and #self.lines == 1 then
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
    self:cancel()
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
-- character counts. That is what makes wrapping a token row cheap. It also
-- means a multi-byte character measures as its byte length -- the same
-- limitation lua/dash.lua has, and the same reason: doing it properly needs
-- wcwidth, which is a bigger job than this panel justifies today.

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

-- Break a coloured token row to fit `cols` characters, splitting between
-- tokens where possible and inside one only when a single token is too wide.
local function fit(tokens, cols)
  local rows, cur, used = {}, {}, 0
  for _, t in ipairs(tokens) do
    local col, text = t[1], t[2]
    while #text > 0 do
      if used >= cols then rows[#rows + 1] = cur; cur, used = {}, 0 end
      local room = cols - used
      if #text <= room then
        cur[#cur + 1] = { col, text }; used = used + #text; text = ""
      else
        cur[#cur + 1] = { col, text:sub(1, room) }; text = text:sub(room + 1)
        used = cols
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
local function wrap_tokens(tokens, cols)
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
      used = used + #t[2]
    end
    for lead, chunk in t[2]:gmatch("(%s*)(%S+)") do
      -- Copied out of the loop variable: Lua 5.5 makes the control variable
      -- read-only, and this loop consumes it.
      local word = lead .. chunk
      local wlen = #word
      if used + wlen > cols and used > 0 then
        flush()
        word = word:gsub("^%s+", "")   -- no leading space at the start of a row
        wlen = #word
      end
      while wlen > cols do   -- a single word longer than the column
        cur[#cur + 1] = { t[1], word:sub(1, cols), bold = t.bold, link = t.link }
        rows[#rows + 1] = cur; cur, used = {}, 0
        word = word:sub(cols + 1); wlen = #word
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
      used = used + #tail
    end
  end
  flush()
  if #rows == 0 then rows[1] = { { style.text, "" } } end
  return rows
end

-- Rows for one entry, cached against (cols, text length). Streaming only ever
-- appends, so the length is a sufficient invalidation key -- and re-laying-out
-- a growing reply on every one of sixty frames a second is exactly what this
-- cache exists to avoid.
function AgentView:layout(e, cols)
  local c = e._layout
  if c and c.cols == cols and c.n == #e.text then return c.rows end

  local r = ROLE[e.role] or ROLE.assistant
  local base = style[r.color] or style.text
  local rows = {}
  local in_code, syn, state = false, nil, nil
  local first = true

  for line in (e.text .. "\n"):gmatch("(.-)\n") do
    local fence, lang = line:match("^%s*(```+)%s*([%w_+#%-]*)")
    if fence then
      -- The fence is markup, not content. Every chat UI worth using shows the
      -- block, not the backticks that delimit it; a band behind the code says
      -- the same thing without spending three rows on punctuation.
      if in_code then in_code, syn, state = false, nil, nil
      else in_code, syn, state = true, syntax_for(lang), nil end
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
      for _, row in ipairs(fit(toks, cols)) do
        row.code = true
        rows[#rows + 1] = row
      end
    elseif in_code then
      for _, row in ipairs(fit({ { style.text, line } }, cols)) do
        row.code = true
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
      local num = line:match("^%s*%d+%.%s")

      if hashes then
        body, col, bold = htext, style.accent, true
      elseif quote then
        body, col = quote, style.dim
        prefix = { style.divider, "| " }
      elseif bullet then
        body = line:sub(bullet)
        prefix = { style.accent, ind .. "- " }
      elseif num then
        -- Numbered lists keep their own marker; it is already meaningful.
        body = line
      end

      local toks = inline(body, col)
      if bold then for _, t in ipairs(toks) do t.bold = true end end
      if prefix then table.insert(toks, 1, prefix) end
      if first and r.prefix ~= "" then
        table.insert(toks, 1, { col, r.prefix })
      end
      for _, row in ipairs(wrap_tokens(toks, cols)) do rows[#rows + 1] = row end
      if hashes and #hashes <= 2 then rows[#rows + 1] = { rule = true, thin = true } end
    end
    first = false
  end

  e._layout = { cols = cols, n = #e.text, rows = rows }
  return rows
end

-- ---------------------------------------------------------------------------
-- Mouse
-- ---------------------------------------------------------------------------
--
-- The buttons' rects are rebuilt by draw() every frame and hit-tested here.
-- Recomputing them on click instead would mean duplicating the layout, and two
-- copies of a layout drift apart the first time one is edited.

function AgentView:on_mouse_moved(x, y, dx, dy)
  AgentView.super.on_mouse_moved(self, x, y, dx, dy)
  local was = self.hover_id
  self.mouse = { x = x, y = y }
  local item = widgets.hit(self.hits, x, y)
  self.hover_id = item and item.label or nil
  if self.hover_id ~= was then core.redraw = true end
  self.cursor = item and "arrow" or "ibeam"
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
  -- Clicking anywhere else focuses the panel, so typing goes to the composer.
  core.set_active_view(self)
  return true
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
  return {
    { label = "New chat", command = "agent:new-session" },
    { label = "Chats",    command = "agent:resume-session" },
    { label = "Recipes",  command = "agent:run-recipe" },
    { label = "Files",    command = "studio:toggle-files" },
    { label = "Tools",    command = "agent:show-tools" },
    { label = "MCP",      command = "agent:list-mcp-servers" },
    { label = "Settings", command = "agent:settings" },
    { label = busy and "Stop" or "Compact",
      command = busy and "agent:cancel" or "agent:compact-now",
      tone = busy and (style.warn or style.accent) or nil },
  }
end

function AgentView:composer_items()
  return {
    { label = "@ file",   command = "agent:attach-file" },
    { label = self:mode_label(), command = "agent:set-mode",
      tone = (self.mode == "auto") and (style.warn or style.accent) or nil },
    { label = self:model(), command = "agent:set-model", dim = true },
  }
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

  common.draw_text(font, style.accent,
    (p.name == "bash" and "run: " or "apply: ") .. (p.summary or p.name),
    "left", x, y + pad, w, lh)

  local hits = widgets.row(font, {
    { label = "Approve", action = function() self:decide("approve") end },
    { label = "Reject",  action = function() self:decide("reject") end },
    { label = "Always allow", action = function() self:decide("always") end },
  }, x, y + pad * 2 + lh, self.mouse)
  for _, hit in ipairs(hits) do self.hits[#self.hits + 1] = hit end
  return h
end

function AgentView:draw()
  self:draw_background(style.background)
  local font = style.code_font
  local lh = font:get_height() * config.line_height
  local pad = style.padding.x
  local vpad = style.padding.y
  local charw = font:get_width("0")
  self.hits = {}

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
  local composer_h = lh * input_lines + bh + vpad * 4
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

  for _, e in ipairs(self.entries) do
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

      -- A user turn is a bubble, sized to its own text and pushed to the right;
      -- everything the agent says is plain and full width. That asymmetry is
      -- what makes a transcript skimmable -- the eye finds "where did I last
      -- say something" by shape, without reading a word.
      local ex, bw = x, nil
      if e.role == "user" then
        local widest = 0
        for _, row in ipairs(rows) do
          local n = 0
          for _, t in ipairs(row) do n = n + #t[2] end
          widest = math.max(widest, n)
        end
        bw = math.min(w, widest * charw + pad)
        ex = x + w - bw
        if visible(y) then
          renderer.draw_rect(ex - pad / 2, y - vpad / 2, bw + pad,
            #rows * lh + vpad, style.selection)
        end
      end

      for i, row in ipairs(rows) do
        if visible(y) then
          if row.code then
            renderer.draw_rect(x - pad / 2, y, w + pad, lh, style.background2)
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
        if i > 600 then break end
      end
    end
    y = y + lh * 0.4
  end

  -- An empty panel should say what to do, not sit there blankly.
  if #self.entries == 0 then
    common.draw_text(font, style.dim, "Ask boggart anything about this project.",
      "center", self.position.x, body_top, self.size.x, body_bottom - body_top)
  end

  self.content_height = (y + self.scroll.y) - body_top + composer_h + pending_h

  if self.scroll_to_end then
    self.scroll_to_end = false
    local max = math.max(0, self.content_height - self.size.y)
    if self.scroll.to.y > max - lh * 6 or self.busy then
      self.scroll.to.y = max
    end
  end

  if self.pending then
    self:draw_pending(x, body_bottom, w, font)
  end

  -- ---- composer box -------------------------------------------------------
  local iy = self.position.y + self.size.y - composer_h
  local focused = core.active_view == self
  renderer.draw_rect(self.position.x, iy, self.size.x, composer_h, style.background)
  local bx, bw = x - pad / 2, w + pad
  renderer.draw_rect(bx, iy + vpad, bw, composer_h - vpad * 2, style.background2)
  -- A border rather than a fill change, so focus is visible without the box
  -- appearing to change size.
  local border = focused and style.accent or style.divider
  renderer.draw_rect(bx, iy + vpad, bw, 1, border)
  renderer.draw_rect(bx, iy + composer_h - vpad - 1, bw, 1, border)
  renderer.draw_rect(bx, iy + vpad, 1, composer_h - vpad * 2, border)
  renderer.draw_rect(bx + bw - 1, iy + vpad, 1, composer_h - vpad * 2, border)

  local ty = iy + vpad * 2
  for i = 1, input_lines do
    local line = self.lines[i] or ""
    local shown = line
    if i == self.cy and not self.busy and focused then
      shown = line:sub(1, self.cx - 1) .. "|" .. line:sub(self.cx)
    end
    if i == 1 and line == "" and #self.lines == 1 and not self.busy then
      common.draw_text(font, style.dim, "Reply to boggart...", "left",
        x, ty, w, lh)
    else
      common.draw_text(font, self.busy and style.dim or style.text,
        shown, "left", x, ty, w, lh)
    end
    ty = ty + lh
  end

  -- controls inside the box: attachments and pickers left, send right
  local crow = iy + composer_h - vpad * 2 - bh
  for _, hit in ipairs(widgets.row(font, self:composer_items(), x, crow, self.mouse)) do
    self.hits[#self.hits + 1] = hit
  end
  local send_label = self.busy and (self.status or "working") or "Send"
  local sw = widgets.width(font, send_label)
  local sx = x + w - sw
  local shit = widgets.button(font, send_label, sx, crow, {
    w = sw,
    active = not self.busy and self:input_text() ~= "",
    dim = self.busy,
    hover = self.mouse and widgets.inside({ x = sx, y = crow, w = sw, h = bh },
      self.mouse.x, self.mouse.y),
  })
  shit.item = { label = send_label, action = function()
    if self.busy then self:cancel() else self:send() end
  end }
  self.hits[#self.hits + 1] = shit

  self:draw_scrollbar()
end

return AgentView
