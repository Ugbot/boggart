-- sidebarprobe.lua -- resize and collapse, exercised through RootView's drag.
--
--   BOGGART_STUDIO_LEGACY=1 BOGGART_STUDIO_SCRIPT=$PWD/tools/sidebarprobe.lua ./boggart-studio .
--
-- Photographs the LEGACY SidebarView (the default shell does not use it).
--
-- Two things here are easy to get wrong in a way no static check catches. The
-- drag is driven through RootView:on_mouse_moved with a divider held, not by
-- calling set_target_size, because the bug that made dragging do nothing lived
-- in the handoff and not in either end of it. And the collapse waits with
-- coroutine.yield(0.02) rather than yield(0): run_threads only gives the frame
-- back when its time budget is spent, so a thread that yields zero spins inside
-- a single frame and the animation it is waiting for never advances.
local core = require "core"
local config = require "core.config"

core.add_thread(function()
  coroutine.yield(0.3)
  local out = {}
  local function p(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    out[#out + 1] = table.concat(parts, " | ")
  end

  local ok, err = pcall(function()
    local studio = require "core.studio"
    local sb = studio.sidebar
    local rv = core.root_view
    p("sidebar", sb ~= nil, sb.size.x, config.sidebar_size, config.sidebar_min)

    -- Find the split whose child leaf holds the sidebar.
    local function find(node)
      if node.type == "leaf" then return nil end
      for _, which in ipairs { "a", "b" } do
        local c = node[which]
        if c.type == "leaf" and c.active_view == sb then return node, which end
      end
      local n, w = find(node.a)
      if n then return n, w end
      return find(node.b)
    end
    local split, which = find(rv.root_node)
    p("split_found", split ~= nil, split and split.type, which)

    local max = math.max(config.sidebar_min, rv.size.x / 3)
    p("max_allowed", max)

    -- 1. direct clamping ----------------------------------------------------
    p("mid", sb:set_target_size("x", 300), config.sidebar_size)
    p("low", sb:set_target_size("x", 5), config.sidebar_size,
      config.sidebar_size == config.sidebar_min)
    p("high", sb:set_target_size("x", 99999), config.sidebar_size,
      config.sidebar_size == max)
    local keep = config.sidebar_size
    p("wrong_axis", sb:set_target_size("y", 10), config.sidebar_size == keep)

    -- 2. set_target_size takes effect on the next update, no glide ----------
    sb:set_target_size("x", 260)
    sb:update()
    p("update_snaps", sb.size.x, sb.size.x == 260)

    -- 3. the drag path RootView actually uses -------------------------------
    rv.dragged_divider = split
    local start = sb.size.x
    for _ = 1, 10 do rv:on_mouse_moved(0, 0, 6, 0); sb:update() end
    p("drag_right", start, sb.size.x, sb.size.x == start + 60)
    -- Grabbing the edge while the rail is still animating must adjust the
    -- width that was asked for, not the frame it happens to be on.
    sb.size.x = 7
    rv:on_mouse_moved(0, 0, 5, 0)
    sb:update()
    p("drag_midanimation", config.sidebar_size, sb.size.x, sb.size.x == start + 65)
    for _ = 1, 200 do rv:on_mouse_moved(0, 0, -6, 0); sb:update() end
    p("drag_clamps_low", sb.size.x, sb.size.x == config.sidebar_min)
    for _ = 1, 400 do rv:on_mouse_moved(0, 0, 6, 0); sb:update() end
    p("drag_clamps_high", sb.size.x, sb.size.x == max)
    rv.dragged_divider = nil

    sb:set_target_size("x", 260); sb:update()

    -- 4. collapse / expand ---------------------------------------------------
    p("toggle_off", sb:toggle(), sb.visible)
    for _ = 1, 30 do coroutine.yield(0.02) end
    p("collapsed_width", sb.size.x, sb.size.x < 1)
    local main = studio.agent_view() or core.active_view
    p("collapsed_layout", main and main.position.x, main and main.size.x, rv.size.x)
    p("toggle_on", sb:toggle(), sb.visible)
    for _ = 1, 30 do coroutine.yield(0.02) end
    p("expanded_width", sb.size.x, config.sidebar_size,
      math.abs(sb.size.x - config.sidebar_size) < 1)

    -- 5. dragging a collapsed rail pulls it back open -----------------------
    sb:toggle()
    for _ = 1, 30 do coroutine.yield(0.02) end
    p("collapsed_again", sb.size.x, sb.visible)
    rv.dragged_divider = split
    rv:on_mouse_moved(0, 0, 40, 0)
    rv.dragged_divider = nil
    sb:update()
    p("drag_reopens", sb.visible, sb.size.x)

    -- 6. the sidebar draws nothing at a hairline width, but must not error --
    sb:set_target_size("x", config.sidebar_min); sb:update()
    sb.size.x = 4
    p("draw_hairline", pcall(sb.draw, sb))
    sb:set_target_size("x", 210); sb:update()

    -- 7. the tree view uses the same protocol -------------------------------
    local tv = nil
    for _, v in ipairs(rv.root_node:get_children()) do
      if v.set_target_size and v ~= sb then tv = v end
    end
    if tv then
      p("treeview", tv:get_name(), tv:set_target_size("x", 5), config.treeview_size)
      p("treeview_high", tv:set_target_size("x", 99999), config.treeview_size,
        config.treeview_size == math.max(100 * SCALE, rv.size.x / 3))
      p("treeview_axis", tv:set_target_size("y", 10))
    else
      p("treeview", "not attached")
    end
  end)

  io.write("OK=", tostring(ok), " ERR=", tostring(err), "\n")
  io.write(table.concat(out, "\n"), "\n")
  io.flush()
  os.exit(0)
end)
