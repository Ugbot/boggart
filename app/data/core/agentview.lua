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

function AgentView:new()
  AgentView.super.new(self)
  self.scrollable = true
  self.entries = {}
  self.busy = false
  self.co = nil
  self.status = "idle"
  self.approve_all = false     -- "always allow" for this session
  self.gate = true             -- approval on by default, like goose/codex
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
          if self.gate and not self.approve_all and GATED[name] then
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
    local t = self:input_text()
    self:set_input("")
    self:submit((t:gsub("^%s+", ""):gsub("%s+$", "")))
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
    self.gate = not self.gate
    self:push("system", "approval " .. (self.gate and "on" or "off"))
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

local function wrap_words(text, cols)
  local out, cur = {}, ""
  for word in text:gmatch("%S+%s*") do
    if #cur + #word > cols and cur ~= "" then out[#out + 1] = cur; cur = word
    else cur = cur .. word end
  end
  out[#out + 1] = cur
  return out
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
      if in_code then in_code, syn, state = false, nil, nil
      else in_code, syn, state = true, syntax_for(lang), nil end
      rows[#rows + 1] = { { style.dim, line } }
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
      for _, row in ipairs(fit(toks, cols)) do rows[#rows + 1] = row end
    elseif in_code then
      for _, row in ipairs(fit({ { style.text, line } }, cols)) do
        rows[#rows + 1] = row
      end
    else
      -- Prose. The cheapest markdown that earns its pixels: headings stand
      -- out, quotes recede, everything else is text.
      local col = base
      if line:match("^#+%s") then col = style.accent
      elseif line:match("^%s*>%s") then col = style.dim end
      local text = (first and r.prefix or "") .. line
      for _, w in ipairs(wrap_words(text, cols)) do rows[#rows + 1] = { { col, w } } end
    end
    first = false
  end

  e._layout = { cols = cols, n = #e.text, rows = rows }
  return rows
end

function AgentView:get_scrollable_size()
  return self.content_height or math.huge
end

-- The approval bar: what is about to happen, and the keys that decide it.
function AgentView:draw_pending(x, y, w, lh, font)
  local p = self.pending
  local h = lh * 2
  renderer.draw_rect(self.position.x, y, self.size.x, h, style.selection)
  common.draw_text(font, style.accent,
    (p.name == "bash" and "run: " or "apply: ") .. (p.summary or p.name),
    "left", x, y, w, lh)
  common.draw_text(font, style.dim,
    "[a]pprove   [r]eject   shift+[A] always allow this session",
    "left", x, y + lh, w, lh)
  return h
end

function AgentView:draw()
  self:draw_background(style.background)
  local font = style.code_font
  local lh = font:get_height() * config.line_height
  local pad = style.padding.x
  local x = self.position.x + pad
  local w = self.size.x - pad * 2
  -- code_font is monospace, so a width in pixels is a width in characters.
  local cols = math.max(8, math.floor(w / font:get_width("0")))
  local voff = (lh - font:get_height()) / 2

  -- input height grows with the draft, bounded so it never eats the transcript
  local input_lines = math.min(#self.lines, 8)
  local input_h = lh * input_lines + style.padding.y * 2
  local pending_h = self.pending and (lh * 2) or 0
  local body_bottom = self.position.y + self.size.y - input_h - pending_h

  local y = self.position.y + style.padding.y - self.scroll.y

  for _, e in ipairs(self.entries) do
    if e.role == "diff" and e.diff then
      -- Rendered rather than described: a diff is the one thing worth the
      -- vertical space, because it is what you are actually approving.
      common.draw_text(font, style.dim, difflib.summary(e.diff, e.path or ""),
        "left", x, y, w, lh)
      y = y + lh
      for _, row in ipairs(e.diff.hunk) do
        local kind, text = row[1], row[2]
        local col = (kind == "+" and style.good) or (kind == "-" and style.error)
                    or style.dim
        if y + lh > self.position.y and y < body_bottom then
          common.draw_text(font, col or style.text, kind .. " " .. text,
            "left", x, y, w, lh)
        end
        y = y + lh
      end
    else
      for i, row in ipairs(self:layout(e, cols)) do
        if y + lh > self.position.y and y < body_bottom then
          local tx = x
          for _, t in ipairs(row) do
            tx = renderer.draw_text(font, t[2], tx, y + voff, t[1])
          end
        end
        y = y + lh
        if i > 600 then break end
      end
    end
    y = y + lh * 0.25
  end
  self.content_height = (y + self.scroll.y) - self.position.y + input_h + pending_h

  -- follow the tail while streaming, unless the user has scrolled up
  if self.scroll_to_end then
    self.scroll_to_end = false
    local max = math.max(0, self.content_height - self.size.y)
    if self.scroll.to.y > max - lh * 6 or self.busy then
      self.scroll.to.y = max
    end
  end

  if self.pending then
    self:draw_pending(x, body_bottom, w, lh, font)
  end

  -- input
  local iy = self.position.y + self.size.y - input_h
  renderer.draw_rect(self.position.x, iy, self.size.x, input_h, style.line_highlight)
  local ty = iy + style.padding.y
  for i = 1, input_lines do
    local line = self.lines[i] or ""
    local prefix = (i == 1)
      and (self.busy and ("[" .. self.status .. "] ") or "› ") or "  "
    local shown = prefix .. line
    if i == self.cy and not self.busy then
      shown = prefix .. line:sub(1, self.cx - 1) .. "|" .. line:sub(self.cx)
    end
    common.draw_text(font, self.busy and style.dim or style.text,
      shown, "left", x, ty, w, lh)
    ty = ty + lh
  end

  self:draw_scrollbar()
end

return AgentView
