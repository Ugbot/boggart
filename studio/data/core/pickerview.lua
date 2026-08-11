-- pickerview.lua -- choosing a file or a folder, in the application.
--
-- There was no way to open anything that was not passed on the command line:
-- the project is one directory, chdir'd at startup, and nothing could add a
-- second or point at another.
--
-- In-app rather than the system dialog, deliberately. SDL2 has no file chooser,
-- so a native one means shelling out -- osascript on macOS, zenity or kdialog
-- or portals on Linux, a COM call on Windows -- which is four platform paths,
-- a permission prompt on macOS that can hang a frame, and a dependency on
-- whichever helper the user happens to have installed. This is a list of
-- directory entries drawn with the widgets already here: it works identically
-- everywhere, needs nothing installed, and can be driven by a test.
--
-- What it gives up is real: no sidebar of favourites, no iCloud, no "recent
-- places", no drag-and-drop from Finder. If those matter more than the single
-- binary does, a native chooser behind sys.caps() is the way, and this stays as
-- the fallback for platforms without one.
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"
local widgets = require "core.widgets"
local ui = require "core.ui"

local PickerView = View:extend()

-- mode: "folder" picks a directory, "file" picks a file. Both browse both --
-- you have to walk through folders to reach a file -- so the mode only decides
-- what Enter and the Choose button do.
function PickerView:new(mode, start, on_pick)
  PickerView.super.new(self)
  self.scrollable = true
  self.mode = mode == "folder" and "folder" or "file"
  self.on_pick = on_pick
  self.filter = ""
  self.selected = 1
  self.hits = {}
  self:cd(start or sys.cwd())
end

function PickerView:get_name()
  return self.mode == "folder" and "Choose a folder" or "Open a file"
end

-- Absolute, and without "." or ".." left in it, so what is displayed is what
-- would be stored. sys.paths()/sys.cwd() come from the capability layer rather
-- than from string surgery on PATHSEP.
local function normalise(path)
  if path == "" then return sys.cwd() end
  local abs = path
  if not abs:match("^[/\\\\]") and not abs:match("^%a:[/\\\\]") then
    abs = sys.cwd() .. PATHSEP .. abs
  end
  local parts = {}
  for piece in abs:gmatch("[^/\\\\]+") do
    if piece == ".." then
      if #parts > 0 then table.remove(parts) end
    elseif piece ~= "." then
      parts[#parts + 1] = piece
    end
  end
  local sep = PATHSEP
  if abs:match("^[/\\\\]") then return sep .. table.concat(parts, sep) end
  return table.concat(parts, sep)
end

function PickerView:cd(path)
  self.dir = normalise(path)
  self.filter = ""
  self.selected = 1
  self.entries = {}

  local names = sys.listdir(self.dir)
  if not names then
    -- An unreadable directory is a normal thing to click on, not an error
    -- worth a dialog. Say so in place and let them go back up.
    self.error = "cannot read " .. self.dir
    return
  end
  self.error = nil

  local dirs, files = {}, {}
  for _, name in ipairs(names) do
    if name:sub(1, 1) ~= "." then       -- dotfiles hidden; ctrl+h shows them
      local full = self.dir .. PATHSEP .. name
      local kind = sys.stat(full)
      if kind == "dir" then dirs[#dirs + 1] = { name = name, dir = true }
      elseif kind == "file" then files[#files + 1] = { name = name } end
    end
  end
  table.sort(dirs, function(a, b) return a.name:lower() < b.name:lower() end)
  table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)

  self.entries[1] = { name = "..", dir = true, up = true }
  for _, d in ipairs(dirs) do self.entries[#self.entries + 1] = d end
  if self.mode == "file" then
    for _, f in ipairs(files) do self.entries[#self.entries + 1] = f end
  else
    -- Files are shown in folder mode too, greyed: a directory listing with the
    -- files removed is disorienting, because it no longer looks like the
    -- folder you know.
    for _, f in ipairs(files) do
      f.dim = true
      self.entries[#self.entries + 1] = f
    end
  end
  self.scroll.to.y = 0
  core.redraw = true
end

function PickerView:visible_entries()
  if self.filter == "" then return self.entries end
  local out = {}
  local needle = self.filter:lower()
  for _, e in ipairs(self.entries) do
    if e.up or e.name:lower():find(needle, 1, true) then out[#out + 1] = e end
  end
  return out
end

function PickerView:choose(entry)
  local list = self:visible_entries()
  entry = entry or list[self.selected]
  if not entry then return end
  if entry.up then return self:cd(self.dir .. PATHSEP .. "..") end
  local full = self.dir .. PATHSEP .. entry.name
  if entry.dir and self.mode == "file" then return self:cd(full) end
  if entry.dir and self.mode == "folder" then return self:cd(full) end
  if not entry.dir and self.mode == "file" then return self:finish(full) end
end

-- In folder mode the answer is the directory being looked at, which is why
-- there is a button as well as Enter: "this one" is not an item in the list.
function PickerView:choose_current()
  self:finish(self.dir)
end

function PickerView:finish(path)
  local node = core.root_view.root_node:get_node_for_view(self)
  local pick = self.on_pick
  if node then
    node:set_active_view(self)
    node:close_active_view(core.root_view.root_node)
  end
  if pick then core.try(pick, path) end
end

function PickerView:cancel()
  self.on_pick = nil
  self:finish(nil)
end

function PickerView:on_text_input(text)
  self.filter = self.filter .. text
  self.selected = 1
  core.redraw = true
end

function PickerView:on_key_pressed(key)
  local list = self:visible_entries()
  if key == "escape" then self:cancel(); return true
  elseif key == "return" then
    -- In folder mode Enter CHOOSES; right-arrow descends. The other way round
    -- leaves no key for "this one", and the obvious candidate is taken:
    -- ctrl+return is bound to toggling the agent panel, and a bound command
    -- always beats a view, so the picker never saw it.
    if self.mode == "folder" then
      local e = list[self.selected]
      if e and e.dir and not e.up then
        self:finish(self.dir .. PATHSEP .. e.name)
      else
        self:choose_current()
      end
    else
      self:choose()
    end
    return true
  elseif key == "right" then
    local e = list[self.selected]
    if e then self:choose(e) end       -- descend, in both modes
    return true
  elseif key == "left" then
    self:cd(self.dir .. PATHSEP .. "..")
    return true
  elseif key == "backspace" then
    if self.filter ~= "" then self.filter = self.filter:sub(1, -2)
    else self:cd(self.dir .. PATHSEP .. "..") end
    core.redraw = true; return true
  elseif key == "up" then
    self.selected = math.max(1, self.selected - 1); core.redraw = true; return true
  elseif key == "down" then
    self.selected = math.min(#list, self.selected + 1); core.redraw = true; return true
  end
  return false
end

function PickerView:on_mouse_moved(x, y, dx, dy)
  PickerView.super.on_mouse_moved(self, x, y, dx, dy)
  self.mouse = { x = x, y = y }
  core.redraw = true
end

function PickerView:on_mouse_pressed(button, x, y, clicks)
  if PickerView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  core.set_active_view(self)
  local item = widgets.hit(self.hits, x, y)
  if item then
    if item.action then item.action() end
    return true
  end
  for _, r in ipairs(self.row_hits or {}) do
    if widgets.inside(r, x, y) then
      self.selected = r.index
      -- One click selects, two opens: a single click that navigates makes it
      -- impossible to look at a folder without entering it.
      if clicks and clicks >= 2 then self:choose(r.entry) end
      core.redraw = true
      return true
    end
  end
  return true
end

function PickerView:get_scrollable_size()
  return self.content_height or math.huge
end

function PickerView:draw()
  self:draw_background(style.background)
  local font = style.code_font
  local m = ui.metrics(font)
  local lh, pad, vpad = m.line_height, m.pad_x, m.pad_y
  local bh = widgets.height(font)
  self.hits, self.row_hits = {}, {}

  local x = self.position.x + pad
  local w = self.size.x - pad * 2
  local y = self.position.y + vpad

  common.draw_text(font, style.dim,
    self.mode == "folder"
      and "Choose a folder to work in -- enter chooses, right arrow opens"
      or "Open a file -- enter opens, left arrow goes up",
    "left", x, y, w, lh)
  y = y + lh
  common.draw_text(font, style.text, self.dir, "left", x, y, w, lh)
  y = y + lh + vpad

  local actions = { { label = "Up", action = function()
      self:cd(self.dir .. PATHSEP .. "..") end } }
  if self.mode == "folder" then
    actions[#actions + 1] = { label = "Choose this folder",
      action = function() self:choose_current() end }
  end
  actions[#actions + 1] = { label = "Cancel", action = function() self:cancel() end }
  for _, hit in ipairs(widgets.row(font, actions, x, y, self.mouse)) do
    self.hits[#self.hits + 1] = hit
  end
  y = y + bh + vpad

  if self.filter ~= "" then
    common.draw_text(font, style.accent, "filter: " .. self.filter,
      "left", x, y, w, lh)
    y = y + lh
  end
  if self.error then
    common.draw_text(font, style.error, self.error, "left", x, y, w, lh)
    y = y + lh
  end

  local list = self:visible_entries()
  if self.selected > #list then self.selected = math.max(1, #list) end
  local top = y
  y = y - self.scroll.y
  for i, e in ipairs(list) do
    if y + lh > top and y < self.position.y + self.size.y then
      local hovered = self.mouse
        and widgets.inside({ x = x, y = y, w = w, h = lh }, self.mouse.x, self.mouse.y)
      if i == self.selected then
        renderer.draw_rect(x, y, w, lh, style.selection)
      elseif hovered then
        renderer.draw_rect(x, y, w, lh, style.line_highlight)
      end
      local colour = e.dim and style.dim or (e.dir and style.accent or style.text)
      common.draw_text(font, colour, (e.dir and "/ " or "  ") .. e.name,
        "left", x + pad / 2, y, w, lh)
    end
    self.row_hits[#self.row_hits + 1] =
      { x = x, y = y, w = w, h = lh, index = i, entry = e }
    y = y + lh
  end

  self.content_height = (y + self.scroll.y) - self.position.y + vpad
  self:draw_scrollbar()
end

return PickerView
