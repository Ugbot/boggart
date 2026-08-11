-- agentview.lua -- the agent panel.
--
-- A lite View that talks to boggart. The whole integration rests on one
-- inversion, the same one lua/dash.lua uses for the terminal dashboard: the
-- editor owns the frame loop and pumps the agent, never the other way round.
-- lite calls update() ~60 times a second; each call turns the agent's
-- coroutine a little and returns immediately. Nothing here ever blocks, so a
-- model thinking for thirty seconds cannot freeze the window.
--
-- The agent runs as a coroutine rather than a thread because boggart's whole
-- transport is already built to yield: api.stream_async yields ("io", req) and
-- proc.run yields ("proc", handle). We resume it, it does a slice of work and
-- yields, we draw a frame. That is the entire trick.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local keymap = require "core.keymap"
local View = require "core.view"

local AgentView = View:extend()

-- Roles, and how they read on screen.
local ROLE = {
  user      = { prefix = "› ",  color = "accent" },
  assistant = { prefix = "",    color = "text" },
  tool      = { prefix = "» ",  color = "keyword" },
  error     = { prefix = "!! ", color = "error" },
  system    = { prefix = "·  ", color = "dim" },
}

function AgentView:new()
  AgentView.super.new(self)
  self.scrollable = true
  self.entries = {}        -- { role, text, tool }
  self.input = ""
  self.busy = false
  self.co = nil            -- the running agent coroutine
  self.status = "idle"
  self.pending_scroll = true
  self:push("system", "boggart " .. (bog and bog.version or "?")
    .. "  model=" .. self:model() .. "   (type a task and press return)")
  if bog and not self:has_creds() then
    self:push("system",
      "No credentials yet. Use the command palette: 'agent: set api key',")
    self:push("system",
      "or 'agent: set endpoint' for a local server such as ds4 on :8000.")
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
  return self.busy and "Agent ●" or "Agent"
end

function AgentView:push(role, text, tool)
  self.entries[#self.entries + 1] = { role = role, text = text or "", tool = tool }
  self.pending_scroll = true
  core.redraw = true
end

-- Streamed text arrives token by token; append to the open assistant entry
-- rather than creating one per delta, or the transcript becomes confetti.
function AgentView:stream(chunk)
  local last = self.entries[#self.entries]
  if last and last.role == "assistant" and last.open then
    last.text = last.text .. chunk
  else
    self.entries[#self.entries + 1] =
      { role = "assistant", text = chunk, open = true }
  end
  self.pending_scroll = true
  core.redraw = true
end

function AgentView:close_stream()
  local last = self.entries[#self.entries]
  if last then last.open = nil end
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
  self:push("user", text)
  self.busy, self.status = true, "thinking"

  -- The turn runs inside a coroutine so api.run_on's yields ("io" while an
  -- HTTP body streams, "proc" while a child process runs) suspend *this*
  -- rather than the editor. update() below resumes it once per frame.
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
          self:push("tool", name .. hint, name)
          -- A tool that edits a file should show up in the editor immediately,
          -- otherwise you are reading a stale buffer while the agent works.
          if name == "write" or name == "edit" then
            self.dirty_path = type(input) == "table" and input.path or nil
          end
        end,
      })
    self:close_stream()
    if not okrun then
      -- Typed boggart errors already carry an actionable explanation; a raw
      -- one gets the generic prefix. Same distinction the CLI makes.
      if type(err) == "table" and err.boggart_error then
        self:push("error", tostring(err))
      else
        self:push("error", tostring(err))
      end
    end
    self.busy, self.status = false, "idle"
    if bog.save_session then pcall(bog.save_session) end
    core.redraw = true
  end)
end

function AgentView:cancel()
  if not self.busy then return end
  self.co = nil
  self.busy, self.status = false, "idle"
  self:close_stream()
  self:push("system", "cancelled")
end

-- One slice of agent work per frame. This is the load-bearing function: it
-- must always return quickly, whatever the agent is doing.
function AgentView:tick()
  if not self.co then return end
  if coroutine.status(self.co) == "dead" then self.co = nil; return end

  local ok, kind, arg = coroutine.resume(self.co)
  if not ok then
    self:push("error", tostring(kind))
    self.co, self.busy, self.status = nil, false, "idle"
    return
  end

  -- Advance whichever engine the agent is waiting on, without blocking:
  -- curl for HTTP, the libuv loop for subprocesses, MCP pipes and timers.
  if kind == "io" then
    self.status = "streaming"
    pcall(http.pump, 0)
  elseif kind == "proc" then
    self.status = "running a command"
    local okuv, uv = pcall(require, "uv")
    if okuv then pcall(uv.run, "nowait") end
  end

  -- A file the agent just wrote should be reloaded if it is open.
  if self.dirty_path then
    local path, doc = self.dirty_path, nil
    self.dirty_path = nil
    for _, d in ipairs(core.docs) do
      if d.filename and d.filename:find(path, 1, true) then doc = d end
    end
    if doc and not doc:is_dirty() then pcall(function() doc:reload() end) end
  end
end

function AgentView:update()
  self:tick()
  -- Keep the loop warm while the agent works, so streamed tokens appear
  -- promptly rather than waiting for the next input event.
  if self.busy then core.redraw = true end
  AgentView.super.update(self)
end

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

function AgentView:on_text_input(text)
  self.input = self.input .. text
  core.redraw = true
end

function AgentView:on_key_pressed(key)
  if key == "return" then
    local t = self.input
    self.input = ""
    self:submit(t)
    return true
  elseif key == "backspace" then
    self.input = self.input:sub(1, -2)
    core.redraw = true
    return true
  elseif key == "escape" then
    self:cancel()
    return true
  end
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

local function wrap(text, font, width)
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line == "" then out[#out + 1] = "" end
    local cur = ""
    for word in line:gmatch("%S+%s*") do
      local try = cur .. word
      if font:get_width(try) > width and cur ~= "" then
        out[#out + 1] = cur
        cur = word
      else
        cur = try
      end
    end
    if cur ~= "" then out[#out + 1] = cur end
  end
  return out
end

function AgentView:get_scrollable_size()
  return self.content_height or math.huge
end

function AgentView:draw()
  self:draw_background(style.background)
  local font = style.code_font
  local lh = font:get_height() * config.line_height
  local pad = style.padding.x
  local x = self.position.x + pad
  local w = self.size.x - pad * 2
  local y = self.position.y + style.padding.y - self.scroll.y

  -- input bar reserves the last two lines
  local input_h = lh + style.padding.y * 2

  for _, e in ipairs(self.entries) do
    local r = ROLE[e.role] or ROLE.assistant
    local color = style[r.color] or style.text
    for i, line in ipairs(wrap(r.prefix .. e.text, font, w)) do
      if y + lh > self.position.y and y < self.position.y + self.size.y - input_h then
        common.draw_text(font, color, line, "left", x, y, w, lh)
      end
      y = y + lh
      if i > 400 then break end -- a runaway entry must not stall the frame
    end
    y = y + lh * 0.25
  end
  self.content_height = (y + self.scroll.y) - self.position.y + input_h

  -- input bar, pinned to the bottom
  local iy = self.position.y + self.size.y - input_h
  renderer.draw_rect(self.position.x, iy, self.size.x, input_h, style.line_highlight)
  local prompt = self.busy and ("[" .. self.status .. "]  ") or "› "
  common.draw_text(font, self.busy and style.dim or style.accent,
    prompt .. self.input .. (self.busy and "" or "_"),
    "left", x, iy + style.padding.y, w, lh)

  self:draw_scrollbar()
end

return AgentView
