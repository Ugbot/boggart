-- pickerview.lua -- choosing a file or a folder, in the application.
--
-- There was no way to open anything that was not passed on the command line:
-- the project is one directory, chdir'd at startup, and nothing could add a
-- second or point at another.
--
-- In-app rather than the system dialog, deliberately. SDL3's file dialog is
-- compiled out of this binary, so a native one means shelling out -- osascript
-- on macOS, zenity or kdialog or portals on Linux, a COM call on Windows --
-- which is four platform paths, a permission prompt on macOS that can hang a
-- frame, and a dependency on whichever helper the user happens to have
-- installed. This is a list of directory entries drawn with the widgets already
-- here: it works identically everywhere, needs nothing installed, and can be
-- driven by a test.
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

-- A name as it is drawn, not as it is on disk. A filename may legally contain
-- a newline or a tab, and a row that contains one either disappears into the
-- renderer or looks exactly like the neighbouring file that does not -- two
-- entries reading "newline.txt" of which only one is really called that. The
-- byte is replaced for display only; entry.name stays exact, so what is opened
-- is what was listed.
local function displayable(name)
  if not name:find("[%z\1-\31\127]") then return name end
  return (name:gsub("[%z\1-\31\127]", "?"))
end

function PickerView:cd(path)
  self.dir = normalise(path)
  self.filter = ""
  self.selected = 1
  self.entries = {}
  self.matches = nil

  local names = sys.listdir(self.dir)
  if not names then
    -- An unreadable directory is a normal thing to click on, not an error
    -- worth a dialog. Say so in place and let them go back up -- which is why
    -- ".." is still in the list. Without it the only way out of a folder you
    -- cannot read is the mouse, and a keyboard user is simply stuck.
    self.error = "cannot read " .. self.dir
    self.entries[1] = { name = "..", shown = "..", dir = true, up = true }
    self.scroll.to.y = 0
    core.redraw = true
    return
  end
  self.error = nil

  local dirs, files = {}, {}
  for _, name in ipairs(names) do
    if self.show_hidden or name:sub(1, 1) ~= "." then
      local full = self.dir .. PATHSEP .. name
      local kind = sys.stat(full)
      -- lname is kept because the filter lowercases every name on every
      -- keystroke and the draw asks again on every frame: at ten thousand
      -- entries that is two hundred thousand throwaway strings a second.
      if kind == "dir" then
        dirs[#dirs + 1] = { name = name, shown = displayable(name),
                            lname = name:lower(), dir = true }
      elseif kind == "file" then
        files[#files + 1] = { name = name, shown = displayable(name),
                              lname = name:lower() }
      end
      -- Anything stat() will not answer for -- a broken or looping symlink, a
      -- file removed between the listing and the stat -- is left out. It
      -- cannot be opened and it cannot be descended into.
    end
  end
  table.sort(dirs, function(a, b) return a.lname < b.lname end)
  table.sort(files, function(a, b) return a.lname < b.lname end)

  self.entries[1] = { name = "..", shown = "..", dir = true, up = true }
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

-- The rows to show, cached against the filter that produced them: this is
-- asked once per frame and once per keystroke, and rebuilding a ten-thousand
-- element table sixty times a second to answer the same question is a frame
-- the agent does not get.
--
-- ".." is NOT kept while filtering. It used to be, unconditionally and first,
-- and since typing resets the selection to the top that meant filtering a
-- directory down to the one file you wanted and pressing Enter navigated you
-- to the PARENT. Backspace and the left arrow still go up, and clearing the
-- filter brings the row back.
function PickerView:visible_entries()
  if self.filter == "" then return self.entries end
  if self.matches and self.matches.filter == self.filter
     and self.matches.of == self.entries then
    return self.matches
  end
  local out = { filter = self.filter, of = self.entries }
  local needle = self.filter:lower()
  for _, e in ipairs(self.entries) do
    if not e.up and e.lname:find(needle, 1, true) then out[#out + 1] = e end
  end
  self.matches = out
  return out
end

function PickerView:choose(entry)
  local list = self:visible_entries()
  entry = entry or list[self.selected]
  if not entry then return end
  if entry.up then return self:cd(self.dir .. PATHSEP .. "..") end
  local full = self.dir .. PATHSEP .. entry.name
  if entry.dir then return self:cd(full) end
  if self.mode == "file" then return self:finish(full) end
  -- A file, in folder mode. Enter on one answers with the folder it is in, so
  -- a double-click has to as well: the same gesture on the same row cannot
  -- mean two different things, and doing nothing at all is indistinguishable
  -- from a dead control.
  return self:choose_current()
end

-- In folder mode the answer is the directory being looked at, which is why
-- there is a button as well as Enter: "this one" is not an item in the list.
function PickerView:choose_current()
  -- Refuses a directory it could not read. Handing one back looks like it
  -- worked, and the failure surfaces later and somewhere else -- as an agent
  -- that cannot list its own working directory.
  if self.error then
    self.error = "cannot read " .. self.dir .. " -- pick another folder"
    core.redraw = true
    return
  end
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

-- Where the list sits, computed rather than remembered from the last frame.
--
-- The keyboard needs this to know whether the selected row is on screen, and a
-- key can arrive before the view has ever been drawn -- so reading it back off
-- the previous draw gives nothing to go on for the first press. Everything
-- above the list is fixed height, so the answer is arithmetic, and having one
-- function produce it is what stops the scrolling and the drawing disagreeing
-- about which row is where.
function PickerView:geometry()
  local font = style.code_font
  local m = ui.metrics(font)
  local lh, pad, vpad = m.line_height, m.pad_x, m.pad_y
  local y = self.position.y + vpad
    + lh * 2 + vpad                       -- the hint and the path
    + widgets.height(font) + vpad         -- the button row
  if self.filter ~= "" then y = y + lh end
  if self.error then y = y + lh end
  return self.position.x + pad, y, self.size.x - pad * 2, lh, font, vpad
end

-- Scroll until the selected row is on screen.
--
-- Nothing did this, so the arrow keys moved a selection that stayed where it
-- was drawn: forty presses down a directory of ten thousand files left the
-- list showing the first thirty entries, no highlight anywhere on screen, and
-- Enter about to open a file the user could not see.
function PickerView:reveal_selection()
  local _, top, _, lh = self:geometry()
  local height = (self.position.y + self.size.y) - top
  if height <= 0 or lh <= 0 then return end
  local above = (self.selected - 1) * lh
  local to = self.scroll.to.y
  if above < to then to = above
  elseif above + lh > to + height then to = above + lh - height end
  self.scroll.to.y = math.max(0, to)
  core.redraw = true
end

function PickerView:select(index)
  local n = #self:visible_entries()
  self.selected = common.clamp(math.floor(index), 1, math.max(1, n))
  self:reveal_selection()
end

-- Rows that fit between the list's top and the bottom of the view. One less
-- than that is a page, so paging always leaves a row of context.
function PickerView:page_rows()
  local _, top, _, lh = self:geometry()
  if lh <= 0 then return 1 end
  return math.max(1, math.floor(((self.position.y + self.size.y) - top) / lh) - 1)
end

function PickerView:on_text_input(text)
  self.filter = self.filter .. text
  self.selected = 1
  self.scroll.to.y = 0
  core.redraw = true
end

function PickerView:on_key_pressed(key)
  local list = self:visible_entries()
  if key == "escape" then self:cancel(); return true
  elseif key == "ctrl+h" then
    -- Promised by the listing code since the first version and never wired up.
    self.show_hidden = not self.show_hidden
    local keep = self.dir
    self:cd(keep)
    return true
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
    if self.filter ~= "" then
      -- By character, not by byte: a filter is whatever the keyboard produced,
      -- and lopping one byte off a multi-byte character leaves a string the
      -- renderer cannot decode.
      local i = #self.filter
      while i > 1 and common.is_utf8_cont(self.filter:sub(i, i)) do i = i - 1 end
      self.filter = self.filter:sub(1, i - 1)
      self.selected = 1
      self.scroll.to.y = 0
    else
      self:cd(self.dir .. PATHSEP .. "..")
    end
    core.redraw = true; return true
  elseif key == "up" then
    self:select(self.selected - 1); return true
  elseif key == "down" then
    self:select(self.selected + 1); return true
  elseif key == "pageup" then
    self:select(self.selected - self:page_rows()); return true
  elseif key == "pagedown" then
    self:select(self.selected + self:page_rows()); return true
  elseif key == "home" then
    self:select(1); return true
  elseif key == "end" then
    self:select(#list); return true
  end
  return false
end

function PickerView:on_mouse_moved(x, y, dx, dy)
  PickerView.super.on_mouse_moved(self, x, y, dx, dy)
  -- Only a genuine move needs a repaint: SDL delivers a motion event per frame
  -- while the cursor merely rests over the picker, and redrawing on each one
  -- pins the whole app at the frame cap for nothing.
  if not self.mouse or self.mouse.x ~= x or self.mouse.y ~= y then
    self.mouse = { x = x, y = y }
    core.redraw = true
  end
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

-- Cut a row to the column it is drawn in, measured in display cells.
--
-- sys.wtake is the only correct way to do this: a 200-character filename is
-- ordinary, this renderer does not clip, and a row that does not fit is drawn
-- straight across whatever view is to the right. Slicing by byte instead would
-- fit the column and hand the C text decoder half a codepoint.
local function fit(text, cells)
  if cells <= 1 or sys.width(text) <= cells then return text end
  local head = sys.wtake(text, cells - 1)
  return head .. "…"
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

  if #list == 0 then
    -- Filtering to nothing used to leave a blank rectangle, which reads as a
    -- picker that has broken rather than one that has been asked a question
    -- with no answer.
    common.draw_text(font, style.dim, "nothing here matches " .. self.filter,
      "left", x + pad / 2, top, w, lh)
    self.content_height = (top + lh + vpad) - self.position.y
    self:draw_scrollbar()
    return
  end

  -- Only the rows on screen are drawn, and only those get a hit rectangle.
  -- Walking the whole list cost a table per entry per frame, so browsing a
  -- directory of ten thousand files allocated ten thousand rectangles sixty
  -- times a second -- for thirty visible rows.
  local bottom = self.position.y + self.size.y
  local first = math.max(1, math.floor(self.scroll.y / lh) + 1)
  local last = math.min(#list, first + math.ceil((bottom - top) / lh))
  local cells = math.max(1, math.floor((w - pad / 2) / m.char_width) - 2)

  for i = first, last do
    local e = list[i]
    local ry = top + (i - 1) * lh - self.scroll.y
    local hovered = self.mouse
      and widgets.inside({ x = x, y = ry, w = w, h = lh }, self.mouse.x, self.mouse.y)
    if i == self.selected then
      renderer.draw_rect(x, ry, w, lh, style.selection)
    elseif hovered then
      renderer.draw_rect(x, ry, w, lh, style.line_highlight)
    end
    local colour = e.dim and style.dim or (e.dir and style.accent or style.text)
    common.draw_text(font, colour, (e.dir and "/ " or "  ") .. fit(e.shown, cells),
      "left", x + pad / 2, ry, w, lh)
    self.row_hits[#self.row_hits + 1] =
      { x = x, y = ry, w = w, h = lh, index = i, entry = e }
  end

  self.content_height = (top - self.position.y) + #list * lh + vpad
  self:draw_scrollbar()
end

return PickerView
