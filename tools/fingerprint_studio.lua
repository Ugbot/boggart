-- Runs tools/fingerprint.lua inside boggart-studio and exits.
--
-- The studio has no --eval: it is a window, and its Lua starts when the editor
-- does. BOGGART_STUDIO_SCRIPT is the scripted entry point core/init.lua runs
-- after the user module, which is also how the UI checks drive it.
local core = require "core"
core.add_thread(function()
  coroutine.yield(0.3)
  -- Studio connects MCP after the first frame. Wait until that thread
  -- finishes so the tool list matches the CLI, which still loads at boot.
  local until_t = system.get_time() + 20
  while bog and bog._mcp_loading and system.get_time() < until_t do
    coroutine.yield(0.05)
  end
  local ok, err = pcall(dofile, assert(os.getenv("BOGGART_FINGERPRINT"),
    "BOGGART_FINGERPRINT is not set"))
  if not ok then
    io.write("fingerprint failed: ", tostring(err), "\n")
    io.flush()
    os.exit(1)
  end
  io.flush()
  os.exit(0)
end)
