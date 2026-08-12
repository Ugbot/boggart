-- panelview.lua -- hosts a panel the agent wrote.
--
-- The host's job is to make a generated panel safe to be wrong. A draw
-- function written by a model will sometimes index a nil, and a crash sixty
-- times a second inside the frame loop takes the whole window with it. So every
-- frame is a pcall, the error is drawn where the panel would have been, and
-- after a few consecutive failures the panel is switched off with a Retry
-- button rather than left thrashing.
--
-- It also reloads from disk. The point of letting the agent write interface is
-- the loop where it writes, looks, and adjusts; making that loop require a
-- restart would defeat it.
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"
local widgets = require "core.widgets"
local uisandbox = require "core.uisandbox"

local PanelView = View:extend()

function PanelView:new(name)
  PanelView.super.new(self)
  self.scrollable = false     -- a panel manages its own space
  self.name = name
  self.state = {}             -- the panel's own persisted table
  self.hits = {}
  self.errors = 0
  self.err = nil
  self.mtime = nil
  self:reload()
end

function PanelView:get_name() return self.name or "Panel" end

function PanelView:path()
  return bog.userdir .. "/ui/" .. self.name .. ".lua"
end

function PanelView:reload()
  local src = bog.util.read_file(self:path())
  if not src then
    self.draw_fn, self.err = nil, "no such panel: " .. tostring(self.name)
    return false
  end
  local fn, err = uisandbox.compile(self.name, src)
  self.draw_fn, self.err = fn, err
  self.errors = 0
  local _, mtime, size = sys.stat(self:path())
  self.mtime, self.size_seen = mtime, size
  core.redraw = true
  return fn ~= nil
end

-- Reload when the file changes, checked on a timer. Every frame would be a
-- stat() sixty times a second for a file that changes when a person or an agent
-- edits it, which is not a sixty-hertz event.
function PanelView:update()
  self.check_at = (self.check_at or 0) - 1
  if self.check_at <= 0 then
    self.check_at = 60
    local kind, mtime, size = sys.stat(self:path())
    if not kind then
      -- Deleted out from under us. The compiled function still works, and
      -- saying nothing would leave a panel on screen with no file behind it --
      -- editing which creates a new one that this view would then adopt.
      if not self.gone then
        self.gone = true
        self.err = "the file for this panel is gone: " .. self:path()
        self.draw_fn = nil
        core.redraw = true
      end
    elseif self.gone or mtime ~= self.mtime or size ~= self.size_seen then
      -- Size as well as mtime: sys.stat's mtime has one-second resolution, so
      -- two saves inside the same second looked identical and the second one
      -- was never picked up.
      self.gone = false
      self:reload()
    end
  end
  PanelView.super.update(self)
end

function PanelView:on_mouse_moved(x, y, dx, dy)
  PanelView.super.on_mouse_moved(self, x, y, dx, dy)
  self.mouse = { x = x, y = y }
  core.redraw = true
end

function PanelView:on_mouse_pressed(button, x, y, clicks)
  if PanelView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  core.set_active_view(self)
  -- Retry is the host's own control, so it is checked before the panel's.
  if self.retry_rect and widgets.inside(self.retry_rect, x, y) then
    self:reload()
    return true
  end
  for _, h in ipairs(self.hits) do
    if widgets.inside(h.rect, x, y) then
      -- Latched for exactly one frame: the panel asks "was my button pressed?"
      -- during its next draw, and gets one true.
      self.clicked = h.label
      core.redraw = true
      return true
    end
  end
  return true
end

function PanelView:draw()
  self:draw_background(style.background)
  local font = style.code_font
  local lh = font:get_height() * config.line_height
  local pad = style.padding.x
  local x, y = self.position.x + pad, self.position.y + style.padding.y
  local w, h = self.size.x - pad * 2, self.size.y - style.padding.y * 2

  if self.draw_fn and self.errors < uisandbox.MAX_ERRORS then
    local ctx, hits = uisandbox.context(self, x, y, w, h, self.mouse, font)
    -- Through uisandbox.run, not pcall. A pcall catches a generated panel that
    -- indexes a nil; it does nothing at all about one that loops forever or
    -- allocates in a loop, and either of those takes the window with it --
    -- including the error message and the Retry button that would have got it
    -- back. See uisandbox.run for why the bound yields instead of erroring.
    local ok, err = uisandbox.run(self.draw_fn, ctx)
    self.clicked = nil          -- the latch lasts exactly one frame
    if ok then
      self.hits = hits
      self.errors = 0
      self.err = nil
      return
    end
    self.errors = self.errors + 1
    self.err = tostring(err)
  end

  -- The failure state. Shown rather than logged: a panel that silently draws
  -- nothing is indistinguishable from a panel that works and has nothing to
  -- say, and the agent needs to be told which it is.
  self.hits = {}
  common.draw_text(font, style.error, "panel '" .. tostring(self.name) .. "' failed",
    "left", x, y, w, lh)
  y = y + lh
  for line in (tostring(self.err or "unknown error") .. "\n"):gmatch("(.-)\n") do
    if line ~= "" then
      common.draw_text(font, style.dim, line, "left", x, y, w, lh)
      y = y + lh
    end
  end
  y = y + lh
  if self.errors >= uisandbox.MAX_ERRORS then
    common.draw_text(font, style.dim,
      string.format("stopped after %d consecutive errors", self.errors),
      "left", x, y, w, lh)
    y = y + lh
  end
  self.retry_rect = widgets.button(font, "Retry", x, y, {
    hover = self.mouse and widgets.inside(
      { x = x, y = y, w = widgets.width(font, "Retry"), h = widgets.height(font) },
      self.mouse.x, self.mouse.y),
  })
end

return PanelView
