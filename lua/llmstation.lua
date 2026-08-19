-- llmstation.lua -- detect a local LLM Station install and expose its 70+
-- deterministic code-intelligence tools (TreeSitter AST, call graphs, LSP, BM25,
-- refactoring, ...) to boggart over MCP, registered as mcp__llm-station__*.
--
-- It fits boggart's grain: LLM Station already ships an MCP adapter
-- (`llm-station mcp --workspace <ws>`), and boggart already hosts MCP servers
-- (lua/mcphost.lua + src/lmcp.c). So the "wrapper" is thin -- find the binary,
-- hand it to the MCP host -- and entirely best-effort: if LLM Station is not
-- installed, this is dormant and boggart is unchanged. "Use it if the daemon is
-- there."
local M = {}

M.SERVER = "llm-station"

-- Locate the llm-station binary. Order: an explicit override, then PATH, then a
-- wheel `bin/` or a source build under ~/llm-station, then the usual bin dirs.
function M.binary()
  local override = os.getenv("BOGGART_LLM_STATION") or os.getenv("LLM_STATION_BIN")
  if override and override ~= "" and sys.stat(override) == "file" then return override end

  -- on PATH
  local ok, r = pcall(sys.exec, "command -v llm-station 2>/dev/null", 5)
  if ok and r and type(r.out) == "string" then
    local p = r.out:gsub("%s+$", "")
    if p ~= "" and sys.stat(p) == "file" then return p end
  end

  -- common install / build locations (globbed, so a preset subdir is found)
  local home = sys.home()
  local candidates = {
    home .. "/llm-station/bin/llm-station",
    home .. "/llm-station/build*/llm-station",     -- build, build-mcp, build-arm64...
    home .. "/llm-station/build*/bin/llm-station",
    home .. "/llm-station/build*/*/llm-station",    -- preset subdir layouts
    home .. "/.local/bin/llm-station",
    "/usr/local/bin/llm-station",
    "/opt/homebrew/bin/llm-station",
  }
  for _, g in ipairs(candidates) do
    for _, p in ipairs(gold.fs.glob(g)) do
      if sys.stat(p) == "file" then return p end
    end
  end
  return nil
end

function M.available() return M.binary() ~= nil end

-- POSIX single-quote so a path with spaces survives the shell.
local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

-- Try to LAUNCH the LLM Station daemon (detached), so it is up for boggart and
-- any other client. Best-effort: the MCP adapter also runs standalone, so this
-- is an optimisation (a persistent, shared daemon), not a requirement. Returns
-- true if the launch command was issued.
function M.launch(workspace)
  local bin = M.binary()
  if not bin then return false, "llm-station binary not found" end
  workspace = workspace or (sys.cwd and sys.cwd()) or "."
  local cmd = shq(bin) .. " start --workspace " .. shq(workspace) .. " >/dev/null 2>&1 &"
  local ok = pcall(sys.exec, cmd, 5)
  return ok == true
end

-- Connect LLM Station's MCP adapter and register its tools. `workspace` defaults
-- to the current project. Returns the tool-name list, or nil + reason. The MCP
-- host has its own connect timeout, so a binary present but a daemon that will
-- not answer fails cleanly rather than hanging.
function M.attach(workspace)
  if not bog.mcphost then return nil, "MCP host unavailable" end
  local bin = M.binary()
  if not bin then return nil, "llm-station binary not found" end
  workspace = workspace or (sys.cwd and sys.cwd()) or "."
  return bog.mcphost.add{
    name = M.SERVER,
    command = bin,
    args = { "mcp", "--workspace", workspace },
  }
end

-- Best-effort auto-detect at startup: attach quietly when installed, log the
-- outcome, and never raise. No-op (returns false) when LLM Station is absent.
-- If the first attach fails, TRY TO LAUNCH the daemon and attach once more, so
-- boggart brings LLM Station up itself rather than only using an already-running
-- one.
function M.autostart()
  if not M.available() then return false end

  local names, err = M.attach()
  if not names then
    -- couldn't connect: try to start the daemon, give it a moment, retry once
    if M.launch() then
      -- A hard sleep freezes the studio frame loop. Yield a second when
      -- we are inside a core thread; the CLI still waits in-process.
      if coroutine.isyieldable() then coroutine.yield(1)
      else pcall(sys.exec, "sleep 1", 3) end
      names, err = M.attach()
    end
  end

  if names then
    bog.log(string.format("llm-station: connected (%d tools) as mcp__%s__*",
      #names, M.SERVER))
    return true
  end
  bog.log("llm-station: detected but could not connect: " .. tostring(err))
  return false
end

return M
