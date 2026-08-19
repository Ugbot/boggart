local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local widgets = require "core.widgets"

config.treeview_size = 200 * SCALE

local function get_depth(filename)
  local n = 0
  for sep in filename:gmatch("[\\/]") do
    n = n + 1
  end
  return n
end


local TreeView = View:extend()

function TreeView:new()
  TreeView.super.new(self)
  self.scrollable = true
  self.visible = true
  self.init_size = true
  self.cache = {}
end


function TreeView:get_cached(item)
  local t = self.cache[item.filename]
  if not t then
    t = {}
    t.filename = item.filename
    t.abs_filename = system.absolute_path(item.filename)
    t.name = t.filename:match("[^\\/]+$")
    t.depth = get_depth(t.filename)
    self.cache[t.filename] = t
  end
  -- Not cached: a name can change what it is. Deleting a file and creating a
  -- directory with the same name used to leave the tree drawing a file icon for
  -- a directory that no longer opens, and it took a restart to fix.
  t.type = item.type
  return t
end


function TreeView:get_name()
  return "Project"
end


function TreeView:get_item_height()
  return style.font:get_height() + style.padding.y
end


function TreeView:check_cache()
  -- Invalidate the cached collapsed-subtree skips when the shape of the list
  -- changes. The list used to be a fresh table on every scan, so its identity
  -- was the signal; it is now patched in place, so the scanner counts structural
  -- edits instead and identity would never change again.
  local version = core.project_files_version
  if version ~= self.last_version or core.project_files ~= self.last_project_files then
    for _, v in pairs(self.cache) do
      v.skip = nil
    end
    self.last_version = version
    self.last_project_files = core.project_files
  end
end


function TreeView:each_item()
  return coroutine.wrap(function()
    self:check_cache()
    local ox, oy = self:get_content_offset()
    local y = oy + style.padding.y
    local w = self.size.x
    local h = self:get_item_height()

    local i = 1
    while i <= #core.project_files do
      local item = core.project_files[i]
      local cached = self:get_cached(item)

      coroutine.yield(cached, ox, y, w, h)
      y = y + h
      i = i + 1

      if not cached.expanded then
        if cached.skip then
          i = cached.skip
        else
          local depth = cached.depth
          while i <= #core.project_files do
            local filename = core.project_files[i].filename
            if get_depth(filename) <= depth then break end
            i = i + 1
          end
          cached.skip = i
        end
      end
    end
  end)
end


function TreeView:on_mouse_moved(px, py)
  self.mouse = { x = px, y = py }
  self.hovered_item = nil
  local bh = widgets.height(style.font)
  local footer_top = self.position.y + self.size.y - bh - style.padding.y * 2
  for item, x,y,w,h in self:each_item() do
    if y + h > footer_top then break end
    if px > x and py > y and px <= x + w and py <= y + h then
      self.hovered_item = item
      break
    end
  end
end


function TreeView:on_mouse_pressed(button, x, y)
  local item = widgets.hit(self.hits, x, y)
  if item and item.action then item.action(); return true end
  if not self.hovered_item then
    return
  elseif self.hovered_item.type == "dir" then
    self.hovered_item.expanded = not self.hovered_item.expanded
  else
    core.try(function()
      core.root_view:open_doc(core.open_doc(self.hovered_item.filename))
    end)
  end
end


-- Same drag protocol as the sidebar: RootView hands a locked panel its own
-- resize rather than moving a split ratio the layout will ignore.
function TreeView:set_target_size(axis, value)
  if axis ~= "x" then return false end
  local max = math.max(100 * SCALE, core.root_view.size.x / 3)
  config.treeview_size = common.clamp(value, 100 * SCALE, max)
  self.visible = true
  self.init_size = true
  return true
end


function TreeView:get_target_size(axis)
  if axis ~= "x" then return nil end
  return self.visible and config.treeview_size or 0
end


function TreeView:update()
  -- update width
  local dest = self.visible and config.treeview_size or 0
  if self.init_size then
    self.size.x = dest
    self.init_size = false
  else
    self:move_towards(self.size, "x", dest)
  end

  TreeView.super.update(self)
end


function TreeView:draw()
  self:draw_background(style.background2)
  self.hits = {}
  if self.size.x < 20 then return end

  local icon_width = style.icon_font:get_width("D")
  local spacing = style.font:get_width(" ") * 2
  local bh = widgets.height(style.font)
  local footer_top = self.position.y + self.size.y - bh - style.padding.y * 2

  local doc = core.active_view.doc
  local active_filename = doc and system.absolute_path(doc.filename or "")

  for item, x,y,w,h in self:each_item() do
    if y + h > footer_top then break end
    local color = style.text

    -- highlight active_view doc
    if item.abs_filename == active_filename then
      color = style.accent
    end

    -- hovered item background
    if item == self.hovered_item then
      renderer.draw_rect(x, y, w, h, style.line_highlight)
      color = style.accent
    end

    -- icons
    x = x + item.depth * style.padding.x + style.padding.x
    if item.type == "dir" then
      local icon1 = item.expanded and "-" or "+"
      local icon2 = item.expanded and "D" or "d"
      common.draw_text(style.icon_font, color, icon1, nil, x, y, 0, h)
      x = x + style.padding.x
      common.draw_text(style.icon_font, color, icon2, nil, x, y, 0, h)
      x = x + icon_width
    else
      x = x + style.padding.x
      common.draw_text(style.icon_font, color, "f", nil, x, y, 0, h)
      x = x + icon_width
    end

    -- text
    x = x + spacing
    x = common.draw_text(style.font, color, item.name, nil, x, y, 0, h)
  end

  -- Open folder lives here, not as a peer of Files on the rail. The tree
  -- is the Files sidebar; this is the one control that moves the project.
  local font = style.font
  local pad = style.padding.x * 0.6
  local vpad = style.padding.y
  local fy = self.position.y + self.size.y - bh - vpad
  renderer.draw_rect(self.position.x, fy - vpad, self.size.x, 1, style.divider)
  local bx = self.position.x + pad
  local bw = self.size.x - pad * 2
  local hov = self.mouse and widgets.inside(
    { x = bx, y = fy, w = bw, h = bh }, self.mouse.x, self.mouse.y)
  local hit = widgets.button(font, "Open folder", bx, fy,
    { w = bw, hover = hov, align = "left" })
  hit.item = { label = "Open folder", command = "studio:open-folder",
    action = function() command.perform("studio:open-folder") end }
  self.hits[#self.hits + 1] = hit
end


-- init
local view = TreeView()
view.visible = false
view.hits = {}
-- The rail layout owns a single sidebar slot. Docking here as a third
-- column is what made Files slide over the conversation. Hand the view
-- to studio and let workspaces.set_sidebar swap it in.
local studio = core.studio
if studio and not studio.legacy and studio.rail then
  studio.tree = view
else
  local node = core.root_view:get_primary_node()
  node:split("left", view, true)
end

-- register commands and keymap
command.add(nil, {
  ["treeview:toggle"] = function()
    if studio and not studio.legacy then
      command.perform("studio:toggle-files")
      return
    end
    view.visible = not view.visible
  end,
})

keymap.add { ["ctrl+\\"] = "treeview:toggle" }

return view
