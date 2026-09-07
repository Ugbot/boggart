-- contextmenu.lua -- right-click, everywhere.
--
-- One engine: a view class registers a provider, a right-click anywhere asks
-- the providers for the view under the pointer, and the collected items open
-- in the core.menu popup (which already owns drawing, keyboard navigation
-- and click handling). A provider returns a list of menu items or nil;
-- providers for a class and its ancestors all contribute, in registration
-- order. No items, no menu, and the click falls through to the view.
--
-- Item shapes are core/menu.lua's: { label=, action= | command= },
-- { heading = }, plus checked and hint fields.
local core = require "core"
local menu = require "core.menu"

local M = {}

local providers = {}   -- { { class = ViewClass, fn = function(view, x, y) } }
local installed = false

-- lite's Object:is walks the metatable chain, so a provider registered on a
-- parent class serves subclasses too.
local function collect(view, x, y)
  local items = {}
  for _, p in ipairs(providers) do
    if view.is and view:is(p.class) then
      local got = p.fn(view, x, y)
      for _, it in ipairs(got or {}) do items[#items + 1] = it end
    end
  end
  return items
end

local function install()
  if installed then return end
  installed = true
  local RootView = require "core.rootview"
  local on_mouse_pressed = RootView.on_mouse_pressed
  function RootView:on_mouse_pressed(button, x, y, clicks)
    if button == "right" then
      local node = self.root_node:get_child_overlapping_point(x, y)
      local view = node and not node:get_tab_overlapping_point(x, y)
        and node.active_view
      if view then
        core.set_active_view(view)
        local items = collect(view, x, y)
        if #items > 0 then
          menu.show({ x = x, y = y, w = 1, h = 1 }, items)
          return
        end
      end
    end
    return on_mouse_pressed(self, button, x, y, clicks)
  end
end

-- contextmenu.add(ViewClass, provider). provider(view, x, y) -> items | nil.
function M.add(class, fn)
  providers[#providers + 1] = { class = class, fn = fn }
  install()
end

return M
