-- welcomeview.lua -- the first thing a new install shows.
--
-- Someone downloads one file and runs it. Until now what they got was an empty
-- conversation and a grey line saying there were no credentials, which is a
-- diagnosis rather than an onboarding: it names a problem and offers nothing to
-- press. Everything needed to fix it existed, behind command names you can only
-- learn from documentation you have not read yet.
--
-- So this screen has one job: get from "I have a binary" to "I have sent a
-- message". It says what boggart is, offers the two ways to reach a model as
-- buttons rather than commands, tests the connection and says in plain words
-- whether it worked, says where the files live, and then gets out of the way.
--
-- Two things it deliberately does not do:
--
--   * It does not invent a second HTTP path to test with. The test is a real
--     turn through bog.api.run_on, driven the way agentview.lua drives one, so
--     the thing it proves is the thing the agent will do next. api.lua already
--     classifies auth, endpoint and model failures; a private probe would be a
--     second opinion, and the two would eventually disagree.
--
--   * It does not display an API key. Credentials live in C (src/lauth.c) and
--     are write-only from Lua: this screen can set one and can ask for a mask,
--     and that is all it will ever be able to do.
local core = require "core"
local common = require "core.common"
local style = require "core.style"
local ui = require "core.ui"
local View = require "core.view"
local widgets = require "core.widgets"
local diagram = require "core.diagram"

local WelcomeView = View:extend()

-- What DwarfStar (ds4-server) serves on, and the address in every local-model
-- example we ship. A suggestion until something uses it -- see apply().
local DEFAULT_LOCAL = "http://127.0.0.1:8000"

-- Offered as buttons on the Anthropic route. A local endpoint gets its list
-- from the server instead (fetch_models), which is better than a guess.
local ANTHROPIC_MODELS = { "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5-20251001" }

local NOT_SET = "not set"

-- The connection test, as small as a turn can be: no tools, no boggart system
-- prompt (which is thousands of tokens of tool documentation), one word back.
local TEST_TEXT = "Reply with the single word OK."
local TEST_SYSTEM = "You are answering a connection test. Reply with one word."

-- api.lua's error kinds, said the way you would say them to someone who has not
-- read any documentation. The kind is the classification; this is only the
-- wording. api.lua's own .message goes underneath, because it carries the
-- status code and the server's explanation, and its .hint does not, because the
-- hint is written for the CLI ("re-run `ant auth login`", "curl ...") and this
-- screen has the buttons the hint is describing.
local VERDICT = {
  auth        = "That key was not accepted.",
  endpoint    = "Nothing answered at that address.",
  model       = "The server answered, but not for that model.",
  bad_request = "The server understood us and refused the request.",
  rate_limit  = "The credentials work -- the account is rate limited right now.",
  overloaded  = "The service is busy. Not your configuration; try again.",
  server      = "The server failed. Not your configuration.",
  stream      = "The reply started and then broke off part-way.",
}

local INTRO = "A coding agent that reads your files, edits them, runs commands, "
  .. "and rewrites its own source. This window is the whole application: you "
  .. "work by talking to it, and it does the work on this machine."

-- Prose wraps; labels elide. The difference matters at 420 pixels, where a
-- fixed three-line paragraph would otherwise run past the column. The view is
-- clipped to its rect (Node:draw), but hits still have to land inside it -- a
-- button drawn past the edge is a button you cannot press.
--
-- Counting characters is enough here and nowhere else in this app: every string
-- this wraps is ASCII we wrote, in the monospace font. Anything from a server
-- (a model name, an error) is elided instead, because that can be any script
-- and would need agentview.lua's cell-width wrapper.
local function wrap(text, cols)
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    if line == "" then line = word
    elseif #line + 1 + #word <= cols then line = line .. " " .. word
    else lines[#lines + 1] = line; line = word end
  end
  if line ~= "" then lines[#lines + 1] = line end
  return lines
end

-- Text that does not fit is elided rather than drawn past its box: a data
-- directory under a temporary HOME is long, and an endpoint or a model name is
-- whatever a server or a person supplied.
--
-- The bisection walks CHARACTERS. Over bytes it lands part-way through any
-- multi-byte character -- and this file's own comment two paragraphs up says
-- that anything from a server "can be any script", which is exactly the input
-- that breaks it: both the measurement and the drawn result are then made from
-- a string the decoder cannot read.
local function elide(font, text, width)
  if font:get_width(text) <= width then return text end
  local n = utf8.len(text)
  local function upto(chars)
    if n then return text:sub(1, (utf8.offset(text, chars + 1) or (#text + 1)) - 1) end
    local i = math.min(chars, #text)
    while i > 0 and common.is_utf8_cont(text:sub(i + 1, i + 1)) do i = i - 1 end
    return text:sub(1, i)
  end
  local lo, hi = 0, n or #text
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if font:get_width(upto(mid) .. "...") <= width then lo = mid else hi = mid - 1 end
  end
  return upto(lo) .. "..."
end

-- What C is willing to say about the key: a mask, and where the value came
-- from. "(unset)" is a sentinel for the caller rather than a phrase to put in
-- front of a person, so it becomes nil.
local function key_summary()
  local ok, masked, source = pcall(auth.masked)
  if not ok or not masked or masked == "" or masked == "(unset)" then return nil end
  return masked, source
end

local function configured()
  local ok, has = pcall(function() return auth.has_key() or auth.base_url() end)
  return ok and has and true or false
end

-- ---------------------------------------------------------------------------
-- First run
-- ---------------------------------------------------------------------------

-- Where boggart keeps its files. Asked at runtime, never spelled out: the
-- directory is not ~/.boggart on every platform, and the policy that decides it
-- is C's (src/bogpaths.h -- sys.paths() is how Lua asks). bog.userdir is the
-- older spelling and still correct on macOS; it is the fallback so this screen
-- works either side of that work landing.
local function datadir()
  local ok, p = pcall(sys.paths)
  if ok and type(p) == "table" and p.data then return p.data end
  return (bog and bog.userdir) or "?"
end

local SEEN_KEY = "studio.welcome.seen"

-- Deliberately the only place that decides this.
--
-- Real first-run detection belongs to the lifecycle work in lua/boot.lua and
-- lua/store.lua, which is adding it; when it lands, the body of this function
-- becomes `return bog.first_run` and nothing else in this file changes. Until
-- then: a fresh install has no credentials and has never dismissed this screen.
--
-- The marker is in the kv table rather than a file of our own, so wiping the
-- data directory is enough to get the first run back -- which is exactly what
-- someone testing a fresh install will try.
function WelcomeView.is_first_run()
  if bog and type(bog.first_run) == "boolean" then return bog.first_run end
  local ok, seen = pcall(function() return bog.store.kv_get(SEEN_KEY) end)
  if ok and seen then return false end
  return not configured()
end

function WelcomeView.mark_seen()
  pcall(function() bog.store.kv_set(SEEN_KEY, tostring(os.time())) end)
end

-- ---------------------------------------------------------------------------
-- Opening
-- ---------------------------------------------------------------------------

-- The first-run surface. On the rail layout it replaces the agent stage
-- rather than sitting as a sibling tab; the legacy attach still adds a tab.
function WelcomeView.open()
  local studio = core.studio
  if studio and not studio.legacy and studio.switch_workspace then
    studio.switch_workspace("welcome")
    return WelcomeView.instance
  end
  local node = core.root_view:get_primary_node()
  local existing = WelcomeView.instance
  if existing and node:get_node_for_view(existing) then
    node:set_active_view(existing)
    core.set_active_view(existing)
    return existing
  end
  local v = WelcomeView()
  WelcomeView.instance = v
  node:add_view(v)
  core.set_active_view(v)
  return v
end

function WelcomeView.maybe_open()
  if not WelcomeView.is_first_run() then return nil end
  -- Rail: the conversation leaf shows this as the empty state, not a second
  -- tab that hides the agent. Legacy still opens a sibling tab.
  return WelcomeView.open()
end

-- ---------------------------------------------------------------------------

function WelcomeView:new()
  WelcomeView.super.new(self)
  self.scrollable = true
  self.focus = nil          -- index of the field being edited
  self.buffer = ""
  self.hits = {}
  self.notice = nil         -- what the last field commit did
  self.result = nil         -- { good, headline, detail }
  self.job = nil            -- the test turn, or the model fetch
  self.status = nil         -- what the job is doing, in words
  self.models = nil         -- what a local endpoint said it serves
  self.gen = diagram.generator(7)

  -- Reopened from the palette rather than shown on a fresh install: start on
  -- whichever route the existing configuration is already on.
  local ok, base = pcall(auth.base_url)
  self.route = (ok and base and "local") or (configured() and "api") or nil

  -- A stored model counts as chosen. The one the session starts with does not:
  -- it is the harness default, and a local endpoint's own list should be
  -- allowed to replace it (see fetch_models).
  local okm, stored = pcall(auth.model)
  self.model_chosen = (okm and stored and stored ~= "") and true or false
  self.model = (self.model_chosen and stored)
    or (bog and bog.session and bog.session.model) or nil

  -- Which shape the local endpoint speaks. It matters because the two wires go
  -- to different paths -- /v1/messages for anthropic, /v1/chat/completions for
  -- openai -- and a local OpenAI server pointed at with the wrong wire fails on
  -- a request it never saw the right form of. A stored choice is respected on
  -- reopen; a fresh local route defaults to "openai" at apply(), because the
  -- /v1/models catalogue this screen fetches IS the OpenAI route and answering
  -- it strongly implies the rest of that shape.
  local okw, wire = pcall(auth.wire)
  self.wire = (okw and wire) or nil
end

function WelcomeView:get_name() return "Welcome" end

function WelcomeView:get_scrollable_size()
  return self.content_height or math.huge
end

-- ---------------------------------------------------------------------------
-- Fields
-- ---------------------------------------------------------------------------
--
-- Described rather than drawn, so the layout and the behaviour cannot disagree
-- about what exists. Same mechanism as settingsview.lua -- click to focus, text
-- into a buffer, enter commits, esc cancels, tab moves on -- because the app
-- should have one way to type into a field.

function WelcomeView:fields()
  local out = {}
  if self.route == "api" then
    local masked, source = key_summary()
    out[#out + 1] = {
      key = "api_key",
      label = "API key",
      value = masked or NOT_SET,
      -- The environment case is called out rather than summarised, because it
      -- is the one where storing a key here changes nothing: C prefers
      -- ANTHROPIC_API_KEY over the file, so the form would be accepting a value
      -- the process then ignores.
      hint = (source == "environment"
          and "ANTHROPIC_API_KEY is set here, and the environment wins over anything stored")
        or "paste sk-ant-... and press enter -- it is stored, never shown again",
      secret = true,
      set = function(v)
        auth.set("api_key", v)
        if bog.api.forget_auth then bog.api.forget_auth() end
        self.result = nil
        local m, src = key_summary()
        if src == "environment" then
          return nil, "stored, but ANTHROPIC_API_KEY is still the key being sent"
        end
        return "key stored (" .. (m or "?") .. ")"
      end,
    }
  elseif self.route == "local" then
    out[#out + 1] = {
      key = "base_url",
      label = "Endpoint",
      value = auth.base_url() or DEFAULT_LOCAL,
      -- Dim while it is only a suggestion, like every other unset field, so
      -- "already configured" and "here is a sensible default" do not look the
      -- same. Testing or starting adopts it; see apply().
      dim = (auth.base_url() == nil),
      hint = "a server speaking /v1/messages -- llama.cpp, vLLM, ds4-server",
      set = function(v)
        auth.set("base_url", v)
        if bog.api.forget_auth then bog.api.forget_auth() end
        self.result, self.models = nil, nil
        self:fetch_models()
        return "endpoint: " .. bog.api.endpoint()
      end,
    }
  end
  if self.route then
    out[#out + 1] = {
      key = "model",
      label = "Model",
      value = self.model or NOT_SET,
      dim = (self.model == nil),
      hint = self.route == "local"
        and "whatever your server serves -- the buttons below ask it"
        or "the buttons below are the ones this build knows about",
      set = function(v)
        self.model, self.model_chosen = v, true
        self.result = nil
        return "model: " .. v
      end,
    }
  end
  return out
end

function WelcomeView:report(ok, msg, why)
  if not ok then self.notice = { text = tostring(msg), bad = true }
  elseif msg == nil then self.notice = { text = why or "not accepted", bad = true }
  else self.notice = { text = msg } end
  core.redraw = true
end

function WelcomeView:commit()
  local f = self:fields()[self.focus or 0]
  if not f then return end
  -- Parenthesised: gsub returns the count as well, and the bare call was
  -- handing a second argument to everything downstream.
  local value = (self.buffer:gsub("^%s+", ""):gsub("%s+$", ""))
  self.focus, self.buffer = nil, ""
  if value == "" then
    -- Said out loud. Pressing enter on an empty field did nothing and reported
    -- nothing, which on the screen a new install opens on is the difference
    -- between "I have not typed anything" and "this application is broken".
    self.notice = { text = "nothing entered -- the " .. f.label:lower()
      .. " is unchanged", bad = true }
    core.redraw = true
    return
  end
  self:report(pcall(f.set, value))
end

function WelcomeView:edit(i)
  local f = self:fields()[i]
  if not f then return end
  self.focus = i
  -- A secret starts empty because there is nothing to start from: C will not
  -- give a key back. Everything else starts from what is on screen -- including
  -- the suggested endpoint -- so correcting a port number is a backspace rather
  -- than a retype.
  self.buffer = (not f.secret and f.value ~= NOT_SET) and f.value or ""
  core.set_active_view(self)
  core.redraw = true
end

function WelcomeView:choose(route)
  self.route = route
  self.focus, self.buffer = nil, ""
  self.result, self.notice = nil, nil
  if route == "local" then
    -- Ask the server what it has, immediately: a model name is the one thing
    -- on this screen nobody can guess, and the endpoint is the only party that
    -- knows. Failure is silent here -- the Test button is where a connection
    -- gets a verdict, and two failure messages for one unreachable server is
    -- one too many.
    self:fetch_models()
  end
  core.redraw = true
end

-- ---------------------------------------------------------------------------
-- Jobs: the test turn, and asking an endpoint what it serves
-- ---------------------------------------------------------------------------
--
-- Both run as a coroutine driven from update(), the way agentview.lua drives a
-- turn: yield "io" to have the HTTP pumped, "proc" for a libuv timer (api.lua's
-- backoff arms one). Neither may block the frame -- an unreachable endpoint
-- takes as long as its timeout to say so, and a window frozen for that long is
-- indistinguishable from a crash.

-- The suggested endpoint becomes the real one at the moment something uses it.
-- Testing and starting both count, and both come through here, so the value the
-- test proves is the value the next request will go to.
function WelcomeView:apply()
  if self.route == "local" and not auth.base_url() then
    auth.set("base_url", DEFAULT_LOCAL)
  end
  -- The wire is written down with everything else, so the value the test proves
  -- is the value the next request goes out under. The local route defaults to
  -- "openai" (see :new()); the Anthropic route says "anthropic" out loud rather
  -- than leaving a wire left over from a previous local attempt, so switching
  -- back is clean.
  if self.route == "local" then
    auth.set("wire", self.wire or "openai")
  elseif self.route == "api" then
    auth.set("wire", "anthropic")
  end
  if self.model and self.model ~= "" then
    auth.set("model", self.model)
    if bog.session then bog.session.model = self.model end
  end
  if bog.api.forget_auth then bog.api.forget_auth() end
end

function WelcomeView:busy() return self.job ~= nil end

function WelcomeView:cancel()
  self.job, self.status = nil, nil
  self.result = { headline = "Stopped before it answered." }
  core.redraw = true
end

function WelcomeView:test()
  if self:busy() then return end
  if not (bog and bog.api) then
    self.result = { headline = "This build has no agent harness in it." }
    return
  end
  self:apply()
  if not configured() then
    self.result = { headline = "Nothing to test yet.",
      detail = "Add a key, or point at a local endpoint." }
    return
  end

  local model = (bog.session and bog.session.model) or self.model
  local endpoint = bog.api.endpoint()
  self.result = nil
  self.status = "asking " .. tostring(model) .. " at " .. endpoint .. " ..."

  -- A session of its own, never saved: a connection test should not turn up in
  -- the conversation the person is about to start.
  local sess = { model = model, messages = {}, max_tokens = 64 }
  local reply = {}
  local t0 = system.get_time()

  self.job_kind = "test"
  self.job = coroutine.create(function()
    local ok, err = pcall(bog.api.run_on, sess, TEST_TEXT,
      function(chunk) reply[#reply + 1] = chunk end,
      {
        async = true,
        system = function() return TEST_SYSTEM end,
        tools = function() return {} end,
      })
    local secs = system.get_time() - t0
    if ok then
      local said = table.concat(reply):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      self.result = {
        good = true,
        headline = string.format("It works. %s replied in %.1fs.", model, secs),
        detail = said ~= "" and ("It said: " .. said:sub(1, 120)) or
          "It replied with no text, which still means the connection is good.",
      }
      -- Configured and proven. Whatever happens next -- a crash, a close, a
      -- window they never came back to -- this screen has done its job and
      -- should not greet them again.
      WelcomeView.mark_seen()
    else
      local kind = (type(err) == "table" and err.kind) or nil
      self.result = {
        headline = VERDICT[kind] or "That did not work.",
        detail = (type(err) == "table" and err.message) or tostring(err),
      }
    end
    self.status = nil
    core.redraw = true
  end)
end

-- What the endpoint says it serves. This is the one place that talks HTTP
-- directly rather than through the turn loop, because there is no turn that
-- asks this question: /v1/models is a catalogue, not a conversation. It stays
-- honest by having no opinion about failure -- if the server is unreachable,
-- Test is what says so.
function WelcomeView:fetch_models()
  if self:busy() then return end
  local base = (auth.base_url() or DEFAULT_LOCAL):gsub("/+$", "")
  self.status = "asking " .. base .. " what it serves ..."
  self.job_kind = "models"
  self.job = coroutine.create(function()
    local found = {}
    -- `req` lives in the outer scope so it is closed even when the body throws
    -- (a decode error, say). A raw HTTP handle left open leaks a uv handle and
    -- a socket for the life of the window.
    local req
    local ok = pcall(function()
      req = http.begin { url = base .. "/v1/models", method = "GET", timeout = 10 }
      local raw = {}
      while true do
        coroutine.yield("io")
        local chunk = req:take()
        if chunk ~= "" then raw[#raw + 1] = chunk end
        local st = req:status()
        if st ~= "running" then break end
      end
      local body = bog.json.decode(table.concat(raw))
      for _, m in ipairs((type(body) == "table" and body.data) or {}) do
        if type(m) == "table" and type(m.id) == "string" then found[#found + 1] = m.id end
      end
    end)
    if req then pcall(function() req:close() end) end
    if ok and #found > 0 then
      self.models = found
      -- The list from the server outranks anything nobody chose. On a fresh
      -- install the model is "claude-opus-5" -- the harness default, and a name
      -- a local server has never heard of -- so leaving it alone means the
      -- first test fails on a model name the person never typed. An explicit
      -- choice (a click, or a name typed into the field) is never overruled,
      -- even if the server does not list it: some servers serve models they do
      -- not advertise.
      local listed = false
      for _, name in ipairs(found) do listed = listed or (name == self.model) end
      if not self.model_chosen and not listed then self.model = found[1] end
    end
    self.status = nil
    core.redraw = true
  end)
end

function WelcomeView:tick()
  if not self.job then return end
  if coroutine.status(self.job) == "dead" then self.job = nil; return end
  local ok, kind = coroutine.resume(self.job)
  if not ok then
    -- A bug in this screen, not a verdict on the connection, and it says so:
    -- "the endpoint is unreachable" would be a lie about someone else's server.
    self.result = { headline = "boggart-studio itself failed while "
      .. (self.job_kind == "test" and "testing" or "asking for the model list")
      .. ".", detail = tostring(kind) }
    self.job, self.status = nil, nil
    return
  end
  if kind == "io" then
    pcall(http.pump, 0)
  elseif kind == "proc" then
    local okuv, uv = pcall(require, "uv")
    if okuv then pcall(uv.run, "nowait") end
  end
end

function WelcomeView:update()
  self:tick()
  if self.job then core.redraw = true end
  WelcomeView.super.update(self)
end

-- Done here: stop greeting them, and leave them in the conversation.
--
-- `commit` separates the two ways out. "Start chatting" adopts what is on
-- screen; "Not now" writes nothing at all -- a suggested endpoint that someone
-- declined must not end up in their configuration because they looked at it.
-- Both stop the screen coming back, because both are an answer.
function WelcomeView:finish(commit)
  if commit then self:apply() end
  WelcomeView.mark_seen()
  local node = core.root_view.root_node:get_node_for_view(self)
  if node then
    node:set_active_view(self)
    node:close_active_view(core.root_view.root_node)
  end
  if core.studio then
    local v = core.studio.open_agent()
    if v and configured() then
      -- The panel says "No credentials" in its opening lines, decided once when
      -- it was constructed -- which was before any of this. Leaving that on
      -- screen underneath "ready" would be the application contradicting
      -- itself. Matching on the text is duplicated knowledge and it is the
      -- weak part of this: the durable fix is for agentview.lua to derive that
      -- hint when it draws rather than push it once at construction.
      for i = #v.entries, 1, -1 do
        local e = v.entries[i]
        if e.role == "system" and (e.text:find("^No credentials")
            or e.text:find("^or 'agent: set endpoint'")) then
          table.remove(v.entries, i)
        end
      end
      v:push("system", "ready -- model " .. tostring((bog.session or {}).model)
        .. " at " .. bog.api.endpoint())
    end
    core.set_active_view(v)
  end
end

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

function WelcomeView:on_text_input(text)
  if self.focus then self.buffer = self.buffer .. text; core.redraw = true end
end

function WelcomeView:on_key_pressed(key)
  if not self.focus then return false end
  if key == "escape" then
    self.focus, self.buffer = nil, ""
  elseif key == "return" then
    self:commit()
  elseif key == "backspace" then
    -- One character, not one byte: a pasted endpoint can contain anything, and
    -- half a codepoint is bytes the renderer cannot decode.
    local n = #self.buffer
    while n > 0 and self.buffer:byte(n) >= 0x80 and self.buffer:byte(n) < 0xC0 do n = n - 1 end
    self.buffer = self.buffer:sub(1, math.max(0, n - 1))
  elseif key == "tab" then
    local n = #self:fields()
    if n == 0 then self.focus, self.buffer = nil, "" ; return true end
    local next_i = (self.focus % n) + 1
    self:commit()
    self:edit(next_i)
  else
    return false
  end
  core.redraw = true
  return true
end

function WelcomeView:on_mouse_moved(x, y, dx, dy)
  WelcomeView.super.on_mouse_moved(self, x, y, dx, dy)
  self.mouse = { x = x, y = y }
  local item = widgets.hit(self.hits, x, y)
  local was = self.hover
  self.hover = item and item.id or nil
  if was ~= self.hover then core.redraw = true end
  self.cursor = item and "arrow" or "ibeam"
end

function WelcomeView:on_mouse_pressed(button, x, y, clicks)
  if WelcomeView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  core.set_active_view(self)
  local item = widgets.hit(self.hits, x, y)
  if item and item.action then item.action() end
  return true
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

local FIELD = ui.styles.field
local FIELD_FOCUSED = ui.styles.field_focused

function WelcomeView:draw()
  self:draw_background(style.background)
  local font = style.code_font
  local m = ui.metrics(font)
  local lh, pad, vpad, bh = m.line_height, m.pad_x, m.pad_y, m.button
  self.hits = {}
  local function add(hit, id, action)
    hit.item = { id = id, action = action }
    self.hits[#self.hits + 1] = hit
  end
  -- A row of buttons, hit-tested, with the ids widgets.row does not assign.
  -- Wrapping rather than clipping, and returning the y it ended on: widgets.row
  -- drops a button that would cross the limit, which is right for a toolbar and
  -- wrong for a list of model names -- a model you cannot see is a model you
  -- cannot pick, and the names come from a server, so their width is not ours
  -- to assume.
  local function row(items, x0, y0, limit)
    local gap = style.padding.x * widgets.GAP
    local cx, cy = x0, y0
    for _, it in ipairs(items) do
      local bw = widgets.width(font, it.label)
      if cx > x0 and cx + bw > limit then cx, cy = x0, cy + bh + gap end
      local hovered = self.mouse and widgets.inside(
        { x = cx, y = cy, w = bw, h = bh }, self.mouse.x, self.mouse.y)
      add(widgets.button(font, it.label, cx, cy,
        { w = bw, active = it.active, dim = it.dim, hover = hovered }),
        it.label, it.action)
      cx = cx + bw + gap
    end
    return cy + bh
  end

  local w = math.min(self.size.x - pad * 2, 78 * m.char_width)
  local x = self.position.x + math.max(pad, (self.size.x - w) / 2)
  local y = self.position.y + vpad * 2 - self.scroll.y
  local right = x + w
  local cols = math.max(16, math.floor(w / m.char_width))

  -- A paragraph, wrapped to the column.
  local function para(text, colour)
    for _, line in ipairs(wrap(text, cols)) do
      common.draw_text(font, colour, line, "left", x, y, w, lh)
      y = y + lh
    end
  end

  -- ---- what this is --------------------------------------------------------
  local title_font = style.big_font or font
  local th = title_font:get_height()
  common.draw_text(title_font, style.accent, "boggart", "left", x, y, w, th)
  -- A drawn underline rather than a ruled one: the only decoration on the
  -- screen, and it costs two strokes.
  diagram.line(self.gen, style.dim, 1.2, x, y + th - vpad / 2,
    x + title_font:get_width("boggart"), y + th - vpad / 2)
  y = y + th + vpad

  para(INTRO, style.text)
  y = y + vpad

  -- ---- the choice ----------------------------------------------------------
  para("To answer you, it needs a model. Two ways:", style.dim)
  y = y + vpad / 2
  y = row({
    { label = "Use an Anthropic API key", active = self.route == "api",
      action = function() self:choose("api") end },
    { label = "Point at a local model", active = self.route == "local",
      action = function() self:choose("local") end },
  }, x, y, right) + vpad

  if not self.route then
    para("Pick one. Nothing is sent anywhere until you do.", style.dim)
    y = y + vpad / 2
  end

  -- ---- the fields ----------------------------------------------------------
  local fields = self:fields()
  for i, f in ipairs(fields) do
    local editing = (self.focus == i)
    common.draw_text(font, style.text, f.label, "left", x, y, w, lh)
    y = y + lh

    local boxh = lh + vpad
    ui.box(editing and ui.derive(FIELD, FIELD_FOCUSED) or FIELD, x, y, w, boxh)

    local shown, colour
    if editing then
      shown = (f.secret and string.rep("*", utf8.len(self.buffer) or #self.buffer)
        or self.buffer) .. "|"
      colour = style.accent
    else
      shown = f.value
      colour = (f.dim or f.value == NOT_SET) and style.dim or style.accent
    end
    common.draw_text(font, colour, elide(font, shown, w - pad * 1.5), "left",
      x + pad / 2, y, w - pad, boxh)
    add({ x = x, y = y, w = w, h = boxh }, "field" .. i, function() self:edit(i) end)
    y = y + boxh + vpad / 2

    common.draw_text(font, style.dim, elide(font,
      editing and "enter to save, esc to cancel, tab for the next field" or f.hint, w),
      "left", x, y, w, lh)
    y = y + lh

    -- The endpoint's shape, as a two-way toggle: /v1/models answering is a
    -- strong hint but not proof (some anthropic-shaped servers proxy it), so the
    -- choice is offered rather than assumed, defaulting to OpenAI where the
    -- catalogue fetched. apply() is where it is written; see :new() for the
    -- default.
    if f.key == "base_url" then
      local wire = self.wire or "openai"
      y = y + vpad / 2
      y = row({
        { label = "OpenAI-shaped", active = (wire == "openai"),
          action = function() self.wire, self.result = "openai", nil end },
        { label = "Anthropic-shaped", active = (wire == "anthropic"),
          action = function() self.wire, self.result = "anthropic", nil end },
      }, x, y, right)
    end

    -- Models as buttons: from the endpoint itself where there is one, and from
    -- what this build knows about where there is not.
    if f.key == "model" then
      local choices = (self.route == "local" and self.models) or
        (self.route == "api" and ANTHROPIC_MODELS) or nil
      y = y + vpad / 2
      local items = {}
      for _, name in ipairs(choices or {}) do
        local pick = name
        items[#items + 1] = { label = name, active = (self.model == name),
          action = function()
            self.model, self.model_chosen, self.result = pick, true, nil
          end }
      end
      if self.route == "local" then
        items[#items + 1] = { label = self.models and "Ask again" or "What does it serve?",
          dim = true, action = function() self:fetch_models() end }
      end
      y = row(items, x, y, right)
    end
    y = y + vpad
  end

  -- A stored endpoint outranks the key: requests go there, with the key
  -- attached. Someone who has been round this screen once and come back to try
  -- an Anthropic key would otherwise watch it fail against their own server
  -- with nothing on screen even mentioning that a server is involved.
  local stray = (self.route == "api") and auth.base_url() or nil
  if stray then
    para("An endpoint is set, so the key would be sent there and not to "
      .. "Anthropic:", style.warn)
    common.draw_text(font, style.warn, elide(font, "  " .. stray, w),
      "left", x, y, w, lh)
    y = y + lh + vpad / 2
    y = row({ { label = "Clear the endpoint", action = function()
      auth.clear("base_url")
      if bog.api.forget_auth then bog.api.forget_auth() end
      self.result = nil
      self.notice = { text = "endpoint cleared -- using the Anthropic API" }
    end } }, x, y, right) + vpad
  end

  if self.notice then
    common.draw_text(font, self.notice.bad and style.error or style.good,
      elide(font, self.notice.text, w), "left", x, y, w, lh)
    y = y + lh + vpad / 2
  end

  -- ---- test, and go --------------------------------------------------------
  local actions = {}
  if self.route then
    if self:busy() then
      actions[#actions + 1] = { label = "Stop", action = function() self:cancel() end }
    else
      actions[#actions + 1] = { label = "Test connection",
        action = function() self:test() end }
    end
    actions[#actions + 1] = { label = "Start chatting",
      -- Filled in once the test has passed, so the screen points at the way
      -- out instead of leaving three buttons of equal weight.
      active = (self.result and self.result.good) or false,
      action = function() self:finish(true) end }
  end
  actions[#actions + 1] = { label = "Not now", dim = true,
    action = function() self:finish(false) end }
  y = row(actions, x, y, right) + vpad / 2

  if self.route then
    -- Said out loud because it is a side effect: testing writes the endpoint and
    -- the model down first. There is no dry-run credential in C, and a test that
    -- did not use the stored settings would be testing something else.
    para("Test saves these settings and sends one short message the same way "
      .. "the agent will.", style.dim)
    y = y + vpad / 2
  end

  -- ---- and what happened ---------------------------------------------------
  if self.status then
    common.draw_text(font, style.text, elide(font, self.status, w), "left", x, y, w, lh)
    y = y + lh
  end
  local r = self.result
  if r then
    common.draw_text(font, r.good and style.good or style.error,
      elide(font, r.headline, w), "left", x, y, w, lh)
    y = y + lh
    -- api.lua's own message, line by line: it is multi-line for some kinds and
    -- carries the status code and the server's words, which are the parts worth
    -- quoting to whoever is going to fix it.
    for line in ((r.detail or "") .. "\n"):gmatch("(.-)\n") do
      if line ~= "" then
        common.draw_text(font, style.dim, elide(font, line, w), "left", x, y, w, lh)
        y = y + lh
      end
    end
  end

  -- ---- where the files are -------------------------------------------------
  --
  -- Not a footnote out of politeness: this program writes to a directory on
  -- your machine, keeps your conversations there and can rewrite its own code,
  -- and you should be told that before you type into it rather than after.
  y = y + vpad * 1.5
  renderer.draw_rect(x, y, w, 1, style.divider)
  y = y + vpad
  local dir = datadir()
  local okp, keypath = pcall(auth.path)
  -- Relative to the directory named on the line above where it sits under it,
  -- which is the usual case; absolute otherwise, because a credential file
  -- somewhere else entirely is exactly when you want to be told where.
  local keyname = (okp and keypath) or "auth"
  if keyname:sub(1, #dir + 1) == dir .. "/" then keyname = keyname:sub(#dir + 2) end
  -- The path goes on its own line when the sentence will not hold it. A path is
  -- the one string here that must not be elided if it can be helped: half a
  -- directory name is no use to anyone.
  local intro_line = "boggart keeps its files in " .. dir
  local lines = { intro_line }
  if font:get_width(intro_line) > w then
    lines = { "boggart keeps its files in", "  " .. dir }
  end
  lines[#lines + 1] = string.format("  %-13s%s", "boggart.db",
    "conversations, memory, and the tools it writes for itself")
  lines[#lines + 1] = string.format("  %-13s%s", keyname,
    "the API key, mode 0600, never in the database")
  for _, line in ipairs(lines) do
    common.draw_text(font, style.dim, elide(font, line, w), "left", x, y, w, lh)
    y = y + lh
  end

  self.content_height = (y + self.scroll.y) - self.position.y + vpad * 2
  self:draw_scrollbar()
end

return WelcomeView
