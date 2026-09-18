-- rightclick.lua -- default context menus for the editor, the chat, the file
-- tree and panels. The engine is core/contextmenu.lua; the sidebar registers
-- its own provider. Items call existing commands, so everything here is also
-- reachable from the palette and the menu bar.
local core = require "core"
local contextmenu = require "core.contextmenu"
local DocView = require "core.docview"
local AgentView = require "core.agentview"
local PanelView = require "core.panelview"

-- Editor: clipboard, the agent verbs on a selection, folding, multi-cursor.
contextmenu.add(DocView, function(dv, x, y)
  -- Clicking outside the selection moves the caret there first, so the verbs
  -- act on what was clicked.
  local line, col = dv:resolve_screen_position(x, y)
  local l1, c1, l2, c2 = dv.doc:get_selection(true)
  local inside = dv.doc:has_selection()
    and (line > l1 or (line == l1 and col >= c1))
    and (line < l2 or (line == l2 and col <= c2))
  if not inside then dv.doc:set_selection(line, col) end
  local has = dv.doc:has_selection()

  local items = {
    { label = "Cut",   command = "doc:cut" },
    { label = "Copy",  command = "doc:copy" },
    { label = "Paste", command = "doc:paste" },
    { heading = "" },
    { label = "Inline edit\u{2026}", command = "agent:inline-edit" },
  }
  if has then
    items[#items + 1] = { label = "Explain selection", command = "agent:explain-selection" }
    items[#items + 1] = { label = "Review selection", command = "agent:review-selection" }
    items[#items + 1] = { label = "Write tests for selection", command = "agent:test-selection" }
  end
  items[#items + 1] = { heading = "" }
  items[#items + 1] = { label = "Toggle fold", command = "fold:toggle" }
  items[#items + 1] = { label = "Cursors at all matches", command = "doc:cursors-at-all-matches" }
  return items
end)

-- Markdown preview: the obvious way to reach the source. The toggle shortcut
-- is easy to miss (and shares a key with agent:explain-selection), so the way
-- to edit lives here where right-clicking finds it.
local ok_md, MarkdownView = pcall(require, "core.markdownview")
if ok_md and MarkdownView then
  contextmenu.add(MarkdownView, function()
    return {
      { label = "Edit source", command = "markdown:toggle-source" },
      { heading = "" },
      { label = "Copy", command = "doc:copy" },
    }
  end)
end

-- Chat: session verbs.
contextmenu.add(AgentView, function()
  return {
    { label = "Rename session\u{2026}", command = "agent:rename-session" },
    { label = "Attach file\u{2026}",    command = "agent:attach-file" },
    { label = "Edit message\u{2026}",   command = "agent:edit-message" },
    { heading = "" },
    { label = "Compact now",  command = "agent:compact-now" },
    { label = "Cancel turn",  command = "agent:cancel" },
  }
end)

-- File tree: the module returns its instance, so register on its class.
local ok, tree = pcall(require, "plugins.treeview")
if ok and tree then
  contextmenu.add(getmetatable(tree), function(view)
    local it = view.hovered_item
    if not it then return nil end
    local items = { { heading = it.filename:match("[^/\\]+$") or it.filename } }
    if it.type == "dir" then
      items[#items + 1] = { label = it.expanded and "Collapse" or "Expand",
        action = function() it.expanded = not it.expanded core.redraw = true end }
    else
      items[#items + 1] = { label = "Open", action = function()
        core.try(function() core.root_view:open_doc(core.open_doc(it.filename)) end)
      end }
    end
    items[#items + 1] = { label = "Copy path", action = function()
      pcall(system.set_clipboard, it.filename)
      core.log("copied: %s", it.filename)
    end }
    return items
  end)
end

-- Panels: edit, reload, close.
contextmenu.add(PanelView, function(view)
  local name = view.name
  return {
    { heading = name },
    { label = "Reload", action = function() view:reload() end },
    { label = "Edit source", action = function()
      local uitools = require "core.uitools"
      core.try(function() core.root_view:open_doc(core.open_doc(uitools.path(name))) end)
    end },
    { label = "Close", action = function()
      require("core.studio").close_panel(name)
    end },
  }
end)

return {}
