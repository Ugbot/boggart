-- uistart.lua -- prove the studio window came up and survived first paint.
--
-- BOGGART_STUDIO_SCRIPT. MCP servers may abort; that is not our problem.
-- This only checks that the window is still standing afterwards.
local core = require "core"
local studio = require "core.studio"

core.add_thread(function()
  local t0 = system.get_time()
  for _ = 1, 12 do
    core.redraw = true
    coroutine.yield(0.05)
  end

  local v = studio.agent_view() or studio.view
  if not v then
    io.stderr:write("uistart: no agent view after init\n")
    os.exit(1)
  end
  if (v.size.x or 0) < 16 or (v.size.y or 0) < 16 then
    io.stderr:write(string.format("uistart: agent view is %.0fx%.0f (not laid out)\n",
      v.size.x or 0, v.size.y or 0))
    os.exit(1)
  end
  if core.error_view then
    io.stderr:write("uistart: error view is up\n")
    os.exit(1)
  end

  -- The 2026-08-19 crash: a resumed chat with ```unknownlang took the window
  -- down inside syntax.get on the first AgentView:draw. Push one and paint.
  if v.push then
    v:push("assistant", "```unknownlang\nhello from uistart\n```")
  end
  for _ = 1, 6 do
    core.redraw = true
    coroutine.yield(0.05)
  end
  if core.error_view then
    io.stderr:write("uistart: error view after painting an unknown fence\n")
    os.exit(1)
  end

  local okd, errd = pcall(function() v:draw() end)
  if not okd then
    io.stderr:write("uistart: agent draw raised: " .. tostring(errd) .. "\n")
    os.exit(1)
  end

  -- MCP children can abort (llm-station does). That must not take us down.
  while system.get_time() - t0 < 4 do
    if core.error_view then
      io.stderr:write("uistart: error view while MCP was starting\n")
      os.exit(1)
    end
    core.redraw = true
    coroutine.yield(0.2)
  end

  io.write(string.format("ok  studio started, agent %.0fx%.0f\n", v.size.x, v.size.y))
  io.flush()
  os.exit(0)
end)
