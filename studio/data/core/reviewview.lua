-- reviewview.lua -- one place to review every unreviewed edit across the whole
-- project, not one buffer at a time.
--
-- Marks live per buffer (core/marks.lua): each agent edit lays a "hunk" group on
-- the file it touched. Until now the only way to review them was to open each
-- file and walk its marks -- so a fleet that edited ten files gave you ten
-- places to remember to look. This view reads marks.review() (every saved file
-- carrying marks, with its hunk groups) and turns it into a single list: "N
-- hunks in M files", walk to any of them, or accept them all at once. Accepting
-- keeps whatever the buffer now says and just clears the marks; reverting (per
-- hunk, in the buffer) is still the way to undo.
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"
local widgets = require "core.widgets"
local marks = require "core.marks"

local ReviewView = View:extend()

function ReviewView:new()
  ReviewView.super.new(self)
  self.scrollable = true
  self.hits = {}
  self.hover = nil
  self:refresh()
end

function ReviewView:get_name() return "Review" end

function ReviewView:refresh()
  self.files = marks.review()
  self.total_hunks = 0
  for _, f in ipairs(self.files) do self.total_hunks = self.total_hunks + f.hunks end
  core.redraw = true
end

-- update() runs every frame; keep the list live as the agent edits or hunks are
-- accepted elsewhere, but only rebuild when the mark count actually changed.
function ReviewView:update()
  ReviewView.super.update(self)
  local n = 0
  for _, f in ipairs(marks.review()) do n = n + f.hunks end
  if n ~= (self.total_hunks or -1) then self:refresh() end
end

-- Open `path` and put the caret on `line` so the hunk is on screen for review.
local function walk_to(path, line)
  local ok, doc = pcall(core.open_doc, path)
  if not ok or not doc then core.error("can't open %s", path); return end
  core.root_view:open_doc(doc)
  pcall(function() doc:set_selection(math.max(1, line or 1), 1) end)
end

-- Accept every hunk in every file: open each buffer and clear its marks (accept
-- preserves the text, so this commits the edits as they stand).
function ReviewView:accept_all()
  local n = 0
  for _, f in ipairs(self.files) do
    local ok, doc = pcall(core.open_doc, f.path)
    if ok and doc then
      local gone = marks.accept_all(doc)
      n = n + (tonumber(gone) or 0)
    end
  end
  self:refresh()
  core.log("accepted %d hunk(s) across %d file(s)", n, #self.files)
end

local KIND_MARK = { added = "+", changed = "~", removed = "-", info = "\u{2022}", error = "!" }

function ReviewView:draw()
  self:draw_background(style.background)
  local font = style.code_font
  local lh = font:get_height() * config.line_height
  local pad, vpad = style.padding.x, style.padding.y
  local bh = widgets.height(font)
  self.hits = {}
  local ox, oy = self:get_content_offset()
  local x = self.position.x + pad
  local y = oy + vpad

  local function add(hit, id, action)
    hit.item = { id = id, action = action }
    self.hits[#self.hits + 1] = hit
  end

  -- Header + the one global control.
  local files = self.files or {}
  local head = (#files == 0) and "No unreviewed edits"
    or string.format("%d hunk%s in %d file%s", self.total_hunks,
      self.total_hunks == 1 and "" or "s", #files, #files == 1 and "" or "s")
  common.draw_text(font, style.accent, head, "left", x, y, self.size.x - pad * 2, lh)
  if #files > 0 then
    local hit = widgets.button(font, "Accept all", self.position.x + self.size.x - pad - 120, y,
      { w = 120, hover = self.hover == "accept_all" })
    add(hit, "accept_all", function() self:accept_all() end)
  end
  y = y + lh + vpad

  -- One block per file: its name, then a row per hunk (kind + line), each a
  -- click target that walks you to it.
  for _, f in ipairs(files) do
    local name = f.path:match("[^/\\]+$") or f.path
    common.draw_text(font, style.text, name .. "  ", "left", x, y, self.size.x, lh)
    common.draw_text(font, style.dim, f.path, "left",
      x + font:get_width(name .. "   "), y, self.size.x, lh)
    y = y + lh
    for _, g in ipairs(f.groups) do
      local mk = KIND_MARK[g.kind] or "\u{2022}"
      local col = marks.color(g.kind) or style.dim
      local label = string.format("   %s  line %d", mk, g.line)
      local hovered = self.hover == g.group .. f.path
      if hovered then
        renderer.draw_rect(self.position.x, y, self.size.x, lh, style.line_highlight)
      end
      common.draw_text(font, col, label, "left", x, y, self.size.x - pad * 2, lh)
      local path, line = f.path, g.line
      add({ x = self.position.x, y = y, w = self.size.x, h = lh },
        g.group .. f.path, function() walk_to(path, line) end)
      y = y + lh
    end
    y = y + vpad
  end
  self.scroll_h = (y - oy) + vpad
end

function ReviewView:get_scrollable_size() return self.scroll_h or self.size.y end

function ReviewView:on_mouse_moved(x, y, dx, dy)
  ReviewView.super.on_mouse_moved(self, x, y, dx, dy)
  local item = widgets.hit(self.hits, x, y)
  local was = self.hover
  self.hover = item and item.id or nil
  if was ~= self.hover then core.redraw = true end
end

function ReviewView:on_mouse_pressed(button, x, y, clicks)
  if ReviewView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  core.set_active_view(self)
  local item = widgets.hit(self.hits, x, y)
  if item and item.action then item.action() end
  core.redraw = true
  return true
end

return ReviewView
