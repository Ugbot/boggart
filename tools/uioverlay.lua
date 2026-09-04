-- uioverlay.lua -- prove an overlay survives a partially damaged frame.
--
-- Run with `ninja ui-overlay`. The bug this guards against (2026-09-03): the
-- renderer treated an EMPTY clip rect as "no clip" and passed NULL to SDL,
-- which disables clipping entirely. rencache replays the whole command list
-- once per dirty rect and intersects every SET_CLIP with that rect, so a view
-- whose clip does not touch the rect legally produces a zero-sized clip -- and
-- that view then painted across the WHOLE target, over the menu dropdown drawn
-- later in the same frame. Because the dropdown's own cells were not dirty,
-- nothing ever repaired them: the menu came back on the next frame that dirtied
-- it and vanished again on the next that did not. That is the flicker.
--
-- It is invisible to every other check here. ui-check forces a redraw and
-- photographs a settled frame; ui-bench measures timing. The bug only appears
-- when *part* of the window is damaged while an overlay is up, which is the
-- ordinary case of "a menu is open and something underneath is animating".
local core = require "core"
local shell = require "shell"

local OUT = os.getenv("BOGGART_STUDIO_SHOT") or "/tmp/boggart-overlay.bmp"
local problems = {}
local function check(ok, msg) if not ok then problems[#problems + 1] = msg end end

-- Read the BMP back and measure how much of the dropdown rect is actually the
-- panel. A frame that lost the overlay shows the view underneath instead, so
-- the panel background collapses from most of the rect to almost none of it.
local function panel_fraction(path, x, y, w, h)
  local f = io.open(path, "rb")
  if not f then return nil, "no screenshot at " .. path end
  local d = f:read("a"); f:close()
  local function u32(o) local a,b,c,e = d:byte(o+1, o+4); return a + b*256 + c*65536 + e*16777216 end
  local function i32(o) local v = u32(o); if v >= 0x80000000 then v = v - 0x100000000 end return v end
  local off, bw, bh = u32(10), i32(18), i32(22)
  local topdown = bh < 0
  if bh < 0 then bh = -bh end
  if bw <= 0 or bh <= 0 then return nil, "unreadable BMP header" end
  local hits, total = 0, 0
  local r0, g0, b0
  for yy = y, y + h - 1, 4 do
    local row = topdown and yy or (bh - 1 - yy)
    if row >= 0 and row < bh then
      for xx = x, x + w - 1, 4 do
        if xx >= 0 and xx < bw then
          local i = off + (row * bw + xx) * 4
          local b, g, r = d:byte(i + 1), d:byte(i + 2), d:byte(i + 3)
          if b then
            -- the panel colour is whatever the theme paints the menu with;
            -- sample it once from the middle of the first row and count matches
            if not r0 then r0, g0, b0 = r, g, b end
            total = total + 1
            if r == r0 and g == g0 and b == b0 then hits = hits + 1 end
          end
        end
      end
    end
  end
  if total == 0 then return nil, "sampled nothing" end
  return hits / total
end

core.add_thread(function()
  local verdict
  for _ = 1, 25 do core.redraw = true; coroutine.yield(0.04) end

  local mb = shell.menubar
  check(mb ~= nil, "no menu bar in the shell composition")
  if not mb then goto done end

  do
    local items = mb:items()
    local target = items[2]
    for _, it in ipairs(items) do if it.name == "File" then target = it end end
    local mx, my = target.x + target.w / 2, mb.position.y + mb.size.y / 2

    core.on_event("mousemoved", mx, my, 0, 0); core.redraw = true
    coroutine.yield(0.05)
    core.on_event("mousepressed", "left", mx, my, 1); core.redraw = true
    core.on_event("mousereleased", "left", mx, my, 1); core.redraw = true
    coroutine.yield(0.05)

    check(mb.open ~= nil, "clicking a menu title did not open a dropdown")
    local x, y, w, h = mb:dropdown_rect()
    if not x then check(false, "no dropdown geometry after opening"); goto done end

    -- The frame that opens the menu damages the whole dropdown, so it is the
    -- baseline: whatever fraction of the rect is panel here is correct.
    coroutine.yield(0.05)
    check(select(1, pcall(system.save_screenshot, OUT)), "save_screenshot failed")
    local base, err = panel_fraction(OUT, math.floor(x), math.floor(y),
      math.floor(w), math.floor(h))
    check(base ~= nil, "baseline frame: " .. tostring(err))
    if not base then goto done end

    -- Now damage the region UNDER the menu without touching the menu's own
    -- cells: an animated scroll in the view below. Then walk the pointer down
    -- the rows, checking every frame still contains the whole panel.
    local v = core.active_view
    if v and v.scroll then v.scroll.to.y = (v.scroll.to.y or 0) + 400 end

    local worst, worst_at = base, 0
    for i = 1, 14 do
      local py = y + 10 + (h - 20) * (i / 14)
      core.on_event("mousemoved", x + w / 2, py, 0, 6); core.redraw = true
      coroutine.yield(0.03)
      system.save_screenshot(OUT)
      local f = panel_fraction(OUT, math.floor(x), math.floor(y),
        math.floor(w), math.floor(h))
      if f and f < worst then worst, worst_at = f, i end
    end

    -- A repaired frame differs from the baseline only by the hover highlight,
    -- which is a fraction of one row; losing the overlay costs most of the rect.
    check(worst > base * 0.75, string.format(
      "the dropdown was overpainted while the view under it animated: panel "
      .. "cover fell from %.0f%% to %.0f%% at step %d -- an empty clip is being "
      .. "treated as no clip somewhere in the renderer",
      base * 100, worst * 100, worst_at))

    verdict = string.format(
      "ok  overlay survives partial damage (panel cover %.0f%% baseline, %.0f%% worst)  wrote %s\n",
      base * 100, worst * 100, OUT)
  end

  ::done::
  if #problems > 0 then
    io.write("FAIL\n")
    for _, p in ipairs(problems) do io.write("  - " .. p .. "\n") end
    io.flush()
    os.exit(1)
  end
  io.write(verdict or "ok\n")
  io.flush()
  os.exit(0)
end)
