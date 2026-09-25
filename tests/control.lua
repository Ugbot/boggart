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
-- This fixture explicitly authorizes repeated read polling; route/token scope
-- and parser rejection are independent from the legacy doom-loop ask guard.
require("perm").state().headless="allow"

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
local started_event
local started_listener=bog.events.on("serve:started",function(_,e) started_event=e end)
local server, url = S.start{ host = "127.0.0.1", port = 0 }
ok(server ~= nil, "the control plane starts on loopback: " .. tostring(url))
if not server then
  io.write(string.format("control: %d passed, %d failed\n", passed, failed + 1))
  os.exit(1)
end
ok(started_event and started_event.token==nil,"startup evidence excludes token")
ok(S.token==nil and type(S.client_token())=="string","token retrieval is host-only explicit API")
bog.events.off(started_listener)
local port = server:port()
ok(port and port > 0, "the OS assigned a port (" .. tostring(port) .. ")")

local base = "http://127.0.0.1:" .. port
local default_auth="-H 'Authorization: Bearer "..S.client_token().."'"

-- curl through proc so the uv loop keeps turning while the request is in flight
local function GET(path, extra)
  local r = proc.run(string.format("curl -sS --max-time 5 %s '%s%s'",
    extra or default_auth, base, path), 10)
  return r.out or ""
end
local function POST(path, body, extra)
  local r = proc.run(string.format(
    "curl -sS --max-time 5 %s -X POST -H 'Content-Type: application/json' -d '%s' '%s%s'",
    extra or default_auth, body or "{}", base, path), 10)
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

-- Session discovery uses the store's public listing API.  Exercise this over
-- the real HTTP route so a misspelled method cannot quietly look like an empty
-- store, and so the wire representation of zero rows remains a JSON array.
local sid = bog.store.sess_create("control route fixture", "test-model")
local sessions = json.decode(GET("/sessions?limit=1"))
eq(#(sessions.sessions or {}), 1, "/sessions returns a populated store")
eq(sessions.sessions and sessions.sessions[1] and sessions.sessions[1].id, sid,
   "/sessions returns the stored session")
bog.store.sess_delete(sid)
local empty_sessions = GET("/sessions?limit=1")
ok(empty_sessions:find('"sessions":[]', 1, true) ~= nil,
   "/sessions encodes zero rows as an empty JSON array")

local real_sess_list = bog.store.sess_list
bog.store.sess_list = function() error("simulated session store failure") end
local session_error = json.decode(GET("/sessions"))
local session_status=tonumber(GET("/sessions",default_auth.." -o /dev/null -w '%{http_code}'"))
eq(session_status,500,"session store failure is HTTP500")
bog.store.sess_list = real_sess_list
ok(session_error.error and session_error.error:find("simulated session store failure", 1, true),
   "/sessions exposes store failures instead of returning zero rows")

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
ok(GET("/health", ""):find("unauthorized"), "a request with no token is rejected")
ok(GET("/health", "-H 'Authorization: Bearer " .. tok .. "'"):find('"ok"'),
   "a request with the right token is served")
ok(GET("/health", "-H 'Authorization: Bearer wrong'"):find("unauthorized"),
   "a request with the wrong token is rejected")
-- Actual wire status, parsed Host/Origin and header ambiguity.
local function status(path, extra)
  return tonumber(GET(path,(extra or ("-H 'Authorization: Bearer "..tok.."'")).." -o /dev/null -w '%{http_code}'"))
end
eq(status("/health",""),401,"missing authentication status")
eq(status("/cancel","-X POST"),401,"unauthenticated mutation refused")
eq(status("/health","-H 'Authorization: Bearer "..tok.."' -H 'Origin: "..base.."' -H 'Origin: "..base.."'"),400,"duplicate Origin refused")
eq(status("/health","-H 'Authorization: Bearer "..tok.."' -H 'Origin: http://evil.invalid'"),403,"wrong origin status")
eq(status("/health","-H 'Authorization: Bearer "..tok.."' -H 'Host: evil.invalid'"),403,"wrong host status")
eq(status("/health","-H 'Authorization: Bearer "..tok.."' -H 'Origin: "..base.."'"),200,"same origin configured client")
eq(status("/health","-H 'Authorization: Bearer "..tok.."' -H 'Authorization: Bearer "..tok.."'"),400,"duplicate authorization refused")
S.stop()
local scoped=S.start{token=tok,capabilities={"control:GET:/health","control:POST:/prompt"}}
base="http://127.0.0.1:"..scoped:port()
eq(status("/health"),200,"scoped token reads granted route")
eq(status("/sessions"),403,"scoped token cannot read ungranted route")
eq(status("/prompt","-X POST -d '{}' -H 'Authorization: Bearer "..tok.."'"),400,"scoped deferred route validates input")
local queued_job
local queue_handle=bog.events.on("serve:prompt",function(_,ev)queued_job=ev end)
local admitted=json.decode(POST("/prompt",'{"text":"scoped","policy":{"allow":["*"]}}',"-H 'Authorization: Bearer "..tok.."'"))
ok(admitted.accepted and queued_job,"scoped prompt enters actual deferred queue")
local effects=0
bog.tools.register("_control_deferred_write",{effect="write",run=function()effects=effects+1;return "written"end})
local A=require("trigger_authority")
local output=A.execute(queued_job,function()return bog.tools.run("_control_deferred_write",{})end)
eq(effects,0,"scoped queued prompt cannot manufacture write authority")
S.revoke()
A.execute(queued_job,function()return bog.tools.run("_control_deferred_write",{})end)
eq(effects,0,"post-enqueue client revocation remains restrictive")
bog.events.off(queue_handle)
S.stop()
local trusted=S.start{profile="trusted_local"}
base="http://127.0.0.1:"..trusted:port()
eq(status("/health",""),200,"explicit trusted local profile")
eq(status("/health","-H 'Origin: null'"),403,"trusted local still validates browser origin")
S.stop()

eq(S.server, nil, "stop() clears the server")

io.write(string.format("control: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
