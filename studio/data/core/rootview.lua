local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local keymap = require "core.keymap"
local Tree = require "bmux.tree"
local View = require "core.view"
local DocView = require "core.docview"


-- Which view class renders a given Doc: Markdown files open as a rendered
-- preview (MarkdownView), everything else as an editable DocView. Guarded so a
-- broken or absent MarkdownView never stops a file opening, and lazy-required so
-- there is no load-time cycle (markdownview -> docview -> ...).
local function view_class_for(doc)
  local name = doc and doc.filename or ""
  local ext = name:lower():match("%.([%w]+)$")
  if (ext == "md" or ext == "markdown") and config.markdown_preview ~= false then
    local ok, MarkdownView = pcall(require, "core.markdownview")
    if ok and MarkdownView then return MarkdownView end
  end
  return DocView
end


local EmptyView = View:extend()

local function draw_text(x, y, color)
  local th = style.big_font:get_height()
  local dh = th + style.padding.y * 2
  x = renderer.draw_text(style.big_font, "boggart", x, y + (dh - th) / 2, color)
  x = x + style.padding.x
  renderer.draw_rect(x, y, math.ceil(1 * SCALE), dh, color)
  local lines = {
    { fmt = "%s to run a command", cmd = "core:find-command" },
    { fmt = "%s to open a file from the project", cmd = "core:find-file" },
  }
  th = style.font:get_height()
  y = y + (dh - th * 2 - style.padding.y) / 2
  local w = 0
  for _, line in ipairs(lines) do
    local text = string.format(line.fmt, keymap.get_binding(line.cmd))
    w = math.max(w, renderer.draw_text(style.font, text, x + style.padding.x, y, color))
    y = y + th + style.padding.y
  end
  return w, dh
end

function EmptyView:draw()
  self:draw_background(style.background)
  local w, h = draw_text(0, 0, { 0, 0, 0, 0 })
  local x = self.position.x + math.max(style.padding.x, (self.size.x - w) / 2)
  local y = self.position.y + (self.size.y - h) / 2
  draw_text(x, y, style.dim)
end


-- These are the shared model nodes themselves; only presentation and host
-- callbacks below depend on Studio. No mirrored content tree is maintained.
local Node = Tree.class {
  empty = function() return EmptyView() end,
  is_empty = function(view) return view:is(EmptyView) end,
  focused = function() return core.active_view end,
  focus = function(view) core.set_active_view(view) end,
  close = function(view, done) view:try_close(done) end,
  after_close = function() core.last_active_view = nil end,
  divider = function() return style.divider_size end,
  locked_size = function(view)
    -- Dock animations expose their destination size so hidden and visible
    -- columns never overlap for a frame while the rail changes.
    if view.get_target_size then
      local x, y = view:get_target_size("x"), view:get_target_size("y")
      if x ~= nil or y ~= nil then return x or view.size.x, y or view.size.y end
    end
    return view.size.x, view.size.y
  end,
  arrange_leaf = function(node) node:layout_leaf() end,
}


function Node:propagate(fn, ...)
  self.a[fn](self.a, ...)
  self.b[fn](self.b, ...)
end


function Node:on_mouse_moved(x, y, ...)
  self.hovered_tab = self:get_tab_overlapping_point(x, y)
  self.hovered_close = nil
  if self.hovered_tab then
    local cx, cy, cs = self:get_tab_close_rect(self.hovered_tab)
    if x >= cx and x < cx + cs and y >= cy and y < cy + cs then
      self.hovered_close = self.hovered_tab
    end
  end
  if self.type == "leaf" then
    self.active_view:on_mouse_moved(x, y, ...)
  else
    self:propagate("on_mouse_moved", x, y, ...)
  end
end


function Node:on_mouse_released(...)
  if self.type == "leaf" then
    self.active_view:on_mouse_released(...)
  else
    self:propagate("on_mouse_released", ...)
  end
end


function Node:get_divider_overlapping_point(px, py)
  if self.type ~= "leaf" then
    local p = 6
    local x, y, w, h = self:get_divider_rect()
    x, y = x - p, y - p
    w, h = w + p * 2, h + p * 2
    if px > x and py > y and px < x + w and py < y + h then
      return self
    end
    return self.a:get_divider_overlapping_point(px, py)
        or self.b:get_divider_overlapping_point(px, py)
  end
end


-- Whether this leaf shows a tab strip.
--
-- Docked panels (locked) and the EmptyView splash never do. A destination
-- surface -- the conversation, settings, the swarm -- is the stage itself, not
-- a tab next to a file. Files still get a strip (even a single one) so the
-- open document is named and closable.
function Node:should_show_tabs()
  if self.type ~= "leaf" or self.locked then return false end
  if self.active_view:is(EmptyView) and #self.views <= 1 then return false end
  if #self.views > 1 then return true end
  -- A single non-empty, non-docked view still gets a strip so it is named and
  -- closable -- a lone log or search view was otherwise stuck open with no tab
  -- and no close affordance.
  return not self.active_view:is(EmptyView)
end


-- One source of truth for the tab strip's geometry, shared by draw and
-- hit-testing so they cannot disagree. Tabs never shrink below MIN_TAB_WIDTH;
-- when they would overflow the strip we show a scrolled window of them (kept
-- around the active tab) with chevrons marking the hidden ones.
local MIN_TAB_WIDTH = 80
function Node:tab_metrics()
  local n = #self.views
  local avail = self.size.x
  local tw = math.max(MIN_TAB_WIDTH,
    math.min(style.tab_width, math.ceil(avail / math.max(1, n))))
  local nfit = math.max(1, math.floor(avail / tw))
  local first = math.max(1, math.min(self.tab_scroll or 1, math.max(1, n - nfit + 1)))
  -- Keep the active tab inside the visible window.
  local ai
  for i, v in ipairs(self.views) do if v == self.active_view then ai = i; break end end
  if ai then
    if ai < first then first = ai
    elseif ai > first + nfit - 1 then first = ai - nfit + 1 end
    first = math.max(1, math.min(first, math.max(1, n - nfit + 1)))
  end
  self.tab_scroll = first
  local last = math.min(n, first + nfit - 1)
  return tw, first, last, nfit
end


function Node:get_tab_overlapping_point(px, py)
  if not self:should_show_tabs() then return nil end
  local tw, first, last = self:tab_metrics()
  local _, _, _, h = self:get_tab_rect(first)
  local x0 = self.position.x
  if py < self.position.y or py >= self.position.y + h or px < x0 then return nil end
  local idx = first + math.floor((px - x0) / tw)
  if idx >= first and idx <= last then return idx end
  return nil
end


-- The close box on a tab, right-aligned inside it. Returned separately so the
-- click handler can consume a hit on it before selecting the tab.
function Node:get_tab_close_rect(idx)
  local x, y, w, h = self:get_tab_rect(idx)
  local s = style.font:get_height()
  return x + w - s - math.floor(style.padding.x / 2), y + math.floor((h - s) / 2), s, s
end


function Node:get_tab_rect(idx)
  local tw = math.max(MIN_TAB_WIDTH,
    math.min(style.tab_width, math.ceil(self.size.x / math.max(1, #self.views))))
  local first = self.tab_scroll or 1
  local h = style.font:get_height() + style.padding.y * 2
  -- idx is the absolute tab index; place it relative to the first visible tab so
  -- off-window tabs land off the strip (and so never hit-test).
  return self.position.x + (idx - first) * tw, self.position.y, tw, h
end


local function copy_position_and_size(dst, src)
  dst.position.x, dst.position.y = src.position.x, src.position.y
  dst.size.x, dst.size.y = src.size.x, src.size.y
end


-- The shared model assigns pane bounds; Studio reserves its tab strip here.
function Node:layout_leaf()
  local av = self.active_view
  if self:should_show_tabs() then
    local _, _, _, th = self:get_tab_rect(1)
    av.position.x, av.position.y = self.position.x, self.position.y + th
    av.size.x, av.size.y = self.size.x, math.max(0, self.size.y - th)
  else
    copy_position_and_size(av, self)
  end
end


function Node:update()
  if self.type == "leaf" then
    for _, view in ipairs(self.views) do
      view:update()
    end
  else
    self.a:update()
    self.b:update()
  end
end


function Node:draw_tabs()
  local tw, first, last = self:tab_metrics()
  local ox, oy = self.position.x, self.position.y
  local ds = style.divider_size
  local h = style.font:get_height() + style.padding.y * 2
  core.push_clip_rect(ox, oy, self.size.x, h)
  renderer.draw_rect(ox, oy, self.size.x, h, style.background2)
  renderer.draw_rect(ox, oy + h - ds, self.size.x, ds, style.divider)

  for i = first, last do
    local view = self.views[i]
    local x, y, w = self:get_tab_rect(i)
    local text = view:get_name()
    local color = style.dim
    if view == self.active_view then
      color = style.text
      renderer.draw_rect(x, y, w, h, style.background)
      renderer.draw_rect(x + w, y, ds, h, style.divider)
      renderer.draw_rect(x - ds, y, ds, h, style.divider)
    end
    if i == self.hovered_tab then color = style.text end
    core.push_clip_rect(x, y, w, h)
    -- Close box (×), painted on the active or hovered tab; its hit region is
    -- consistent for every tab so a click there closes regardless of paint.
    local show_close = (view == self.active_view or i == self.hovered_tab)
    local cw = show_close and (style.font:get_height() + style.padding.x) or 0
    if show_close then
      local cx, cy, cs = self:get_tab_close_rect(i)
      common.draw_text(style.font,
        i == self.hovered_close and style.text or style.dim,
        "\u{00d7}", "center", cx, cy, cs, cs)
    end
    local tx, tw2 = x + style.padding.x, w - style.padding.x * 2 - cw
    local align = style.font:get_width(text) > tw2 and "left" or "center"
    common.draw_text(style.font, color, text, align, tx, y, tw2, h)
    core.pop_clip_rect()
  end

  -- Chevrons for tabs scrolled out of view on either side.
  if first > 1 then
    common.draw_text(style.font, style.dim, "\u{2039}", "left",
      ox + style.padding.x / 2, oy, tw, h)
  end
  if last < #self.views then
    common.draw_text(style.font, style.dim, "\u{203a}", "right",
      ox + self.size.x - tw - style.padding.x / 2, oy, tw, h)
  end

  core.pop_clip_rect()
end


function Node:draw()
  if self.type == "leaf" then
    if self:should_show_tabs() then
      self:draw_tabs()
    end
    local pos, size = self.active_view.position, self.active_view.size
    -- Integer clip: the GPU path sizes the backbuffer in window pixels, so the
    -- old software-surface `pos % 1` fudge no longer has a fractional origin
    -- to correct and would only widen the clip into the next view.
    core.push_clip_rect(pos.x, pos.y, size.x, size.y)
    self.active_view:draw()
    core.pop_clip_rect()
  else
    local x, y, w, h = self:get_divider_rect()
    renderer.draw_rect(x, y, w, h, style.divider)
    self:propagate("draw")
  end
end


local RootView = View:extend()

function RootView:new()
  RootView.super.new(self)
  self.root_node = Node()
  self.deferred_draws = {}
  self.mouse = { x = 0, y = 0 }
end


function RootView:defer_draw(fn, ...)
  table.insert(self.deferred_draws, 1, { fn = fn, ... })
end


function RootView:get_primary_node()
  return self.root_node:get_primary_node() or self.root_node
end


function RootView:get_active_node()
  return self.root_node:get_node_for_view(core.active_view)
end


-- Open `view` in a new split of the active pane, in direction dir (left/right/
-- up/down). The thin primitive later phases (a terminal in a split, an agent
-- routing a result into a pane) build on, rather than each re-opening the doc.
function RootView:open_view_in(dir, view)
  local node = self:get_active_node()
  if not node or (node.get_locked_size and node:get_locked_size()) then
    node = self.root_node:get_node_for_view(core.last_active_view) or node
  end
  if not node then return end
  node:split(dir, view)
  core.set_active_view(view)
  return view
end


function RootView:open_doc(doc)
  local node = self:get_active_node()
  if node and node.locked and core.last_active_view then
    core.set_active_view(core.last_active_view)
    node = self:get_active_node()
  end
  -- The sidebar's node is locked and the sidebar is a view you can be focused
  -- in, so this is reachable by clicking: its own "Open a file..." button
  -- leaves focus in the rail, and by the time the file is chosen the command
  -- view that briefly held focus has closed, which makes last_active_view the
  -- rail again. That asserted, so the button threw instead of opening a file.
  --
  -- Land in the primary node, which is where documents belong regardless of
  -- what happened to have focus when the request was made.
  if not node or node.locked then
    node = self:get_primary_node()
    if node.active_view then core.set_active_view(node.active_view) end
  end
  assert(not node.locked, "Cannot open doc on locked node")
  for i, view in ipairs(node.views) do
    if view.doc == doc then
      node:set_active_view(node.views[i])
      return view
    end
  end
  local view = view_class_for(doc)(doc)
  node:add_view(view)
  self.root_node:update_layout()
  -- Only a DocView has a caret to scroll to; a rendered view (Markdown) does not.
  if view.scroll_to_line and view.doc and view.doc.get_selection then
    view:scroll_to_line(view.doc:get_selection(), true, true)
  end
  return view
end


function RootView:on_mouse_pressed(button, x, y, clicks)
  local div = self.root_node:get_divider_overlapping_point(x, y)
  if div then
    self.dragged_divider = div
    return
  end
  local node = self.root_node:get_child_overlapping_point(x, y)
  local idx = node:get_tab_overlapping_point(x, y)
  if idx then
    -- A left-click on the tab's × closes it (as does middle-click anywhere on
    -- the tab); otherwise the tab just becomes active.
    local cx, cy, cs = node:get_tab_close_rect(idx)
    local on_close = x >= cx and x < cx + cs and y >= cy and y < cy + cs
    if button == "middle" or (button == "left" and on_close) then
      node:close_view(node.views[idx],self.root_node)
    else node:set_active_view(node.views[idx]) end
  else
    node:set_active_view(node.active_view)
    node.active_view:on_mouse_pressed(button, x, y, clicks)
  end
end


function RootView:on_mouse_released(...)
  if self.dragged_divider then
    self.dragged_divider = nil
  end
  self.root_node:on_mouse_released(...)
end


-- A docked panel that can be resized by dragging its edge.
--
-- Docked panels are locked nodes, and a locked node takes its size from its
-- view rather than from the split ratio -- which is why dragging their divider
-- did nothing at all: the ratio moved and the layout ignored it. A view that
-- implements set_target_size(axis, value) is asking to be resized directly, so
-- the drag is handed to it instead.
--
-- Doing this here rather than inside the panel matters: the pointer leaves the
-- panel the instant you drag outward, and RootView is the only place that
-- keeps hold of a drag across that boundary.
local function resizable_panel(node)
  if node.type == "leaf" then return nil end
  for _, child in ipairs { node.a, node.b } do
    if child.type == "leaf" and child.locked and child.active_view
       and child.active_view.set_target_size then
      return child.active_view, child == node.a
    end
  end
end


function RootView:on_mouse_moved(x, y, dx, dy)
  if self.dragged_divider then
    local node = self.dragged_divider
    local panel, is_first = resizable_panel(node)
    if panel then
      local axis = (node.type == "hsplit") and "x" or "y"
      local delta = (axis == "x") and dx or dy
      if not is_first then delta = -delta end
      -- Against the panel's target size, not its current one. A panel that is
      -- still animating open reports a size somewhere in the middle of the
      -- transition, and moving the pointer one pixel would otherwise pin it
      -- there and throw the rest of the width away.
      local from = panel.get_target_size and panel:get_target_size(axis)
      panel:set_target_size(axis, (from or panel.size[axis]) + delta)
      return
    end
    node:resize_by(dx, dy)
    return
  end

  self.mouse.x, self.mouse.y = x, y
  self.root_node:on_mouse_moved(x, y, dx, dy)

  local node = self.root_node:get_child_overlapping_point(x, y)
  local div = self.root_node:get_divider_overlapping_point(x, y)
  if div then
    system.set_cursor(div.type == "hsplit" and "sizeh" or "sizev")
  elseif node:get_tab_overlapping_point(x, y) then
    system.set_cursor("arrow")
  else
    system.set_cursor(node.active_view.cursor)
  end
end


function RootView:on_mouse_wheel(amount,x,y,horizontal)
  x,y=x or self.mouse.x,y or self.mouse.y
  local node = self.root_node:get_child_overlapping_point(x, y)
  node.active_view:on_mouse_wheel(amount,x,y,horizontal)
end


function RootView:on_text_input(...)
  core.active_view:on_text_input(...)
end


function RootView:update()
  copy_position_and_size(self.root_node, self)
  self.root_node:update()
  self.root_node:update_layout()
end


function RootView:draw()
  self.root_node:draw()
  while #self.deferred_draws > 0 do
    local t = table.remove(self.deferred_draws)
    t.fn(table.unpack(t))
  end
end


-- Exposed so the shell can put an empty leaf back to the splash placeholder when
-- a workspace has no views (studio/data/shell isolates views per workspace).
RootView.EmptyView = EmptyView

return RootView
