-- control.lua -- the inbound control surface: C transport + enforcement, Lua routes.
--
-- Two halves, tested as two halves, because the split is the design:
--
--   C   (src/lserve.c)  the socket, HTTP framing, the bind rule, the token check
--   Lua (lua/control.lua) which routes exist and what they answer
--
-- The C half is here because Lua has no sockets -- no amount of rewriting the
-- harness can open a listening port -- and because two of its rules must not be
-- reachable by the Lua the agent edits: it binds loopback unless told
-- otherwise, and a non-loopback bind with no token is refused outright. Those
-- two are the tests that matter most in this file.
--
-- The round trips go through curl driven by lua/proc.lua, whose wait() turns
-- the same uv loop the listener is on -- so the request and the accept really
-- do happen concurrently, in one process, the way they will in production.
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

local json = require "json"
local proc = require "proc"
local S = require "control"

-- ---- C: entropy ----------------------------------------------------------
local t1, t2 = serve.token(24), serve.token(24)
eq(#t1, 48, "serve.token(24) is 48 hex characters")
ok(t1 ~= t2, "two tokens differ")
ok(t1:match("^%x+$") ~= nil, "the token is hex")
eq(#serve.token(4), 16, "a too-short request is clamped up, not honoured")

-- ---- C: the bind rule ----------------------------------------------------
-- The enforcement that cannot live in Lua: binding somewhere the network can
-- reach, with no token, is refused by the C that owns the socket.
local srv, why = serve.listen{ host = "0.0.0.0", handler = function() return 200, "" end }
eq(srv, nil, "a non-loopback bind with no token is refused")
ok(tostring(why):find("token"), "and it says why: " .. tostring(why))

-- ---- start on loopback ---------------------------------------------------
local server, url = S.start{ host = "127.0.0.1", port = 0 }
ok(server ~= nil, "the control plane starts on loopback: " .. tostring(url))
if not server then
  io.write(string.format("control: %d passed, %d failed\n", passed, failed + 1))
  os.exit(1)
end
local port = server:port()
ok(port and port > 0, "the OS assigned a port (" .. tostring(port) .. ")")

local base = "http://127.0.0.1:" .. port

-- curl through proc so the uv loop keeps turning while the request is in flight
local function GET(path, extra)
  local r = proc.run(string.format("curl -sS --max-time 5 %s '%s%s'",
    extra or "", base, path), 10)
  return r.out or ""
end
local function POST(path, body, extra)
  local r = proc.run(string.format(
    "curl -sS --max-time 5 %s -X POST -H 'Content-Type: application/json' -d '%s' '%s%s'",
    extra or "", body or "{}", base, path), 10)
  return r.out or ""
end

-- ---- routes --------------------------------------------------------------
local health = json.decode(GET("/health"))
eq(health.ok, true, "/health answers")
eq(health.version, boggart.version, "/health reports the running version")
ok(health.mode ~= nil, "/health reports the mode")

local routes = json.decode(GET("/routes"))
ok(type(routes.routes) == "table" and #routes.routes > 4,
   "/routes describes the control plane (" .. tostring(#(routes.routes or {})) .. " routes)")

local tools = json.decode(GET("/tools"))
ok(type(tools.tools) == "table" and #tools.tools > 5,
   "/tools lists the live registry (" .. tostring(#(tools.tools or {})) .. " tools)")

local perms = json.decode(GET("/permissions"))
ok(perms.mode ~= nil, "/permissions reports the mode")
ok(type(perms.modes) == "table", "/permissions offers the mode list")

-- setting the policy over the wire, including a rule table
local set = json.decode(POST("/permissions",
  '{"mode":"manual","rules":{"bash":{"git *":"allow"}}}'))
eq(set.mode, "manual", "POST /permissions changes the mode")
eq(require("perm").state().mode, "manual", "and the change is the shared state")
eq(require("perm").decide("bash", { command = "git log" }, require("perm").state()), "allow",
   "the rule posted over the wire is the rule the tool loop enforces")
require("perm").set_mode("smart")

-- ---- webhooks: the inbound trigger ---------------------------------------
local fired = nil
local h = bog.events.on("hook:deploy", function(_, d) fired = d end)
local hook = json.decode(POST("/hooks/deploy", '{"ref":"refs/heads/main"}'))
eq(hook.delivered, "hook:deploy", "a webhook is accepted")
ok(fired ~= nil, "the webhook became a boggart event")
eq(fired and fired.body and fired.body.ref, "refs/heads/main", "the payload survives the trip")
bog.events.off(h)

-- ---- errors --------------------------------------------------------------
local missing = json.decode(GET("/nope"))
ok(missing.error ~= nil, "an unknown path is a 404 with a reason")
local bad = json.decode(POST("/prompt", '{}'))
ok(bad.error ~= nil, "a prompt with no text is refused")
local queued = json.decode(POST("/prompt", '{"text":"hello"}'))
eq(queued.accepted, true, "a well-formed prompt is accepted")

S.stop()

-- ---- C: the token check --------------------------------------------------
-- Checked before any route is reached, so no Lua route can forget it.
local tok = serve.token(16)
local server2 = S.start{ host = "127.0.0.1", port = 0, token = tok }
ok(server2 ~= nil, "a token-protected server starts")
base = "http://127.0.0.1:" .. server2:port()
ok(GET("/health"):find("unauthorized"), "a request with no token is rejected")
ok(GET("/health", "-H 'Authorization: Bearer " .. tok .. "'"):find('"ok"'),
   "a request with the right token is served")
ok(GET("/health", "-H 'Authorization: Bearer wrong'"):find("unauthorized"),
   "a request with the wrong token is rejected")
S.stop()

eq(S.server, nil, "stop() clears the server")

io.write(string.format("control: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
