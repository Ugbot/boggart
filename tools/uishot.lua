-- uishot.lua -- render the studio with representative content and photograph it.
--
-- Run via tools/uishot.sh. This exists because the panel-attachment bug of
-- 2026-08-11 was invisible to every headless test: AgentView constructed
-- correctly, laid out correctly, and answered every probe correctly, while
-- never appearing on screen at all -- once because lite does not set view.node
-- (so the "is the panel open?" check was nil every time) and once because a
-- `locked` split pins a node to its view's size, which for a fresh View is
-- zero. Neither is detectable without a rendered frame.
--
-- Output is a BMP because SDL2 writes one with no extra dependency. Convert it
-- to PNG if you want to look at it somewhere fussy.
local core = require "core"
local studio = require "core.studio"
local difflib = require "core.diff"

local OUT = os.getenv("BOGGART_STUDIO_SHOT") or "/tmp/boggart-studio.bmp"

core.add_thread(function()
  coroutine.yield(0.3)

  local v = studio.open_agent()
  v.entries = {}
  v:push("system", "boggart " .. (bog and bog.version or "?")
    .. "   model " .. v:model())
  v:push("user", "add a retry helper to lua/api.lua and show me the diff")
  v:push("assistant", table.concat({
    "I'll add a bounded retry with jittered backoff.",
    "",
    "```lua",
    "-- Retry on 429/5xx only. Jitter keeps a fleet of agents from",
    "-- resynchronising on the same second after a rate limit.",
    "local function backoff_ms(attempt)",
    "  local base = M.RETRY.base_ms * (2 ^ (attempt - 1))",
    "  return math.min(base, M.RETRY.max_ms) * (0.5 + math.random())",
    "end",
    "```",
    "",
    "Applying it to `lua/api.lua` now.",
  }, "\n"))
  v:push("tool", "read lua/api.lua", "read")

  local old = "local M = {}\n\nfunction M.endpoint()\n  return auth.base_url()\nend\n"
  local new = "local M = {}\n\nM.RETRY = { attempts = 4, base_ms = 500, max_ms = 8000 }\n\n"
    .. "function M.endpoint()\n  return auth.base_url()\nend\n"
  v:push("diff", "", { diff = difflib.compute(old, new), path = "lua/api.lua" })

  v:push("error", "endpoint unreachable: connection refused (retrying in 1.2s)")
  v:push("assistant", "Retried and succeeded. The helper is in place.")

  v:set_input("now run @lua/api.lua through the tests")
  v.pending = { name = "write", summary = "lua/api.lua  +2 -0  at line 3" }
  bog.session.usage = { input = 18420, output = 2130, cached = 41200, turns = 7,
                        last_input = 59620 }

  -- Assertions a rendered frame can make and a headless probe cannot: the
  -- panel is in the node tree, it has a non-zero size, and asking for it twice
  -- does not build a second one.
  local problems = {}
  local function check(ok, msg) if not ok then problems[#problems + 1] = msg end end

  check(studio.agent_view() == v, "agent_view() does not find the open panel")
  check(studio.open_agent() == v, "open_agent() built a second panel")
  local node = core.root_view.root_node:get_node_for_view(v)
  check(node ~= nil, "panel is not attached to the node tree")

  core.redraw = true
  for _ = 1, 4 do coroutine.yield(0.15) end   -- let the frame reach the framebuffer

  check(v.size.x > 100, "panel width is " .. tostring(v.size.x) .. " (collapsed)")
  check(v.size.y > 100, "panel height is " .. tostring(v.size.y) .. " (collapsed)")

  local ok, err = system.save_screenshot(OUT)
  check(ok, "save_screenshot failed: " .. tostring(err))

  if #problems > 0 then
    io.write("FAIL\n")
    for _, p in ipairs(problems) do io.write("  - " .. p .. "\n") end
    io.flush()
    os.exit(1)
  end
  io.write(string.format("ok  panel %dx%d  wrote %s\n", v.size.x, v.size.y, OUT))
  io.flush()
  os.exit(0)
end)
