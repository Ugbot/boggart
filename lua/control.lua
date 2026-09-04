-- control.lua -- the ROUTING half of the control surface.
--
-- Named apart from the C `serve` global on purpose: `serve` is the socket and
-- the rules that cannot move, `control` is the plane built on top of it. The socket, the HTTP
-- framing and the two non-negotiable rules (loopback-by-default, constant-time
-- token) live in C (src/lserve.c) because Lua has no sockets and because an
-- enforcement point the agent can rewrite is not an enforcement point. This
-- file is everything else, and it is deliberately ordinary Lua: which routes
-- exist, what they answer, and what they are allowed to touch.
--
-- That split is the whole design. Routes change every week; a listening socket
-- and an auth check must not change at all. So:
--
--   C   accept, parse, cap, authenticate, write, keep SSE streams alive
--   Lua route table, payload shapes, what each route may do, event bridging
--
-- The control plane is what makes boggart a *service* rather than a program you
-- start and watch: a webhook can wake it, a second client can attach to a
-- running fleet, a phone can drive it through the same door the studio does,
-- and none of that is coding-specific -- it is the same door a business process
-- or an assistant task comes through.
local M = {}

local json = require "json"

M.server = nil
M.routes = {}
M.token = nil

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function ok(body, status)
  return status or 200, json.encode(body), { content_type = "application/json" }
end

local function err(status, message)
  return status, json.encode({ error = message }), { content_type = "application/json" }
end

-- Parse a urlencoded query string into a table. Small on purpose: a control
-- plane's query strings are `?n=20`, not a form post.
local function parse_query(q)
  local out = {}
  for pair in tostring(q or ""):gmatch("[^&]+") do
    local k, v = pair:match("^([^=]*)=?(.*)$")
    if k and k ~= "" then
      v = tostring(v):gsub("+", " "):gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
      end)
      out[k] = v
    end
  end
  return out
end
M.parse_query = parse_query

local function body_table(req)
  if not req.body or req.body == "" then return {} end
  local okj, t = pcall(json.decode, req.body)
  return (okj and type(t) == "table") and t or {}
end

-- ---------------------------------------------------------------------------
-- routes
-- ---------------------------------------------------------------------------
--
-- route(method, pattern, fn). The pattern is a Lua pattern anchored at both
-- ends, so captures work: "/agents/([%w_-]+)/cancel".
function M.route(method, pattern, fn, desc)
  M.routes[#M.routes + 1] =
    { method = method:upper(), pattern = "^" .. pattern .. "$", fn = fn, desc = desc }
  return M
end

local function dispatch(req)
  for _, r in ipairs(M.routes) do
    if r.method == req.method then
      local caps = { req.path:match(r.pattern) }
      if caps[1] ~= nil then
        if caps[1] == req.path then caps = {} end
        return r.fn(req, table.unpack(caps))
      end
    end
  end
  return err(404, "no route for " .. req.method .. " " .. req.path)
end

-- ---- introspection --------------------------------------------------------

M.route("GET", "/health", function()
  return ok({
    ok = true,
    version = boggart.version,
    mode = bog.mode,
    model = bog.cfg and bog.cfg.model,
    session = bog.session and bog.session.id,
    agents = bog.sched and bog.sched.actors and #(bog.sched.actors or {}) or 0,
    clients = M.server and M.server:clients() or 0,
  })
end, "liveness, version, current model and fleet size")

-- Every route, from the table itself: a control plane that cannot describe
-- itself is one you have to read the source of.
M.route("GET", "/routes", function()
  local out = {}
  for _, r in ipairs(M.routes) do
    out[#out + 1] = { method = r.method, path = r.pattern:sub(2, -2), desc = r.desc }
  end
  return ok({ routes = out })
end, "this list")

M.route("GET", "/tools", function()
  local names = {}
  for name, def in pairs(bog.tools.registry or {}) do
    names[#names + 1] = { name = name, description = def.description }
  end
  table.sort(names, function(a, b) return a.name < b.name end)
  return ok({ tools = names })
end, "the live tool registry")

M.route("GET", "/sessions", function(req)
  local q = parse_query(req.query)
  local limit = tonumber(q.limit) or 20
  local list = (bog.store and bog.store.sessions and bog.store.sessions(limit)) or {}
  return ok({ sessions = list })
end, "recent sessions")

-- ---- permissions: read and set the policy over the wire -------------------

M.route("GET", "/permissions", function()
  local perm = require "perm"
  local st = perm.state()
  return ok({ mode = st.mode, tool_policy = st.tool_policy or {},
              rules = st.rules or perm.rules or {},
              modes = perm.MODES })
end, "the current permission mode and rules")

M.route("POST", "/permissions", function(req)
  local perm = require "perm"
  local body = body_table(req)
  local st = perm.state()
  if body.mode then perm.set_mode(body.mode) end
  if type(body.rules) == "table" then st.rules = body.rules end
  if type(body.tool_policy) == "table" then st.tool_policy = body.tool_policy end
  return ok({ mode = st.mode, rules = st.rules or {} })
end, "set the mode and/or the rule table")

-- ---- models ---------------------------------------------------------------

M.route("GET", "/models", function()
  local route = require "route"
  local catalog = require "catalog"
  local cur = route.current()
  local providers = {}
  for _, p in ipairs(catalog.providers()) do
    providers[#providers + 1] = {
      name = p.name, label = p.label, url = p.url, wire = p.wire, auth = p.auth,
      -- whether a key exists, never the key: the one thing a client needs to
      -- know to say "that provider is usable"
      keyed = auth.has_key and auth.has_key(p.key_slot or p.name) or false,
    }
  end
  local models = {}
  for _, m in ipairs(catalog.models{}) do
    models[#models + 1] = { id = m.id, provider = m.provider, label = m.label,
                            context = m.context, tools = m.tools,
                            vision = m.vision, effort = m.effort }
  end
  return ok({
    current = { model = cur.model, url = cur.url, wire = cur.wire },
    utility = (function() local u = route.utility(); return { model = u.model, name = u.name } end)(),
    roles = catalog.roles(),
    providers = providers,
    models = models,
    presets = route.list(),
  })
end, "the catalog: current destination, roles, providers (keyed or not), models")

M.route("POST", "/models/refresh", function(req)
  local body = body_table(req)
  local catalog = require "catalog"
  local n, why = catalog.refresh(body.provider or "openrouter")
  if not n then return err(400, tostring(why)) end
  return ok({ refreshed = body.provider or "openrouter", models = n.models })
end, "pull a provider's published catalog")

M.route("POST", "/models/role", function(req)
  local body = body_table(req)
  if type(body.name) ~= "string" or body.name == "" then
    return err(400, "a role needs a `name`")
  end
  local bound, why = require("catalog").bind_role(body.name, body.spec or body.model)
  if not bound then return err(400, tostring(why)) end
  return ok({ role = body.name, spec = bound })
end, "bind a role to a model (or an ordered fallback list)")

-- ---- the fleet ------------------------------------------------------------

M.route("GET", "/agents", function()
  local out = {}
  for id, a in pairs((bog.sched and bog.sched.actors) or {}) do
    out[#out + 1] = {
      id = id,
      name = a.name or a.spec,
      state = a.state,
      skills = a.skills,
      turns = a.turns,
    }
  end
  return ok({ agents = out })
end, "the live fleet roster")

M.route("POST", "/cancel", function()
  if bog.sched and bog.sched.cancel_all then pcall(bog.sched.cancel_all) end
  bog.cancel = true
  return ok({ cancelled = true })
end, "cancel the running turn / fleet")

-- ---- work -----------------------------------------------------------------
--
-- A prompt over the wire is the same turn the REPL runs. It is queued onto the
-- bus rather than run inline: the handler is called from a uv callback, and a
-- model turn takes minutes -- blocking the loop inside it would stall the very
-- event stream the caller is watching.
M.route("POST", "/prompt", function(req)
  local body = body_table(req)
  local text = body.text or body.prompt
  if type(text) ~= "string" or text == "" then
    return err(400, "a prompt needs a `text` field")
  end
  local id = tostring(os.time()) .. "-" .. tostring(math.random(1e6))
  bog.events.emit("serve:prompt", { id = id, text = text, source = body.source or "http" })
  return ok({ accepted = true, id = id })
end, "queue a prompt as a turn (async; watch /events for the result)")

-- ---- webhooks: the inbound trigger ----------------------------------------
--
-- The autonomy story starts here. `POST /hooks/<name>` turns an outside event
-- (a push, an issue, a chat message, a cron service, a home-automation button)
-- into an ordinary boggart event, which `on_event` handlers and the automation
-- table can act on. Coding agents call this a webhook; a business process calls
-- it the start of a flow. Same door.
M.route("POST", "/hooks/([%w_%-%.]+)", function(req, name)
  local body = body_table(req)
  bog.events.emit("hook:" .. name, { name = name, body = body, raw = req.body,
                                     remote = req.remote })
  return ok({ delivered = "hook:" .. name })
end, "deliver an external event as hook:<name>")

-- ---- triggers: schedules and event bindings -------------------------------
--
-- The autonomy surface. A trigger names an occasion ("every 300s", "09:00",
-- "hook:push") and what to do about it; lua/triggers.lua owns the table and the
-- single uv timer that drives it.

M.route("GET", "/triggers", function()
  return ok({ triggers = require("triggers").status() })
end, "scheduled and event-bound triggers")

M.route("POST", "/triggers", function(req)
  local body = body_table(req)
  if type(body.name) ~= "string" or body.name == "" then
    return err(400, "a trigger needs a `name`")
  end
  if type(body.when) ~= "table" then
    return err(400, "a trigger needs a `when`: {every=n} | {at=\"09:00\"} | {on=\"hook:x\"}")
  end
  local T = require "triggers"
  local t = T.add(body.name, body.when, body.run, { enabled = body.enabled ~= false })
  return ok({ trigger = { name = t.name, when = t.when, enabled = t.enabled,
                          next_at = t.next_at } }, 201)
end, "create or replace a trigger")

M.route("POST", "/triggers/([%w_%-%.]+)/fire", function(req, name)
  local T = require "triggers"
  if not T.list[name] then return err(404, "no trigger called " .. name) end
  T.fire(name, { manual = true })
  return ok({ fired = name })
end, "fire a trigger now, by hand")

M.route("DELETE", "/triggers/([%w_%-%.]+)", function(req, name)
  local T = require "triggers"
  if not T.remove(name) then return err(404, "no trigger called " .. name) end
  return ok({ removed = name })
end, "delete a trigger")

-- ---- the event stream -----------------------------------------------------

M.route("GET", "/events", function()
  return "stream"
end, "server-sent events: everything on the bus, live")

-- ---------------------------------------------------------------------------
-- the bridge: bus/events -> SSE
-- ---------------------------------------------------------------------------
--
-- One subscription, forwarded to every attached client. Registered once and
-- kept for the life of the server so a reconnecting client does not multiply
-- handlers.
local bridge_handle = nil

local function install_bridge()
  if bridge_handle then return end
  bridge_handle = bog.events.on("*", function(name, data)
    if not M.server then return end
    local okj, payload = pcall(json.encode, {
      event = name,
      at = os.time(),
      data = (type(data) == "table") and data or { value = tostring(data) },
    })
    if okj then pcall(function() M.server:broadcast(name, payload) end) end
  end, { desc = "serve: mirror events to SSE clients", source = "serve.lua" })
end

local function remove_bridge()
  if bridge_handle then bog.events.off(bridge_handle); bridge_handle = nil end
end

-- ---------------------------------------------------------------------------
-- lifecycle
-- ---------------------------------------------------------------------------

-- start{ host=, port=, token= } -> server, url
-- A token is generated unless one is supplied AND the bind is loopback; asking
-- for any other host without a token is refused in C, which is the point.
function M.start(opts)
  opts = opts or {}
  if M.server then return M.server end
  local host = opts.host or os.getenv("BOGGART_SERVE_HOST") or "127.0.0.1"
  local port = tonumber(opts.port or os.getenv("BOGGART_SERVE_PORT")) or 0
  local token = opts.token or os.getenv("BOGGART_SERVE_TOKEN")
  if token == nil and host ~= "127.0.0.1" and host ~= "::1" and host ~= "localhost" then
    token = serve.token(24)   -- C: real entropy, not math.random
  end

  local srv, why = serve.listen{
    host = host, port = port, token = token,
    handler = function(req)
      local okd, a, b, c = pcall(dispatch, req)
      if not okd then
        return 500, json.encode({ error = tostring(a) }),
               { content_type = "application/json" }
      end
      return a, b, c
    end,
  }
  if not srv then return nil, why end

  M.server, M.token = srv, token
  install_bridge()
  local url = string.format("http://%s:%d", host, srv:port())
  bog.events.emit("serve:started", { url = url, token = token })
  return srv, url
end

function M.stop()
  if not M.server then return false end
  remove_bridge()
  M.server:stop()
  M.server, M.token = nil, nil
  bog.events.emit("serve:stopped", {})
  return true
end

function M.url()
  if not M.server then return nil end
  return string.format("http://127.0.0.1:%d", M.server:port())
end

return M
