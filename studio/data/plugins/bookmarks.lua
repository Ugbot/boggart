-- bookmarks.lua -- nine slots of {file, line, col, scroll}. Set with
-- cmd+shift+1..9, jump with cmd+1..9, list with cmd+b. A jump restores
-- scroll as well as caret: a bookmark is a view, not a coordinate.
-- Slots persist in .studio-bookmarks.lua at the project root.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"

local slots = {}

local function store_path()
  return (core.project_dir or ".") .. "/.studio-bookmarks.lua"
end

local function save()
  local out = { "return {" }
  for i = 1, 9 do
    local b = slots[i]
    if b then
      out[#out + 1] = string.format(
        "  [%d] = { file = %q, line = %d, col = %d, scroll_y = %d },",
        i, b.file, b.line, b.col, b.scroll_y)
    end
  end
  out[#out + 1] = "}\n"
  local fp = io.open(store_path(), "wb")
  if fp then fp:write(table.concat(out, "\n")) fp:close() end
end

local function load()
  local ok, t = pcall(dofile, store_path())
  if ok and type(t) == "table" then slots = t end
end
load()

local function label(i)
  local b = slots[i]
  if not b then return nil end
  return string.format("%d: %s:%d", i, b.file:match("[^/\\]+$") or b.file, b.line)
end

local function set_slot(i)
  local dv = core.active_view
  local doc = dv and dv.doc
  if not doc or not doc.filename then
    core.error("bookmark: the buffer has no file")
    return
  end
  local line, col = doc:get_selection()
  slots[i] = {
    file = system.absolute_path(doc.filename) or doc.filename,
    line = line, col = col,
    scroll_y = math.floor(dv.scroll.y),
  }
  save()
  core.log("bookmark %d set: %s", i, label(i))
end

local function jump(i)
  local b = slots[i]
  if not b then
    core.log("bookmark %d is empty (cmd+shift+%d sets it)", i, i)
    return
  end
  local ok, err = core.try(function()
    local dv = core.root_view:open_doc(core.open_doc(b.file))
    dv.doc:set_selection(b.line, b.col)
    -- Caret first, then the saved scroll overrides open_doc's ensure-visible.
    dv.scroll.to.y = b.scroll_y
  end)
  if not ok then core.error("bookmark %d: %s", i, tostring(err)) end
end

local cmds = {
  ["bookmarks:list"] = function()
    local items = {}
    for i = 1, 9 do
      local l = label(i)
      if l then items[#items + 1] = l end
    end
    if #items == 0 then core.log("no bookmarks set") return end
    core.command_view:enter("Bookmark", function(text)
      local i = tonumber(text:match("^(%d)"))
      if i then jump(i) end
    end, function() return items end)
  end,
  ["bookmarks:clear-all"] = function()
    slots = {}
    save()
    core.log("bookmarks cleared")
  end,
}
for i = 1, 9 do
  cmds["bookmarks:set-" .. i] = function() set_slot(i) end
  cmds["bookmarks:jump-" .. i] = function() jump(i) end
end
command.add(nil, cmds)

local binds = { ["cmd+b"] = "bookmarks:list", ["ctrl+b"] = "bookmarks:list" }
for i = 1, 9 do
  binds["cmd+" .. i] = "bookmarks:jump-" .. i
  binds["ctrl+" .. i] = "bookmarks:jump-" .. i
  binds["cmd+shift+" .. i] = "bookmarks:set-" .. i
  binds["ctrl+shift+" .. i] = "bookmarks:set-" .. i
end
keymap.add(binds)

return {}
