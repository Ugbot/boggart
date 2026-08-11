-- settingsview.lua -- credentials and configuration, as a screen you can see.
--
-- Everything here was already reachable from the command palette, one prompt at
-- a time. That is fine once you know the command names and hopeless before you
-- do: "where do I put my API key" should be answerable by looking, and a
-- sequence of modal prompts cannot show you what is currently set.
--
-- The API key is the reason this file is careful. boggart's credentials live in
-- C (src/lauth.c) and are write-only from Lua: this view can store a key and
-- can ask for a masked summary, but it cannot read one back. So the field never
-- displays a key -- it shows what C reports (a mask and where the value came
-- from), and typing in it replaces the stored value. That is not a UI
-- convention borrowed from password fields; it is the actual shape of the
-- capability, and the view would be lying if it looked any other way.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"
local widgets = require "core.widgets"

local SettingsView = View:extend()

-- One spelling of "nothing here yet", because the layout dims a field on this
-- exact string and two spellings would drift apart.
local NOT_SET = "not set"

-- What C is willing to say about the key. l_masked answers "(unset)" when there
-- is none, which is a sentinel for the caller rather than a phrase to put in
-- front of a person, so it becomes nil here and the field says NOT_SET like
-- every other empty field does.
local function key_summary()
  local ok, masked, source = pcall(auth.masked)
  if not ok or not masked or masked == "" or masked == "(unset)" then return nil end
  return masked, source
end

-- Text that does not fit is elided rather than drawn past its box. This view
-- does not clip, and the credentials path -- which on a temporary HOME is long
-- -- was running off the right edge of the window entirely.
local function elide(font, text, width)
  if font:get_width(text) <= width then return text end
  local lo, hi = 0, #text
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if font:get_width(text:sub(1, mid) .. "...") <= width then lo = mid else hi = mid - 1 end
  end
  return text:sub(1, lo) .. "..."
end

function SettingsView:new()
  SettingsView.super.new(self)
  self.scrollable = true
  self.focus = nil       -- index of the field being edited
  self.buffer = ""
  self.hits = {}
  self.notice = nil
end

function SettingsView:get_name() return "Settings" end

-- The fields, described rather than drawn, so the layout and the behaviour
-- cannot disagree about what exists.
function SettingsView:fields()
  local masked, source = key_summary()
  return {
    {
      key = "api_key",
      label = "API key",
      value = masked or NOT_SET,
      -- The environment case is called out rather than summarised, because it
      -- is the one where storing a key here changes nothing: C prefers
      -- ANTHROPIC_API_KEY over the file, and a form that quietly accepted a
      -- value the process would then ignore is worse than no form at all.
      hint = (source == "environment"
          and "ANTHROPIC_API_KEY is set, and the environment wins over anything stored here")
        or (source and "stored on this machine, and used for every request")
        or "sk-ant-... , or leave blank and set an endpoint below",
      secret = true,
      set = function(v)
        auth.set("api_key", v)
        if bog.api.forget_auth then bog.api.forget_auth() end
        local m, src = key_summary()
        if src == "environment" then
          return nil, "stored, but ANTHROPIC_API_KEY is still the key being sent"
        end
        return "key stored (" .. (m or "?") .. ")"
      end,
      clear = function()
        auth.clear("api_key")
        if bog.api.forget_auth then bog.api.forget_auth() end
        if auth.has_key() then
          return nil, "cleared here -- ANTHROPIC_API_KEY still supplies one"
        end
        return "key cleared"
      end,
    },
    {
      key = "base_url",
      label = "Endpoint",
      value = auth.base_url() or "https://api.anthropic.com",
      hint = "a local server speaking /v1/messages, e.g. http://127.0.0.1:8000",
      set = function(v)
        auth.set("base_url", v)
        if bog.api.forget_auth then bog.api.forget_auth() end
        return "endpoint: " .. bog.api.endpoint()
      end,
      clear = function()
        auth.clear("base_url")
        if bog.api.forget_auth then bog.api.forget_auth() end
        return "using the Anthropic API"
      end,
    },
    {
      key = "model",
      label = "Model",
      -- The session's model, not the stored one, because the session is what
      -- the next request will actually use; the stored value is only where a
      -- fresh session starts from.
      value = (bog.session and bog.session.model) or auth.model() or NOT_SET,
      hint = "claude-opus-5, or whatever your endpoint serves",
      set = function(v)
        auth.set("model", v)
        if bog.session then bog.session.model = v end
        return "model: " .. v
      end,
    },
    {
      key = "context",
      label = "Context window",
      value = tostring(bog.api.context_limit(bog.session)) .. " tokens",
      hint = string.format("compacts at %d%%; blank to use the default for the model",
        (bog.api.COMPACT_RATIO or 0.8) * 100),
      set = function(v)
        local n = tonumber(v)
        if not n or n < 1000 then
          return nil, ("%q is not a token count -- give a number, at least 1000"):format(v)
        end
        bog.session.context_limit = math.floor(n)
        return "context window: " .. math.floor(n)
      end,
      clear = function()
        bog.session.context_limit = nil
        return "context window: back to the model default"
      end,
    },
  }
end

-- The result of a set or a clear, in the form pcall leaves it. A field that
-- refuses returns nil plus the reason, and the reason is the only useful part:
-- "not accepted" tells you nothing the wrong value on screen has not already.
-- Refusal is the right channel for a value that was written and then ignored --
-- an API key shadowed by the environment leaves the field looking correct and
-- the request still going out under someone else's credential.
function SettingsView:report(ok, msg, why)
  if not ok then self.notice = { text = tostring(msg), bad = true }
  elseif msg == nil then self.notice = { text = why or "not accepted", bad = true }
  else self.notice = { text = msg } end
  core.redraw = true
end

function SettingsView:commit()
  local f = self:fields()[self.focus or 0]
  if not f then return end
  local value = self.buffer
  self.focus, self.buffer = nil, ""
  if value == "" then return end
  self:report(pcall(f.set, value))
end

function SettingsView:edit(i)
  self.focus = i
  self.buffer = ""
  core.set_active_view(self)
  core.redraw = true
end

function SettingsView:on_text_input(text)
  if self.focus then self.buffer = self.buffer .. text; core.redraw = true end
end

function SettingsView:on_key_pressed(key)
  if not self.focus then return false end
  if key == "escape" then
    self.focus, self.buffer = nil, ""
  elseif key == "return" then
    self:commit()
  elseif key == "backspace" then
    self.buffer = self.buffer:sub(1, -2)
  elseif key == "tab" then
    local n = #self:fields()
    local next_i = (self.focus % n) + 1
    self:commit()
    self:edit(next_i)
  else
    return false
  end
  core.redraw = true
  return true
end

function SettingsView:on_mouse_moved(x, y, dx, dy)
  SettingsView.super.on_mouse_moved(self, x, y, dx, dy)
  self.mouse = { x = x, y = y }
  local item = widgets.hit(self.hits, x, y)
  local was = self.hover
  self.hover = item and item.id or nil
  if was ~= self.hover then core.redraw = true end
  self.cursor = item and "arrow" or "ibeam"
end

function SettingsView:on_mouse_pressed(button, x, y, clicks)
  if SettingsView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  core.set_active_view(self)
  local item = widgets.hit(self.hits, x, y)
  if item and item.action then item.action() end
  return true
end

function SettingsView:draw()
  self:draw_background(style.background)
  local font = style.code_font
  local lh = font:get_height() * config.line_height
  local pad = style.padding.x
  local vpad = style.padding.y
  local bh = widgets.height(font)
  self.hits = {}
  local function add(hit, id, action) hit.item = { id = id, action = action }
    self.hits[#self.hits + 1] = hit end

  local w = math.min(self.size.x - pad * 2, 80 * font:get_width("0"))
  local x = self.position.x + math.max(pad, (self.size.x - w) / 2)
  local y = self.position.y + vpad * 2 - self.scroll.y

  -- The title advances by its own height, not by a multiple of the body line
  -- height: big_font is two and a half times the body font, so a body-sized box
  -- let it spill upwards into the tab bar.
  local title_font = style.big_font or font
  local th = title_font:get_height()
  common.draw_text(title_font, style.accent, "Settings", "left", x, y, w, th)
  y = y + th + lh

  local fields = self:fields()
  for i, f in ipairs(fields) do
    local editing = (self.focus == i)

    -- Label at text weight and value at accent: on this palette style.dim on
    -- style.background is around 1.5:1, which is fine for an aside and not for
    -- the word telling you which field you are looking at.
    common.draw_text(font, style.text, f.label, "left", x, y, w, lh)
    y = y + lh

    -- The value box. Editing shows the buffer and a caret; otherwise it shows
    -- what is stored -- masked, for the key, because that is all C will say.
    local boxh = lh + vpad
    local hovered = self.mouse and widgets.inside(
      { x = x, y = y, w = w, h = boxh }, self.mouse.x, self.mouse.y)
    renderer.draw_rect(x, y, w, boxh, style.background2)
    local border = editing and style.accent or (hovered and style.dim or style.divider)
    renderer.draw_rect(x, y, w, 1, border)
    renderer.draw_rect(x, y + boxh - 1, w, 1, border)
    renderer.draw_rect(x, y, 1, boxh, border)
    renderer.draw_rect(x + w - 1, y, 1, boxh, border)

    local shown, colour
    if editing then
      shown = (f.secret and string.rep("*", #self.buffer) or self.buffer) .. "|"
      colour = style.accent
    else
      shown = f.value
      colour = (f.value == NOT_SET) and style.dim or style.accent
    end
    common.draw_text(font, colour, elide(font, shown, w - pad * 1.5), "left",
      x + pad / 2, y, w - pad, boxh)
    add({ x = x, y = y, w = w, h = boxh }, "field" .. i, function() self:edit(i) end)
    y = y + boxh + vpad / 2

    local hint = editing and "enter to save, esc to cancel, tab for the next field" or f.hint
    common.draw_text(font, style.dim, elide(font, hint, w), "left", x, y, w, lh)
    y = y + lh

    if f.clear then
      y = y + vpad / 2
      local hov = self.mouse and widgets.inside(
        { x = x, y = y, w = widgets.width(font, "Clear"), h = bh },
        self.mouse.x, self.mouse.y)
      add(widgets.button(font, "Clear", x, y, { hover = hov, dim = true }),
        "clear" .. i, function() self:report(pcall(f.clear)) end)
      y = y + bh
    end
    y = y + vpad * 1.5
  end

  -- ---- actions -------------------------------------------------------------
  local actions = {
    { label = "Test connection", action = function()
        -- Reuses the agent's own path rather than a private probe: the turn
        -- loop already classifies auth, endpoint and model failures with the
        -- message you would want, and a second code path could disagree.
        local v = core.studio.open_agent()
        v:push("system", "testing " .. bog.api.endpoint() .. " ...")
        v:submit("Reply with the single word OK.")
      end },
    { label = "Permission mode", action = function()
        command.perform("agent:set-mode") end },
    { label = "MCP servers", action = function()
        command.perform("agent:list-mcp-servers") end },
    { label = "Close", action = function()
        local node = core.root_view:get_primary_node()
        node:close_active_view(core.root_view.root_node)
      end },
  }
  for _, hit in ipairs(widgets.row(font, actions, x, y, self.mouse)) do
    hit.item = { id = hit.item.label, action = hit.item.action }
    self.hits[#self.hits + 1] = hit
  end
  y = y + bh + vpad

  if self.notice then
    common.draw_text(font, self.notice.bad and style.error or style.good,
      elide(font, self.notice.text, w), "left", x, y, w, lh)
    y = y + lh
  end

  -- Where all this actually lives, because a settings screen that hides its
  -- own storage is asking to be mistrusted. Ruled off: without the line the
  -- footnote reads as another notice about whatever you just did.
  y = y + vpad * 1.5
  renderer.draw_rect(x, y, w, 1, style.divider)
  y = y + vpad
  local ok, path = pcall(auth.path)
  common.draw_text(font, style.dim, elide(font,
    "Credentials: " .. ((ok and path) or "?") .. "  (0600, never in the database)", w),
    "left", x, y, w, lh)
  y = y + lh
  common.draw_text(font, style.dim, elide(font,
    "The key is write-only from Lua -- this screen can set it, never read it.", w),
    "left", x, y, w, lh)
  y = y + lh

  self.content_height = (y + self.scroll.y) - self.position.y + vpad * 2
  self:draw_scrollbar()
end

return SettingsView
