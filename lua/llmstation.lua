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
  -- The NEWEST match wins, not the first. A source tree accumulates build
  -- dirs (build-mcp, build/macos-arm64, ...) and glob order is alphabetical,
  -- so "first" was an old build that no longer speaks the current daemon
  -- protocol: it launched, then never answered a ZMQ ping.
  local best, best_t = nil, -1
  for _, g in ipairs(candidates) do
    for _, p in ipairs(gold.fs.glob(g)) do
      local kind, mtime = sys.stat(p)
      if kind == "file" and (mtime or 0) > best_t then best, best_t = p, mtime or 0 end
    end
  end
  return best
end

function M.available() return M.binary() ~= nil end


-- Try to LAUNCH the LLM Station daemon (detached), so it is up for boggart and
-- any other client. Best-effort: the MCP adapter also runs standalone, so this
-- is an optimisation (a persistent, shared daemon), not a requirement. Returns
-- true if the launch command was issued.
function M.launch(workspace)
  local bin = M.binary()
  if not bin then return false, "llm-station binary not found" end
  workspace = workspace or (sys.cwd and sys.cwd()) or "."
  -- Spawned DETACHED (its own session) and unref'd, never through sys.exec:
  -- sys.exec runs the command in a process group it tears down on return, so
  -- `start ... &` launched the daemon and then killed it a moment later -- the
  -- launch "succeeded" and nothing was ever listening. `start` daemonizes and
  -- exits; the daemon it forks inherits the new session and outlives us.
  local ok, uv = pcall(require, "uv")
  if not ok then return false end
  local handle = uv.spawn(bin, {
    args = { "start", "--workspace", workspace },
    detached = true,
    stdio = { nil, nil, nil },
  }, function() end)
  if not handle then return false end
  uv.unref(handle)
  return true
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
  -- Transport rule (docs/station-zmq.md): when the ZMQ client is built and a
  -- daemon answers, station traffic goes over ZMQ and the MCP mount is not
  -- connected. Missing ZMQ degrades to native tools. MCP is selected only
  -- explicitly (BOGGART_STATION_FORCE_MCP=1).
  local okz, stn = pcall(require, "stationlink")
  if os.getenv("BOGGART_STATION_FORCE_MCP") ~= "1" and okz and stn and stn.active and stn.active() then
    bog.log("llm-station: native ZMQ transport active; MCP mount not connected")
    return true
  end
  if os.getenv("BOGGART_STATION_FORCE_MCP") ~= "1" then return false end
  if not M.available() then return false end
  if bog.mcphost and bog.mcphost.conns[M.SERVER] then return true end

  local names, err = M.attach()
  if not names then
    -- couldn't connect: try to start the daemon, give it a moment, retry once
    if M.launch() then
      -- A hard sleep freezes the studio frame loop. Yield a uv timer so
      -- both the swarm scheduler (which treats a bare `1` as "runnable")
      -- and a studio thread keep pumping.
      require("proc").sleep(1)
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
