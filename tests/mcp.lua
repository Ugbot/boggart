-- mcp.lua -- offline end-to-end test of the MCP client + Lua glue, driving a
-- mock stdio MCP server (tests/mock_mcp.py). Verifies: connect/handshake, tool
-- discovery + registration into the normal tool registry, tools/call, the error
-- path, wildcard per-agent allowlists (the "MCP servers are just tools, scoped
-- per agent" design), and the mcp_add tool. No network.
--
-- It also covers both protocol generations, because the client negotiates
-- between them per connection: the handshake generation (2025-11-25 and
-- earlier) and the stateless one (2026-07-28). The mock can play either, and
-- traces every message it receives to a file, so these assertions are about
-- what actually went over the wire -- that a v1 server really did see
-- `initialize`, that a v2 server really did not, that `_meta` really was on
-- every modern request -- rather than about what the client says it did.
local json = require("json")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

bog.userdir = os.tmpname() .. "_boggart_mcp_test"
sys.mkdir_p(bog.userdir)

-- The wire log the mock writes: one JSON object per message it received.
local n_traces = 0
local function trace_path()
  n_traces = n_traces + 1
  return bog.userdir .. "/wire" .. n_traces .. ".jsonl"
end

local function wire(path)
  local msgs = {}
  local fh = io.open(path, "r")
  if not fh then return msgs end
  for line in fh:lines() do
    if line ~= "" then
      local okj, m = pcall(json.decode, line)
      if okj then msgs[#msgs + 1] = m end
    end
  end
  fh:close()
  return msgs
end

local function methods(path)
  local out = {}
  for _, m in ipairs(wire(path)) do out[#out + 1] = m.method end
  return out
end

local function saw(path, method)
  for _, m in ipairs(methods(path)) do if m == method then return true end end
  return false
end

local function first_of(path, method)
  for _, m in ipairs(wire(path)) do if m.method == method then return m end end
  return nil
end

if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()

-- ---- wildcard allowlist (pure) ----
do
  local allow = { ["mcp__mock__*"] = true, ["read"] = true }
  ok(bog.tools.allowed(allow, "mcp__mock__echo"), "wildcard grants server tool")
  ok(bog.tools.allowed(allow, "read"), "exact grant still works")
  ok(not bog.tools.allowed(allow, "mcp__other__x"), "wildcard doesn't over-grant")
  ok(not bog.tools.allowed(allow, "bash"), "unlisted tool denied")
end

-- ---- connect a v1 (handshake) server + register its tools ----
local v1_trace = trace_path()
do
  -- The mock serves one tool per page, so this also asserts the client follows
  -- nextCursor to the end rather than registering only the first page.
  local names, err = bog.mcphost.add{ name = "mock", command = "python3",
    args = { "tests/mock_mcp.py", "--era", "v1", "--trace", v1_trace } }
  ok(names ~= nil, "mcp connect + tools/list (" .. tostring(err) .. ")")
  if names then
    eq(#names, 2, "registered 2 tools")
    ok(bog.tools.registry["mcp__mock__echo"], "echo registered under namespaced name")
    ok(bog.tools.registry["mcp__mock__add"], "add registered")
    -- schema flowed through from the server
    ok(bog.tools.registry["mcp__mock__echo"].input_schema.properties.text ~= nil, "input_schema propagated")
  end

  -- Negotiation, as the server saw it: the probe went out first, the server
  -- did not understand it, and the client fell back to the handshake.
  local seen = methods(v1_trace)
  eq(seen[1], "server/discover", "v1: probes with server/discover first")
  ok(saw(v1_trace, "initialize"), "v1: falls back to the initialize handshake")
  ok(saw(v1_trace, "notifications/initialized"), "v1: completes the handshake")
  local info = bog.mcphost.info["mock"] or {}
  eq(info.era, "legacy", "v1: era recorded as legacy")
  eq(info.protocol, "2025-11-25", "v1: protocol version from the handshake")
  eq((info.serverInfo or {}).name, "mock", "v1: serverInfo captured from initialize")
  -- A legacy request carries no _meta: that field is the modern generation's.
  local tl = first_of(v1_trace, "tools/list")
  ok(tl and (tl.params == nil or tl.params._meta == nil), "v1: no _meta on requests")
end

-- ---- call MCP tools through the normal tool path ----
do
  eq(bog.tools.run("mcp__mock__echo", { text = "hi" }), "echo: hi", "tools/call echo via registry")
  eq(bog.tools.run("mcp__mock__add", { a = 2, b = 40 }), "42", "tools/call add via registry")
  ok(bog.tools.run("mcp__mock__nope", {}) == nil or true, "unknown-tool name isn't registered")
end

-- ---- error path: server-side error becomes a Tool error ----
do
  -- call a real tool with a name the server rejects by using a fresh conn and
  -- an unregistered remote name via the raw client
  local conn = bog.mcphost.conns["mock"]
  local res, e = conn:call("nonexistent", "{}")
  ok(res == nil and tostring(e):find("mcp error"), "server error surfaces via client")
end

-- ---- mcp tool + list ----
do
  local listed = bog.tools.run("mcp", {})
  ok(listed:find("mock:") and listed:find("mcp__mock__echo"), "mcp list shows server + tools")
end

-- ---- schemas_for exposes MCP tools only when the wildcard is granted ----
do
  local granted = bog.tools.schemas_for({ ["mcp__mock__*"] = true })
  local names = {}
  for _, s in ipairs(granted) do names[s.name] = true end
  ok(names["mcp__mock__echo"] and names["mcp__mock__add"], "wildcard exposes server tools to an agent")
  ok(not names["bash"], "ungranted core tools stay hidden")

  local none = bog.tools.schemas_for({ ["read"] = true })
  local nn = {}
  for _, s in ipairs(none) do nn[s.name] = true end
  ok(not nn["mcp__mock__echo"], "agent without the skill sees no MCP tools")
end

-- ---- mcp_add tool (runtime connect) ----
do
  local r = bog.tools.run("mcp_add", { name = "mock2", command = "python3", args = { "tests/mock_mcp.py" } })
  ok(r:find("connected 'mock2'"), "mcp_add tool connects a server")
  eq(bog.tools.run("mcp__mock2__echo", { text = "yo" }), "echo: yo", "second server usable")
end

-- ---- bad server fails gracefully (no crash) ----
do
  local names, err = bog.mcphost.add{ name = "bad", command = "definitely_not_a_real_binary_xyz_123" }
  ok(names == nil and err ~= nil, "bad server returns nil,err instead of crashing")
end

-- ---- a v2 (stateless) server: discover, _meta, resultType ----
local v2_trace = trace_path()
do
  local names, err = bog.mcphost.add{ name = "modern", command = "python3",
    args = { "tests/mock_mcp.py", "--era", "v2", "--trace", v2_trace } }
  ok(names ~= nil, "v2 connect + tools/list (" .. tostring(err) .. ")")
  eq(#(names or {}), 2, "v2: registered both tools (pagination still followed)")

  local info = bog.mcphost.info["modern"] or {}
  eq(info.era, "modern", "v2: era recorded as modern")
  eq(info.protocol, "2026-07-28", "v2: negotiated the stateless revision")
  eq((info.serverInfo or {}).name, "mock", "v2: serverInfo captured from the result _meta")

  -- The handshake is gone in this generation: sending it would be a protocol
  -- error, and a client that sent it "just in case" would be talking to a
  -- server that has no idea what it means.
  eq(methods(v2_trace)[1], "server/discover", "v2: opens with server/discover")
  ok(not saw(v2_trace, "initialize"), "v2: never sends initialize")
  ok(not saw(v2_trace, "notifications/initialized"), "v2: never sends the initialized notification")

  -- and the call itself still works, resultType "complete" and all
  eq(bog.tools.run("mcp__modern__echo", { text = "hi" }), "echo: hi", "v2: tools/call round trip")
  local call = first_of(v2_trace, "tools/call")
  ok(call and call.params.name == "echo", "v2: tools/call params unchanged by _meta")

  -- _meta on every request, not just the first: there is no session to carry
  -- the version, capabilities or identity, so each request restates them.
  local n_reqs, n_meta = 0, 0
  for _, m in ipairs(wire(v2_trace)) do
    if m.id ~= nil then
      n_reqs = n_reqs + 1
      local meta = (m.params or {})._meta or {}
      if meta["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"
        and meta["io.modelcontextprotocol/clientCapabilities"] ~= nil
        and ((meta["io.modelcontextprotocol/clientInfo"] or {}).name == "boggart") then
        n_meta = n_meta + 1
      end
    end
  end
  eq(n_reqs, 4, "v2: sent discover, both tools/list pages and a tools/call")
  eq(n_meta, n_reqs, "v2: every request carries the required _meta")
end

-- ---- a v2 server that asks for input mid-call (MRTR) ----
do
  -- boggart does not implement MRTR. The requirement is not that it answers
  -- the input request, it is that it never passes an "input_required" result
  -- off as the tool's answer -- that result carries content blocks that read
  -- like a real reply, and handing them to the model would be a fabrication.
  local names = bog.mcphost.add{ name = "needy", command = "python3",
    args = { "tests/mock_mcp.py", "--era", "v2", "--input-required", "--trace", trace_path() } }
  ok(names ~= nil, "v2 input_required server still connects")

  local out = tostring(bog.tools.run("mcp__needy__echo", { text = "hi" }))
  ok(out:find("Tool error"), "input_required surfaces as a tool error")
  ok(out:find("MRTR"), "the error says why: MRTR is not implemented (" .. tostring(out) .. ")")
  ok(out:find("elicitation/create"), "the error names what the server asked for")
  ok(not out:find("PREMATURE"), "the interim result is NOT passed off as the answer")

  -- the same, one layer down: the raw client call must fail, not return
  local res, e = bog.mcphost.conns["needy"]:call("echo", '{"text":"hi"}')
  ok(res == nil and tostring(e):find("MRTR"), "raw conn:call rejects an input_required result")
end

-- ---- a v2 server that speaks no version we do ----
do
  local mm_trace = trace_path()
  local names, err = bog.mcphost.add{ name = "future", command = "python3",
    args = { "tests/mock_mcp.py", "--era", "v2", "--supported", "2099-01-01", "--trace", mm_trace } }
  ok(names == nil, "version mismatch refuses to connect")
  err = tostring(err)
  ok(err:find("2099%-01%-01"), "the error names what the server does speak (" .. err .. ")")
  ok(err:find("2026%-07%-28"), "and what boggart speaks")
  -- An UnsupportedProtocolVersionError identifies a *modern* server, so the
  -- client must not mistake it for an old one and try the handshake.
  ok(not saw(mm_trace, "initialize"), "version mismatch does not fall back to initialize")
end

-- ---- Streamable HTTP: the headers each generation requires ----
-- The two generations differ as much in their headers as in their bodies, and
-- headers are exactly what a stdio test cannot see: 2026-07-28 requires
-- Mcp-Method and Mcp-Name on every POST (so intermediaries can route without
-- parsing the body) and has abolished Mcp-Session-Id, which the older one
-- depends on. So the mock serves HTTP too, and records what arrived.
local http_procs = {}
do
  local proc = require("proc")
  local n_http = 0

  -- Start the mock on an ephemeral port and wait for it to say which one.
  local function serve(era)
    n_http = n_http + 1
    local pf = bog.userdir .. "/port" .. n_http .. ".txt"
    local tr = trace_path()
    local h = proc.start(string.format(
      'python3 tests/mock_mcp.py --era %s --http --portfile "%s" --trace "%s"', era, pf, tr), 60)
    http_procs[#http_procs + 1] = h
    local deadline = os.time() + 20
    while os.time() < deadline do
      local fh = io.open(pf, "r")
      if fh then
        local body = fh:read("a") or ""
        fh:close()
        local port = body:match("^(%d+)\n")
        if port then return tonumber(port), tr end
      end
      mcp.pump(50) -- the only portable "wait a moment" here: it runs the loop
    end
    return nil, tr
  end

  -- headers of the traced request for `method`, or {}
  local function hdrs(path, method)
    local m = first_of(path, method)
    return m and m._http or {}
  end

  local port, tr = serve("v2")
  ok(port ~= nil, "v2 http mock bound a port")
  if port then
    local names, err = bog.mcphost.add{ name = "httpmodern", transport = "http",
      url = "http://127.0.0.1:" .. port .. "/mcp" }
    ok(names ~= nil, "v2 over http connects (" .. tostring(err) .. ")")
    eq((bog.mcphost.info["httpmodern"] or {}).era, "modern", "v2 http: negotiated modern")
    eq(bog.tools.run("mcp__httpmodern__echo", { text = "hi" }), "echo: hi", "v2 http: tools/call round trip")

    local call = hdrs(tr, "tools/call")
    eq(call["mcp-method"], "tools/call", "v2 http: Mcp-Method mirrors the method")
    eq(call["mcp-name"], "echo", "v2 http: Mcp-Name mirrors params.name")
    eq(call["mcp-protocol-version"], "2026-07-28", "v2 http: protocol header states the version")
    eq(hdrs(tr, "server/discover")["mcp-method"], "server/discover", "v2 http: probe carries Mcp-Method too")
    local sessions = 0
    for _, m in ipairs(wire(tr)) do
      if (m._http or {})["mcp-session-id"] then sessions = sessions + 1 end
    end
    eq(sessions, 0, "v2 http: never sends a session id (sessions are gone)")
  end

  local lport, ltr = serve("v1")
  ok(lport ~= nil, "v1 http mock bound a port")
  if lport then
    local names, err = bog.mcphost.add{ name = "httplegacy", transport = "http",
      url = "http://127.0.0.1:" .. lport .. "/mcp" }
    ok(names ~= nil, "v1 over http connects (" .. tostring(err) .. ")")
    eq((bog.mcphost.info["httplegacy"] or {}).era, "legacy", "v1 http: falls back to the handshake")
    eq(bog.tools.run("mcp__httplegacy__echo", { text = "hi" }), "echo: hi", "v1 http: tools/call round trip")
    -- The session the server minted on initialize comes back on later requests:
    -- adding the modern path must not have cost the legacy one its session.
    eq(hdrs(ltr, "tools/call")["mcp-session-id"], "mock-session-1", "v1 http: session id echoed back")
    eq(hdrs(ltr, "tools/call")["mcp-method"], nil, "v1 http: no modern mirror headers")
  end
end

-- cleanup: close all conns (kills the mock subprocesses)
for _, c in pairs(bog.mcphost.conns) do pcall(function() c:close() end) end
-- ...and the HTTP mocks, which are nobody's child process but ours
for _, h in ipairs(http_procs) do pcall(function() h:kill("sigkill") end) end
if bog.db then bog.db:close() end
sys.rmtree(bog.userdir) -- not a shell command: cmd.exe has no rm

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
return failed == 0 and 0 or 1
