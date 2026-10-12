-- uitracker.lua -- render the tracker tab (list, then board) and save shots.
-- BOGGART_STUDIO_SCRIPT=tools/uitracker.lua BOGGART_STUDIO_SHOT=out.bmp boggart-studio <repo>
-- Needs a store with tracker data (e.g. after `/tracker import`).
local core = require "core"
local OUT = os.getenv("BOGGART_STUDIO_SHOT") or "/tmp/boggart-tracker.bmp"
local PROJECT = os.getenv("BOGGART_TRACKER_PROJECT") or "BRAIN"
local problems = {}
core.add_thread(function()
  local function frame(n) core.redraw = true; for _ = 1, (n or 4) do coroutine.yield(0.08) end end
  local ok, tv = pcall(require, "core.trackerview")
  if not ok then problems[#problems + 1] = "trackerview did not load: " .. tostring(tv) end
  if ok then
    local v = tv.open(PROJECT)
    frame(8)
    if not v.model then problems[#problems + 1] = "no model for " .. PROJECT end
    system.save_screenshot((OUT:gsub("%.bmp$", "")) .. "-list.bmp")
    v:select_delta(2); frame(4)
    system.save_screenshot((OUT:gsub("%.bmp$", "")) .. "-list-select.bmp")
    v:toggle_board(); frame(6)
    system.save_screenshot((OUT:gsub("%.bmp$", "")) .. "-board.bmp")
  end
  for _, p in ipairs(problems) do io.stderr:write("uitracker: ", p, "\n") end
  io.stderr:write("uitracker: ", #problems == 0 and "ok" or "FAILED", "\n")
  os.exit(#problems == 0 and 0 or 1)
end)
