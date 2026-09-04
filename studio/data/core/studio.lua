-- studio.lua -- LEGACY window composition (boggart-studio app layer over lite).
--
-- Adds the agent panel, the commands that drive it, and the configuration
-- surfaces (credentials, model, MCP servers, sessions). Loaded from
-- core/init.lua after the editor is up.
--
-- THIS FILE'S attach() IS THE LEGACY LAYOUT: everything is a tab in the
-- primary node, with SidebarView as the left rail. The default studio is the
-- shell (studio/data/shell): menu bar + AGENT/EDIT/FLEET workspaces. Set
-- BOGGART_STUDIO_LEGACY=1 to restore this composition. The engine -- AgentView,
-- swarm setup, commands, recipes -- is still required by the shell; only the
-- window chrome here is legacy.
--
-- Everything here is ordinary lite Lua and ordinary boggart Lua in one
-- interpreter, which is the point: the agent can edit this file and reload it,
-- so the application's own UI is inside the agent's reach.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local AgentView = require "core.agentview"
local SidebarView = require "core.sidebarview"
local SettingsView = require "core.settingsview"
local PanelView = require "core.panelview"
local LibraryView = require "core.libraryview"
local PickerView = require "core.pickerview"
local fonts = require "core.fonts"
local SwarmView = require "core.swarmview"
local uitools = require "core.uitools"
local menu = require "core.menu"

local studio = {}

-- ---------------------------------------------------------------------------
-- The panel
-- ---------------------------------------------------------------------------

-- Is the panel still on screen?
--
-- Asked of the node tree, not of the view: lite never sets view.node, so the
-- obvious-looking studio.view.node check was nil every time -- which silently
-- disabled the status indicator, cancel, approve and reject, and made every
-- "open panel" split a fresh panel instead of focusing the existing one.
function studio.agent_view()
  local v = studio.view
  if v and core.root_view.root_node:get_node_for_view(v) then return v end
  return nil
end

-- Shared startup that both attach paths run: fonts, drawing tools, the swarm
-- pump, resume the last session, and (on a first run) the welcome surface.
local function attach_common(view)
  core.try(uitools.register, studio)
  core.try(function()
    local problems = fonts.apply()
    for _, p2 in ipairs(problems or {}) do core.log("%s", p2) end
  end)
  core.try(studio.setup_swarm)
  core.try(function()
    if require("core.welcomeview").is_first_run() then return end
    if not (bog.resume_startup and bog.resume_startup()) then
      local recent = bog.store.sess_list(1)
      local id = recent and recent[1] and recent[1].id
      if id then bog.resume_session(id) end
    end
    if bog.session and bog.session.id then view:repaint(bog.session.messages) end
  end)
  core.try(function() require("core.welcomeview").maybe_open() end)
  studio.start_mcp()
  return view
end

-- MCP after the first present, once. core.init used to start the same load in
-- a second thread, so two llm-station children raced to bind ZMQ and one
-- abort()ed about two seconds after the window appeared -- Crash Reporter,
-- not a Lua error.txt.
function studio.start_mcp()
  if studio.mcp_started then return end
  studio.mcp_started = true
  if not (bog and bog.mode == "embedded") then return end
  bog._mcp_loading = true
  core.add_thread(function()
    coroutine.yield()
    if bog.mcphost then bog.try(bog.mcphost.load) end
    if bog.llmstation then bog.try(bog.llmstation.autostart) end
    bog._mcp_loading = false
  end)
end

-- The old "agent tab + Chat/Code sidebar" window. Kept behind
-- BOGGART_STUDIO_LEGACY=1 until the rail layout has enough miles.
function studio.attach_legacy()
  if studio.attached then return end
  studio.attached = true
  studio.legacy = true
  studio.workspace = "agent"

  local view = AgentView()
  studio.view = view
  core.root_view:get_primary_node():add_view(view)
  core.set_active_view(view)

  studio.sidebar = SidebarView()
  core.root_view:get_primary_node():split("left", studio.sidebar, true)
  core.set_active_view(view)
  return attach_common(view)
end

-- Kept for the few callers that still guard on it (swarmview/welcomeview);
-- the shell owns workspace switching, so route there. There is no rail layout
-- anymore and legacy has no workspaces, so off the shell this is a no-op.
function studio.switch_workspace(name)
  local sh = package.loaded["shell"]
  if sh and sh.attached and sh.switch then sh.switch(name) end
end

-- ---------------------------------------------------------------------------
-- Swarm: the chat agent IS the coordinator
-- ---------------------------------------------------------------------------
--
-- boggart's swarm has always been headless (`boggart swarm`): a coordinator
-- actor spawns sub-agents, they message over the C bus, and the scheduler in
-- lua/sched.lua drives them all. The studio used to keep that in a separate
-- Swarm tab with its own coordinator and its own frame loop. It is one engine
-- now: the chat turn runs as coordinator actor 0 in the shared scheduler (see
-- agentview.lua's submit/tick), the studio pumps that scheduler every frame,
-- and so the swarm tools work straight from the chat and any sub-agent it
-- spawns actually runs. The Swarm tab is a dashboard onto the same engine.
--
-- The cost is paid only when it is used. "swarm mode by default" is about the
-- capability being present, not about every conversation running a coordinator
-- ceremony: the common case is still one agent having a normal conversation,
-- and it must feel exactly as it did. So setup is split in two --
--   setup_swarm()  -- cheap, at startup: require the actor layer, register the
--                     tools, start the (guarded, no-op-when-idle) pump.
--   ensure_engine() -- the heavy half (bus + journal writer + observation),
--                     deferred to the first spawn.

-- The swarm engine -- setup_swarm / ensure_engine / observe_on / ensure_session
-- / start_pump and is_swarm_tool -- lives in core/engine.lua now (S3). install()
-- defines those methods on this studio table, so their callers are unchanged and
-- studio.lua stays the composition it should be.
require("core.engine").install(studio)

function studio.open_agent()
  -- In the shell, the conversation is the AGENT workspace; switching there
  -- re-homes and focuses the view (shell.workspaces.agent.enter re-adds it),
  -- which is all this used to do via workspaces.show_chat. The fallthrough below
  -- still handles a closed/never-built panel in either composition.
  local sh = package.loaded["shell"]
  if sh and sh.attached and sh.switch then
    sh.switch("agent")
    if studio.view and core.root_view.root_node:get_node_for_view(studio.view) then
      core.set_active_view(studio.view)
      return studio.view
    end
  end
  local existing = studio.agent_view()
  if existing then
    -- Bring the tab forward as well as taking focus. set_active_view only moves
    -- the keyboard, so with a file open in the same node the window went on
    -- showing the file while everything typed went into the conversation -- and
    -- the panel's size stayed stale, since it was never the drawn view.
    local node = core.root_view.root_node:get_node_for_view(existing)
    if node then node:set_active_view(existing) end
    core.set_active_view(existing)
    return existing
  end
  -- The panel was closed. Put it back in the main area rather than splitting:
  -- there is only ever one conversation view, and it belongs in the middle.
  local view = studio.view or AgentView()
  studio.view = view
  core.root_view:get_primary_node():add_view(view)
  core.set_active_view(view)
  return view
end

-- Chat or Code. The rail layout maps these onto workspaces; the legacy
-- attach still flips the Chat/Code segmented control and the file tree.
function studio.show_surface(which)
  -- In the shell those two surfaces are workspaces, not tabs in one node.
  local sh = package.loaded["shell"]
  if sh and sh.attached then
    if which == "code" then sh.switch("edit") else studio.open_agent() end
    return
  end
  local tree = package.loaded["plugins.treeview"]
  local has_tree = type(tree) == "table" and tree.visible ~= nil
  if which == "code" then
    if has_tree then tree.visible = true end
    local node = core.root_view:get_primary_node()
    for i = #node.views, 1, -1 do
      if node.views[i].doc then
        node:set_active_view(node.views[i])
        core.set_active_view(node.views[i])
        return
      end
    end
    -- Nothing open yet. "Code" should land you in a file, not in an empty
    -- room with a hint about which keys to press.
    command.perform("core:find-file")
  else
    if has_tree then tree.visible = false end
    core.set_active_view(studio.open_agent())
  end
end

-- Open a session from the sidebar.
function studio.open_session(id)
  if bog.session and bog.session.id == id then
    core.set_active_view(studio.open_agent())
    return
  end
  bog.save_session()
  if not bog.resume_session(id) then
    core.error("could not load session %d", id)
    return
  end
  local v = studio.open_agent()
  v:repaint(bog.session.messages)
  v:push("system", string.format("session %d -- %d messages, model %s",
    id, #bog.session.messages, bog.session.model))
  core.set_active_view(v)
  if studio.sidebar then studio.sidebar:refresh(true) end
end

-- Delete a session from the store. If it is the one on screen there is nothing
-- left to show, so a fresh conversation takes its place; the sidebar re-reads
-- either way. The confirm-guard lives at the call sites (a second click on the
-- sidebar's ×, a y/n on the command) -- by the time we are here the decision is
-- already made.
function studio.delete_session(id)
  if not id then return end
  bog.store.sess_delete(id)
  if bog.session and bog.session.id == id then
    -- Deliberately no save first: the row is gone, and saving would resurrect
    -- it. Start clean, exactly as agent:new-session does.
    bog.new_session()
    local v = studio.open_agent()
    v.entries = {}
    v:push("system", "new session " .. tostring(bog.session.id))
  end
  if bog.events then pcall(bog.events.emit, "session:deleted", { id = id }) end
  if studio.sidebar then studio.sidebar:refresh(true) end
end

function studio.toggle_agent()
  -- In the shell, Chat/Code is AGENT/EDIT: the same two surfaces the legacy
  -- sidebar's segmented control switched, now as workspaces.
  local shell = package.loaded["shell"]
  if shell and shell.attached then
    if shell.current == "agent" then shell.switch("edit")
    else studio.open_agent() end
    return
  end
  local v = studio.agent_view()
  if v and core.active_view == v then
    -- Focus back to the code rather than closing: losing the transcript
    -- because you wanted to type in a file would be infuriating.
    local node = core.root_view:get_primary_node()
    if node and node.active_view then core.set_active_view(node.active_view) end
  else
    studio.open_agent()
  end
end

-- Send the current selection (or the whole buffer) to the agent with a prompt.
function studio.ask_about_selection(template)
  local dv = core.active_view
  if not dv or not dv.doc then
    core.error("no document in the active view")
    return
  end
  local text = dv.doc:get_text(dv.doc:get_selection())
  local whole = false
  if text == "" then
    text = table.concat(dv.doc.lines)
    whole = true
  end
  local name = dv.doc.filename or "(untitled)"
  local view = studio.open_agent()
  local header = string.format("%s (%s):\n", template,
    whole and name or (name .. ", selection"))
  view:submit(header .. "```\n" .. text .. "\n```")
end

-- ---------------------------------------------------------------------------
-- Status: the agent's state belongs in the status bar, not only in the panel
-- ---------------------------------------------------------------------------

local function human_tokens(n)
  n = tonumber(n) or 0
  if n < 1000 then return tostring(math.floor(n)) end
  return string.format("%.1fk", n / 1000)
end

function studio.status_items()
  if not bog then return {} end
  local v = studio.view or studio.agent_view()

  -- Which model, and crucially where it runs: local (your own server, free) or
  -- remote (a named vendor, per-token money). The status()-derived provider is
  -- the same one a request resolves, so the badge cannot claim you are on local
  -- while a request goes to the cloud. Remote is the one worth flagging -- it is
  -- the "what am I about to spend money on?" this line exists to answer -- so the
  -- provider name takes the warning colour when remote and stays dim when local.
  -- bog.api.status and bog.api.cost resolve the provider and price the session;
  -- both are stable second-to-second but the status bar redraws them every
  -- frame. Cache for ~1s so an idle window isn't re-pricing itself 60×/s. The
  -- volatile bits below (approve?/busy/mode/token counts) stay live.
  local now = system.get_time()
  local cache = studio._status_cache
  if not cache or now - cache.at > 1 then
    local sok, sst = pcall(bog.api.status)
    local dollars
    if bog.api and bog.api.cost then
      local cok, d = pcall(bog.api.cost, bog.session)
      if cok then dollars = d end
    end
    cache = { at = now, st = sok and sst or nil, dollars = dollars }
    studio._status_cache = cache
  end
  local st = cache.st
  local out
  if st then
    out = { style.dim, "agent ",
      st.is_local and style.dim or (style.warn or style.accent), st.provider,
      style.dim, " · ", style.text, st.model }
    if st.is_local then out[#out + 1] = style.dim; out[#out + 1] = "  " .. st.host end
  else
    out = { style.dim, "agent ", style.text, (bog.session and bog.session.model) or "?" }
  end

  -- Token usage: what this conversation has cost, and how full the context is.
  -- The percentage is the actionable one -- it says when a compaction is
  -- coming -- so it gets a colour when it matters instead of being one more
  -- grey number.
  local u = bog.session and bog.session.usage
  if u and u.turns and u.turns > 0 then
    out[#out + 1] = style.dim
    out[#out + 1] = string.format("  %s in / %s out",
      human_tokens((u.input or 0) + (u.cached or 0)), human_tokens(u.output))
  end

  -- Money: the same "spend" signal the provider badge already carries, made
  -- literal. Remote shows an estimated $ in the warn colour -- the one number
  -- here that is actual dollars. Local shows nothing: api.cost() returns nil for
  -- your own server, so there is no fake price to warn about.
  local dollars = cache.dollars
  if dollars and dollars > 0 then
    out[#out + 1] = style.warn or style.accent
    out[#out + 1] = string.format("  ~$%.4f", dollars)
  end
  if bog.api and bog.api.context_fraction then
    local frac, used = bog.api.context_fraction(bog.session)
    if used > 0 then
      local ratio = bog.api.COMPACT_RATIO or 0.8
      out[#out + 1] = (frac >= ratio and (style.warn or style.accent))
        or (frac >= ratio * 0.75 and style.text) or style.dim
      -- math.floor, not a bare "+ 0.5": %d rejects a float in Lua 5.3+, and
      -- statusview.lua pcalls this function -- so the model, the token counts,
      -- the context percentage, [approve?] and the mode badge all disappeared
      -- together, with no error anywhere, for any conversation that had a
      -- context to report.
      out[#out + 1] = string.format("  ctx %s (%d%%)", human_tokens(used),
        math.floor(frac * 100 + 0.5))
    end
  end

  local A = package.loaded["shell.automations"]
  if A and A.scheduled then
    out[#out + 1] = style.dim
    out[#out + 1] = string.format("  [every %gm: %s]",
      A.scheduled.minutes, A.scheduled.name)
  end

  if v then
    if v.pending then
      out[#out + 1] = style.warn or style.accent
      out[#out + 1] = "  [approve?]"
    elseif v.busy then
      out[#out + 1] = style.dim
      out[#out + 1] = "  [" .. (v.status or "busy") .. "]"
    elseif v.mode ~= "smart" then
      out[#out + 1] = (v.mode == "auto" and (style.warn or style.dim)) or style.dim
      out[#out + 1] = "  [" .. v:mode_label():lower() .. "]"
    end
  end
  return out
end

-- Project files as plain relative paths, for the attach picker.
function studio.project_paths()
  local out = {}
  for _, f in ipairs(core.project_files or {}) do
    if f.type == "file" then out[#out + 1] = f.filename end
  end
  return out
end

-- One settings view, opened as a tab beside the conversation.
function studio.open_settings()
  -- Reuse the singleton wherever it lives: a stashed (inactive-workspace) view is
  -- OUT of the live Node tree, so searching only the primary node would miss it
  -- and build a duplicate. Search the whole root -- if found in a node, bring it
  -- forward; if stashed (no node), re-home it into the current primary node.
  if studio.settings then
    local node = core.root_view.root_node:get_node_for_view(studio.settings)
    if node then
      node:set_active_view(studio.settings)
    else
      core.root_view:get_primary_node():add_view(studio.settings)
    end
    core.set_active_view(studio.settings)
    return studio.settings
  end
  studio.settings = SettingsView()
  core.root_view:get_primary_node():add_view(studio.settings)
  core.set_active_view(studio.settings)
  return studio.settings
end

-- The swarm gets its own tab beside the conversation, like Settings: it is a
-- second surface onto the same engine, not a mode the window switches into.
function studio.open_swarm() return SwarmView.open() end

-- The Library: the tools the agent wrote for itself, its skills, its memory and
-- its MCP servers. A tab beside the conversation, like settings, because it is
-- a place you look at rather than a command you have to know the name of.
function studio.open_library(section)
  -- Singleton, reused wherever it lives -- see open_settings for why the search
  -- is over the whole root and why a stashed instance is re-homed rather than
  -- duplicated across workspaces.
  if not studio.library then
    studio.library = LibraryView()
    core.root_view:get_primary_node():add_view(studio.library)
  else
    local node = core.root_view.root_node:get_node_for_view(studio.library)
    if node then node:set_active_view(studio.library)
    else core.root_view:get_primary_node():add_view(studio.library) end
  end
  if section then studio.library:set_section(section) end
  core.set_active_view(studio.library)
  return studio.library
end

-- The cross-file review: every unreviewed edit in one list, walk or accept-all.
-- A tab beside the conversation like Settings; a singleton reused wherever it
-- lives so a second open surfaces the existing panel rather than a duplicate.
function studio.open_review()
  if studio.review then
    local node = core.root_view.root_node:get_node_for_view(studio.review)
    if node then node:set_active_view(studio.review)
    else core.root_view:get_primary_node():add_view(studio.review) end
  else
    studio.review = require("core.reviewview")()
    core.root_view:get_primary_node():add_view(studio.review)
  end
  studio.review:refresh()
  core.set_active_view(studio.review)
  return studio.review
end

-- ---------------------------------------------------------------------------
-- Agent-written panels
-- ---------------------------------------------------------------------------
--
-- Opened as tabs in the main area, so a panel the agent wrote sits alongside
-- the conversation and the files rather than in some lesser category. It is a
-- surface of the application like any other; that is the whole claim.

studio.panels = {}

function studio.open_panel(name)
  -- One instance per panel name, reused wherever it lives -- see open_settings
  -- for the whole-root search and the re-home-instead-of-duplicate rule. Reload
  -- on every reopen, live or re-homed.
  local existing = studio.panels[name]
  if existing then
    existing:reload()
    local node = core.root_view.root_node:get_node_for_view(existing)
    if node then
      node:set_active_view(existing)
    else
      core.root_view:get_primary_node():add_view(existing)
    end
    core.set_active_view(existing)
    return existing
  end
  local view = PanelView(name)
  studio.panels[name] = view
  core.root_view:get_primary_node():add_view(view)
  core.set_active_view(view)
  return view
end

function studio.close_panel(name)
  local view = studio.panels[name]
  studio.panels[name] = nil
  if not view then return false end
  local node = core.root_view.root_node:get_node_for_view(view)
  if node then
    node:set_active_view(view)
    node:close_active_view(core.root_view.root_node)
  end
  return true
end

-- Say something where the user is actually looking.
--
-- core.log flashes a line in the status bar for a few seconds and files it in
-- the log view; core.log_quiet shows nothing at all. For a command someone
-- typed into the palette that is reasonable. For a button they just clicked in
-- the conversation it is not: the reply appears twenty inches away in six-point
-- text, next to the token counters, and is gone before they look down. Which
-- is why "the button does nothing" was a fair description of a button that was
-- working exactly as written.
--
-- Anything reachable from the toolbar answers in the transcript instead.
function studio.say(fmt, ...)
  local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  local v = studio.agent_view()
  if v then v:push("system", text) end
  core.log_quiet("%s", text)
  return text
end

-- One picker at a time, as a tab beside the conversation.
function studio.pick(mode, on_pick)
  local node = core.root_view:get_primary_node()
  local start = (core.project_roots and core.project_roots[#core.project_roots])
    or sys.cwd()
  studio.picker = PickerView(mode, start, on_pick)
  node:add_view(studio.picker)
  core.set_active_view(studio.picker)
  return studio.picker
end

-- Work in a folder: the agent's working directory, the file tree, and the
-- window title all move together.
--
-- The agent's tools resolve relative paths against the process's working
-- directory, so this is a real chdir rather than a setting -- and everything
-- derived from it has to be told: the cached git project root (which decides
-- where project-scoped tools are filed), the file scanner, and the tree, which
-- caches per path. The model is told by the system prompt, which now states
-- the working directory and is rebuilt each turn.
function studio.work_in(path)
  if sys.stat(path) ~= "dir" then
    core.error("%s is not a directory", tostring(path))
    return false
  end
  local ok, err = pcall(system.chdir, path)
  if not ok then
    core.error("cannot work in %s: %s", path, tostring(err))
    return false
  end

  if bog.tools and bog.tools.forget_project then bog.tools.forget_project() end
  core.project_roots = {}
  core.project_files = {}

  local tree = package.loaded["plugins.treeview"]
  if type(tree) == "table" and tree.cache then tree.cache = {} end

  system.set_window_title(path:match("[^/\\]+$") or path)
  studio.say("Working in %s. The agent's read, write, edit, list and bash now "
    .. "resolve relative paths here.", path)
  core.log("working in %s", path)
  return true
end

-- Add a folder to the project. The scanner picks it up on its next pass, so
-- the tree and ctrl+p find it without anything having to be told twice.
function studio.add_folder(path)
  core.project_roots = core.project_roots or {}
  for _, r in ipairs(core.project_roots) do
    if r == path then studio.say("%s is already in the project.", path); return false end
  end
  if sys.stat(path) ~= "dir" then
    core.error("%s is not a directory", tostring(path))
    return false
  end
  core.project_roots[#core.project_roots + 1] = path
  studio.say("Added %s to the project.", path)
  -- The agent works in the process's cwd, so a folder added to the *window*
  -- is not automatically a folder the agent will write to. Saying so is
  -- better than letting someone discover it from a refused edit.
  core.log_quiet("note: the agent still works from %s; use @paths to point it "
    .. "at files in an added folder", sys.cwd())
  return true
end


-- ---------------------------------------------------------------------------
-- MCP persistence
-- ---------------------------------------------------------------------------

local function quote(v)
  if type(v) == "table" then
    local parts = {}
    for _, x in ipairs(v) do parts[#parts + 1] = quote(x) end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end
  return string.format("%q", tostring(v))
end

-- Append a spec to ~/.boggart/lua/mcp_servers.lua. Written as source rather
-- than parsed-and-rewritten: the file is the user's to edit, and rewriting it
-- would throw away their comments and formatting to save one append.
function studio.save_mcp_server(spec)
  local path = bog.userdir .. "/lua/mcp_servers.lua"
  local body = bog.util.read_file(path)
  local fields = {}
  for _, k in ipairs { "name", "transport", "command", "url" } do
    if spec[k] then fields[#fields + 1] = k .. " = " .. quote(spec[k]) end
  end
  if spec.args and #spec.args > 0 then
    fields[#fields + 1] = "args = " .. quote(spec.args)
  end
  local entry = "  { " .. table.concat(fields, ", ") .. " },\n"

  if body and body:find("return%s*{") then
    -- Insert before the closing brace of the returned table.
    local head, tail = body:match("^(.-)%s*(\n%s*}%s*)$")
    if head then
      bog.util.write_file(path, head .. "\n" .. entry:gsub("\n$", "") .. tail)
      return true
    end
  end
  bog.util.write_file(path, (body or "") .. "\nreturn {\n" .. entry .. "}\n")
  return true
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

local function prompt(label, submit, default)
  core.command_view:enter(label, submit, function() return {} end, nil, default)
end

-- The recents as a fuzzy list -- "id  date  title", newest first -- for the
-- session commands that need you to point at one. Same label shape as
-- agent:resume-session, so the palette reads the same whichever verb you reach
-- for. on_pick(id) runs once a row is chosen.
local function session_picker(label, on_pick)
  local rows = bog.store.sess_list(30)
  local items, byname = {}, {}
  for _, s in ipairs(rows) do
    local it = string.format("%d  %s  %s", s.id,
      os.date("%m-%d %H:%M", s.updated), s.title or "(untitled)")
    items[#items + 1] = it
    byname[it] = s.id
  end
  core.command_view:enter(label, function(text, item)
    local id = byname[item or text]
    if id then on_pick(id) end
  end, function(text) return common.fuzzy_match(items, text) end)
end

-- The clipboard verbs are predicated on the conversation being focused, so
-- they take the stroke when it is ours and leave it alone when it is not.
command.add(function() return core.active_view == studio.agent_view() end, {
  ["agent:paste"] = function()
    local v = studio.agent_view(); if v then v:on_key_pressed("ctrl+v") end
  end,
  ["agent:copy"] = function()
    local v = studio.agent_view(); if v then v:on_key_pressed("ctrl+c") end
  end,
  ["agent:cut"] = function()
    local v = studio.agent_view(); if v then v:on_key_pressed("ctrl+x") end
  end,
  ["agent:select-all"] = function()
    local v = studio.agent_view(); if v then v:on_key_pressed("ctrl+a") end
  end,
})

command.add(nil, {
  ["agent:toggle-panel"] = studio.toggle_agent,
  ["agent:open-panel"]   = studio.open_agent,

  ["agent:explain-selection"] = function()
    studio.ask_about_selection("Explain this code")
  end,
  ["agent:review-selection"] = function()
    studio.ask_about_selection("Review this code for bugs and suggest fixes")
  end,
  ["agent:test-selection"] = function()
    studio.ask_about_selection("Write tests for this code")
  end,

  ["agent:cancel"] = function()
    local v = studio.agent_view()
    if v then v:cancel() end
  end,

  -- Voice dictation ("speak and/or type"): the composer mic button and any
  -- keybinding both route here. Opens the agent panel so the dictated text has
  -- a composer to land in.
  ["agent:voice-toggle"] = function()
    local v = studio.open_agent()
    if v and v.voice_toggle then v:voice_toggle() end
  end,

  -- ---- approval -----------------------------------------------------------
  ["agent:toggle-approval"] = function()
    local v = studio.open_agent()
    v:set_mode(v.mode == "auto" and "smart" or "auto")
    core.log("mode: %s", v:mode_label())
  end,

  ["agent:set-mode"] = function()
    local v = studio.view or studio.open_agent()
    local items = {}
    local cur_mode = v.mode or (require("perm").state().mode)
    for _, m in ipairs(v.MODES) do
      items[#items + 1] = {
        label = string.format("%s -- %s", m.label, m.help),
        checked = (m.id == cur_mode),   -- open on the mode you are actually in
        action = function() v:set_mode(m.id) end,
      }
    end
    local anchor = v.mode_hit
    if anchor and not studio.legacy then
      menu.show(anchor, items)
      return
    end
    local labels, byname = {}, {}
    for _, it in ipairs(items) do
      labels[#labels + 1] = it.label
      byname[it.label] = it.action
    end
    core.command_view:enter("Permission mode:", function(text, item)
      local act = byname[item or text]
      if act then act() end
    end, function(text) return common.fuzzy_match(labels, text) end)
  end,

  -- Per-tool overrides, because a mode alone cannot say "ask about everything
  -- except read".
  ["agent:tool-permission"] = function()
    local v = studio.open_agent()
    local names = {}
    for _, t in ipairs(bog.tools.schemas()) do names[#names + 1] = t.name end
    table.sort(names)
    core.command_view:enter("Tool:", function(text, item)
      local name = item or text
      if name == "" then return end
      local choices = { "ask", "allow", "deny", "default (follow the mode)" }
      core.command_view:enter("Permission for " .. name .. ":", function(t2, i2)
        local pick = i2 or t2
        v.tool_policy[name] = (pick ~= "default (follow the mode)") and pick or nil
        v:push("system", string.format("%s: %s", name, v:policy_for(name)))
        core.log("%s -> %s", name, v:policy_for(name))
      end, function(t2) return common.fuzzy_match(choices, t2) end)
    end, function(text) return common.fuzzy_match(names, text) end)
  end,

  ["agent:show-permissions"] = function()
    local v = studio.open_agent()
    core.log_quiet("mode: %s", v:mode_label())
    local any = false
    for name, p in pairs(v.tool_policy) do
      core.log_quiet("  %s = %s", name, p); any = true
    end
    studio.say("Permission mode: %s%s", v:mode_label(),
      any and ", with per-tool overrides" or "")
  end,
  ["agent:approve"] = function()
    local v = studio.agent_view(); if v then v:decide("approve") end
  end,
  ["agent:reject"] = function()
    local v = studio.agent_view(); if v then v:decide("reject") end
  end,

  -- ---- context ------------------------------------------------------------
  ["agent:compact-now"] = function()
    local v = studio.agent_view()
    if v and v.busy then core.error("busy -- cancel the turn first"); return end
    local frac, used = bog.api.context_fraction(bog.session)
    if used == 0 then studio.say("Nothing to compact yet."); return end
    core.log("compacting %d tokens (%d%%)...", used, math.floor(frac * 100 + 0.5))
    if v then v.busy, v.status = true, "compacting" end
    -- Compact yields "io" on the HTTP stream. Drive it on a studio thread so
    -- the frame loop keeps pumping instead of freezing the window.
    core.add_thread(function()
      local ok, err = pcall(bog.api.compact, bog.session, {})
      if v then v.busy, v.status = false, "idle" end
      if not ok then core.error("compaction failed: %s", tostring(err)); return end
      if v then
        v:repaint(bog.session.messages)
        v:push("system", "context compacted by hand")
      end
      core.log("compacted -- now %d tokens", select(2, bog.api.context_fraction(bog.session)))
    end)
  end,

  ["agent:show-context"] = function()
    local frac, used = bog.api.context_fraction(bog.session)
    studio.say("context %d / %d tokens (%d%%), compacts at %d%%; %d compaction(s) so far",
      used, bog.api.context_limit(bog.session), math.floor(frac * 100 + 0.5),
      (bog.api.COMPACT_RATIO or 0.8) * 100,
      (bog.session.usage and bog.session.usage.compactions) or 0)
  end,

  -- ---- usage --------------------------------------------------------------
  ["agent:show-usage"] = function()
    local u = bog.session and bog.session.usage
    if not u or not u.turns or u.turns == 0 then
      studio.say("No usage recorded in this session yet.")
      return
    end
    -- Cost is an ESTIMATE from api.PRICING; a local endpoint has no per-token
    -- price, so cost() returns nil and we say "local" rather than print $0.00.
    local money = ""
    if bog.api and bog.api.cost then
      local okc, dollars = pcall(bog.api.cost, bog.session)
      if okc then
        money = dollars and string.format(" | ~$%.4f (est.)", dollars)
          or " | local (no per-token cost)"
      end
    end
    studio.say("%d turns | %d input (+%d cached) | %d output | last request %d tokens%s",
      u.turns, u.input or 0, u.cached or 0, u.output or 0, u.last_input or 0, money)
  end,

  -- ---- configuration ------------------------------------------------------
  ["agent:set-api-key"] = function()
    prompt("Anthropic API key:", function(text)
      if text == "" then return end
      -- Same validate/trim/store/invalidate as the settings and welcome screens:
      -- a key pasted with a trailing newline used to be stored raw and 401.
      local ok, err = require("core.settings").set("api_key", text)
      if not ok then core.error("%s", err); return end
      core.log("stored api key %s", select(1, auth.masked()))
    end)
  end,

  ["agent:set-endpoint"] = function()
    prompt("Base URL (blank for the Anthropic API):", function(text)
      local settings = require "core.settings"
      if text == "" then
        settings.clear("base_url")
        core.log("using the Anthropic API")
      else
        local ok, err = settings.set("base_url", text)
        if not ok then core.error("%s", err); return end
        core.log("endpoint: %s", bog.api.endpoint())
      end
    end, auth.base_url() or "http://127.0.0.1:8000")
  end,

  ["agent:set-model"] = function()
    local v = studio.view or studio.open_agent()
    local current = (bog.session and bog.session.model) or ""
    local function apply(text)
      if text == "" then return end
      local model, err = require("core.settings").set("model", text)
      if not model then core.error("%s", err); return end
      bog.session.model = model
      core.log("model: %s", model)
    end
    -- The dropdown, filled from the catalog.
    --
    -- It used to offer exactly two rows -- the model you were already on, and
    -- "Enter model…" -- so the control looked like a picker and behaved like a
    -- text prompt. Now it lists what is actually available, grouped by
    -- provider, with the providers you can REACH first: a model whose key is
    -- missing is not a choice, it is a detour, so those are shown last and
    -- labelled rather than mixed in.
    local items, listed = {}, {}
    local okc, cat = pcall(require, "catalog")
    if okc then
      -- roles first: they are the answer to "which model for this kind of
      -- work", which is what a person is usually choosing between.
      local roles = cat.roles()
      local rnames = {}
      for n in pairs(roles) do rnames[#rnames + 1] = n end
      table.sort(rnames)
      if #rnames > 0 then
        items[#items + 1] = { heading = "roles" }
        for _, n in ipairs(rnames) do
          local target = roles[n][1]
          items[#items + 1] = {
            label = string.format("%s  (%s)", n, table.concat(roles[n], " → ")),
            action = function() apply(target) end,
          }
        end
      end

      -- models, grouped by provider, keyed providers first
      local by_provider, order = {}, {}
      for _, m in ipairs(cat.models{}) do
        local pn = m.provider or "other"
        if not by_provider[pn] then by_provider[pn] = {}; order[#order + 1] = pn end
        table.insert(by_provider[pn], m)
      end
      local keyed = {}
      for _, pn in ipairs(order) do
        local pr = cat.provider(pn)
        keyed[pn] = pr and auth.has_key and auth.has_key(pr.key_slot or pn) or false
      end
      table.sort(order, function(a, b)
        if keyed[a] ~= keyed[b] then return keyed[a] end
        return a < b
      end)
      for _, pn in ipairs(order) do
        items[#items + 1] = { heading = keyed[pn] and pn or (pn .. "  (no key)") }
        for _, m in ipairs(by_provider[pn]) do
          local label = m.id
          if m.context then label = label .. "   " .. math.floor(m.context / 1000) .. "k" end
          listed[m.id] = true
          items[#items + 1] = {
            label = label, checked = (m.id == current),
            action = function() apply(m.id) end,
          }
        end
      end
    end
    -- Pin the current model at the top only when the catalog does not already
    -- list it (a hand-typed id, or one from a provider that has been removed).
    -- Compared by ID, not by the drawn label: the label carries the context
    -- size, so matching on it always failed and always produced a duplicate row
    -- above the list.
    if current ~= "" and not listed[current] then
      table.insert(items, 1, { label = current, checked = true,
                               action = function() apply(current) end })
    end
    items[#items + 1] = { heading = "" }
    items[#items + 1] = {
      label = "Search all models…",
      action = function() command.perform("agent:models") end,
    }
    items[#items + 1] = {
      label = "Enter model…",
      action = function()
        prompt("Model:", apply, current)
      end,
    }
    if v and v.model_hit and not studio.legacy then
      menu.show(v.model_hit, items)
      return
    end
    prompt("Model:", apply, current)
  end,

  ["agent:show-config"] = function()
    local masked, src = auth.masked()
    core.log("key %s (%s) | endpoint %s | model %s",
      masked, src or "-", bog.api.endpoint(), bog.session.model)
  end,

  -- ---- sessions -----------------------------------------------------------
  ["agent:new-session"] = function()
    bog.new_session()
    local v = studio.open_agent()
    v.entries = {}
    v:push("system", "new session " .. tostring(bog.session.id))
  end,

  ["agent:resume-session"] = function()
    session_picker("Resume session:", function(id)
      if bog.resume_session(id) then
        local v = studio.open_agent()
        v:repaint(bog.session.messages)
        v:push("system", string.format("resumed session %d (%d messages, model %s)",
          id, #bog.session.messages, bog.session.model))
      end
    end)
  end,

  ["agent:delete-session"] = function()
    session_picker("Delete session:", function(id)
      -- Confirm-guard: a delete cannot be undone, so make it a second,
      -- deliberate keystroke rather than one stray Enter on a fuzzy match.
      prompt("Delete session " .. id .. "? [y]es / [n]o:", function(ans)
        if ans:sub(1, 1):lower() == "y" then studio.delete_session(id) end
      end, "n")
    end)
  end,

  ["agent:rename-session"] = function()
    session_picker("Rename session:", function(id)
      -- The active conversation's live copy, or the stored one for any other:
      -- either way sess_save is handed the existing model and messages, so a
      -- rename changes only the title (titles are otherwise auto-set from the
      -- first message and never editable).
      local s = (bog.session and bog.session.id == id) and bog.session
        or bog.store.sess_load(id)
      if not s then return end
      prompt("New title:", function(title)
        title = (title:gsub("^%s+", ""):gsub("%s+$", ""))
        if title == "" then return end
        bog.store.sess_save(id, title, s.model, s.messages)
        -- Keep bog.session in step so the footer and the next save do not put
        -- the old title back.
        if bog.session and bog.session.id == id then bog.session.title = title end
        if studio.sidebar then studio.sidebar:refresh(true) end
        core.log("renamed session %d", id)
      end, s.title or "")
    end)
  end,

  -- ---- tools: the self-extension surface, made visible --------------------
  -- What is currently reacting to events, and how often it has fired. The
  -- point of an event system you cannot list is hard to defend.
  ["agent:show-event-handlers"] = function()
    local rows = (bog.events and bog.events.list()) or {}
    if #rows == 0 then
      studio.say("No event handlers registered.")
      return
    end
    for _, h in ipairs(rows) do
      core.log_quiet("#%d  %-20s %-10s %d calls  %s", h.id, h.pattern,
        h.source or "?", h.calls, h.desc or "")
    end
    studio.say("%d event handler(s) -- details in the log (ctrl+l)", #rows)
  end,

  ["agent:show-tools"] = function()
    studio.open_library("tools")
  end,

  -- ---- MCP servers --------------------------------------------------------
  -- Servers are declared in ~/.boggart/lua/mcp_servers.lua, which boot.lua
  -- already reads at startup. These commands edit that file rather than
  -- inventing a second registry, so what the GUI configures is exactly what
  -- the terminal boggart connects to.
  ["agent:list-mcp-servers"] = function()
    studio.open_library("mcp")
  end,

  ["agent:add-mcp-server"] = function()
    prompt("MCP server name:", function(name)
      if name == "" then return end
      prompt("Command (stdio), or an http(s):// URL:", function(cmd)
        if cmd == "" then return end
        local spec
        if cmd:match("^https?://") then
          spec = { name = name, transport = "http", url = cmd }
        else
          local args = {}
          for word in cmd:gmatch("%S+") do args[#args + 1] = word end
          spec = { name = name, command = table.remove(args, 1), args = args }
        end
        local names, err
        core.add_thread(function()
          names, err = bog.mcphost.add(spec)
          if not names then
            core.error("mcp '%s': %s", name, tostring(err))
            return
          end
          studio.save_mcp_server(spec)
          core.log("connected '%s' (%d tools), saved to mcp_servers.lua",
            name, #names)
        end)
      end)
    end)
  end,

  ["agent:edit-mcp-servers"] = function()
    local path = bog.userdir .. "/lua/mcp_servers.lua"
    if not bog.util.read_file(path) then
      bog.util.write_file(path, "-- MCP servers, one spec per entry.\n"
        .. "-- stdio: { name = \"x\", command = \"npx\", args = { \"-y\", \"pkg\" } }\n"
        .. "-- http:  { name = \"x\", transport = \"http\", url = \"https://...\" }\n"
        .. "return {\n}\n")
    end
    core.root_view:open_doc(core.open_doc(path))
  end,

  -- ---- editing the conversation -------------------------------------------
  -- Both of these rewrite history, so they operate on bog.session.messages --
  -- the thing the model actually sees -- and repaint the panel from it
  -- afterwards. Editing the transcript without editing the messages would give
  -- you a panel that disagrees with the conversation.
  ["agent:edit-message"] = function()
    local v = studio.open_agent()
    if v.busy then core.error("busy -- cancel the turn first"); return end
    local items, byname = {}, {}
    for i, m in ipairs(bog.session.messages) do
      if m.role == "user" and type(m.content) == "string" then
        local label = string.format("%d: %s", i,
          m.content:gsub("%s+", " "):sub(1, 70))
        items[#items + 1] = label
        byname[label] = i
      end
    end
    if #items == 0 then core.log("no editable messages yet"); return end
    core.command_view:enter("Edit which message:", function(text, item)
      local idx = byname[item or text]
      if not idx then return end
      local original = bog.session.messages[idx].content
      prompt("Edited message:", function(edited)
        if edited == "" then return end
        prompt("[e]dit in place or [f]ork to a new session?", function(choice)
          local fork = choice:sub(1, 1):lower() == "f"
          local kept = {}
          for i = 1, idx - 1 do kept[i] = bog.session.messages[i] end
          if fork then
            bog.new_session()
            core.log("forked to session %s", tostring(bog.session.id))
          end
          -- Everything after the edited message described a conversation that
          -- no longer happened, so it goes either way. Fork differs only in
          -- whether the original session keeps its copy.
          bog.session.messages = kept
          v:repaint(bog.session.messages)
          v:push("system", fork and ("forked at message " .. idx)
                                 or ("edited message " .. idx
                                     .. "; later turns discarded"))
          v:submit(edited)
        end, "e")
      end, original)
    end, function(text) return common.fuzzy_match(items, text) end)
  end,

  -- ---- saved prompts (the automations store) ------------------------------
  -- The saved-prompt feature is the automations store now (shell/automations),
  -- which folded in what used to be recipes / workflows / schedule. These agent:*
  -- names are the toolbar and sidebar entry points -- and the only ones the
  -- legacy composition has, since it draws no shell menu -- so they route into
  -- exactly the same pickers the Run menu uses.
  ["agent:run-recipe"]      = function() require("shell.automations").run_picker() end,
  ["agent:edit-recipe"]     = function() require("shell.automations").edit_picker() end,
  ["agent:schedule-recipe"] = function() require("shell.automations").schedule_picker() end,
  ["agent:stop-schedule"]   = function()
    if require("shell.automations").stop_schedule() then core.log("schedule stopped")
    else core.log("nothing scheduled") end
  end,

  ["agent:save-recipe"] = function()
    local v = studio.open_agent()
    local draft = v:input_text()
    if draft == "" then
      core.error("nothing in the input to save -- type the prompt first")
      return
    end
    prompt("Name this automation:", function(name)
      if name == "" then return end
      name = name:gsub("[^%w_%-]", "-")
      local A = require "shell.automations"
      A.save(name, draft)
      local params = A.params(draft)
      core.log("saved automation '%s'%s", name, #params > 0
        and (" (parameters: " .. table.concat(params, ", ") .. ")") or "")
      v:push("system", "saved automation '" .. name .. "' -- {{name}} marks a parameter")
    end)
  end,

  -- ReAct: the goal supervisor with Thought → Act → Observe prompts. Sends
  -- through /react so slash handling, the turn budget and the session save
  -- stay one path with the REPL. (Orthogonal to saved prompts -- kept.)
  ["agent:react"] = function()
    prompt("ReAct goal:", function(text)
      if not text or text == "" then return end
      local v = studio.open_agent()
      if v.send_prompt then v:send_prompt("/react " .. text)
      else v:submit(text) end
    end)
  end,

  -- ---- things the buttons call --------------------------------------------
  -- ---- opening things ------------------------------------------------------
  -- A picker, because there was no way to reach anything that was not passed
  -- on the command line. See core/pickerview.lua for why it is drawn rather
  -- than delegated to the system dialog.
  -- ---- fonts ---------------------------------------------------------------
  ["studio:set-font"] = function()
    local which = "code"
    core.command_view:enter("Which text: code (the conversation) or ui?",
      function(text, item)
        which = (item or text) == "ui" and "ui" or "code"
        studio.pick("file", function(path)
          if not path then return end
          if not path:lower():match("%.tt[fc]$") and not path:lower():match("%.otf$") then
            studio.say("%s does not look like a font file (.ttf, .ttc or .otf).", path)
            return
          end
          local problems, refused = fonts.set(which, path)
          if refused then
            studio.say("%s", refused)
          elseif problems and #problems > 0 then
            for _, p2 in ipairs(problems) do studio.say("%s", p2) end
          else
            studio.say("%s font is now %s.", which, path:match("[^/\\]+$") or path)
          end
        end, fonts.first_search_path())
      end, function(text)
        return require("core.common").fuzzy_match({ "code", "ui" }, text)
      end)
  end,

  ["studio:font-size"] = function()
    local s2 = fonts.settings()
    prompt("Size for the conversation text:", function(text)
      local n = tonumber(text)
      if not n or n < 6 or n > 72 then
        studio.say("A font size between 6 and 72, please.")
        return
      end
      fonts.set("code", nil, n)
      studio.say("Conversation text is now %g point.", n)
    end, tostring(s2.code.size))
  end,

  ["studio:reset-fonts"] = function()
    fonts.reset()
    studio.say("Fonts are back to the ones that ship with boggart.")
  end,

  ["studio:open-file"] = function()
    studio.pick("file", function(path)
      if path then core.root_view:open_doc(core.open_doc(path)) end
    end)
  end,

  -- Choosing a folder means working in it. That is what people mean by it, and
  -- what the first version got wrong: it added the folder to the file tree and
  -- left the agent standing in whatever directory boggart was launched from,
  -- so the tree showed one project while read and bash operated on another.
  ["studio:open-folder"] = function()
    studio.pick("folder", function(path)
      if path then studio.work_in(path) end
    end)
  end,

  -- The old behaviour, kept and named honestly: another tree to search and
  -- open from, without moving the agent.
  ["studio:add-folder"] = function()
    studio.pick("folder", function(path)
      if path then studio.add_folder(path) end
    end)
  end,

  ["studio:remove-folder"] = function()
    local roots = core.project_roots or {}
    if #roots == 0 then core.log("no added folders to remove"); return end
    core.command_view:enter("Stop watching which folder:", function(text, item)
      local pick = item or text
      for i, r in ipairs(roots) do
        if r == pick then
          table.remove(roots, i)
          core.log("removed %s (its files leave the tree on the next scan)", r)
          return
        end
      end
    end, function(text) return common.fuzzy_match(roots, text) end)
  end,

  ["studio:toggle-files"] = function()
    local sh = package.loaded["shell"]
    if sh and sh.attached and sh.current ~= "edit" then
      sh.switch("edit")
      return
    end
    command.perform("treeview:toggle")
  end,

  ["studio:toggle-sidebar"] = function()
    if studio.sidebar then
      local sh = package.loaded["shell"]
      if sh and sh.attached and sh.current ~= "agent" then
        sh.switch("agent")
        studio.sidebar.visible = true
        return
      end
      studio.sidebar:toggle()
    else
      -- No rail (tests, or a composition that never docked one): the file tree
      -- is the equivalent surface.
      command.perform("treeview:toggle")
    end
  end,

  ["studio:open-panel"] = function()
    local names = uitools.list()
    if #names == 0 then
      core.log("no panels yet -- ask the agent to draw one")
      return
    end
    core.command_view:enter("Panel:", function(text, item)
      local name = item or text
      if name ~= "" then studio.open_panel(name) end
    end, function(text) return common.fuzzy_match(names, text) end)
  end,

  ["studio:edit-panel"] = function()
    local names = uitools.list()
    if #names == 0 then core.log("no panels yet"); return end
    core.command_view:enter("Edit panel:", function(text, item)
      local name = item or text
      if name ~= "" then
        core.root_view:open_doc(core.open_doc(uitools.path(name)))
      end
    end, function(text) return common.fuzzy_match(names, text) end)
  end,

  -- The settings screen. A form you can look at, rather than a sequence of
  -- modal prompts that cannot show you what is already set.
  ["agent:settings"] = function()
    studio.open_settings()
  end,

  -- The first-run screen, on purpose rather than because it is a first run.
  ["agent:welcome"] = function()
    require("core.welcomeview").open()
  end,

  ["agent:library"] = function()
    studio.open_library()
  end,

  ["agent:review"] = function()
    studio.open_review()
  end,

  ["agent:swarm"] = function()
    SwarmView.open()
  end,

  -- The palette version is still here: it is faster once you know what you
  -- want, and it reaches things the form deliberately does not duplicate.
  ["agent:settings-list"] = function()
    local items = {
      { "Welcome (set up a model)", "agent:welcome" },
      { "Font",                   "studio:set-font" },
      { "Font size",              "studio:font-size" },
      { "Reset fonts",            "studio:reset-fonts" },
      { "Library (tools, memory)", "agent:library" },
      { "Swarm (multi-agent)",    "agent:swarm" },
      { "Event handlers",         "agent:show-event-handlers" },
      { "Permission mode",        "agent:set-mode" },
      { "Per-tool permissions",   "agent:tool-permission" },
      { "Model",                  "agent:set-model" },
      { "API key",                "agent:set-api-key" },
      { "Endpoint (local model)", "agent:set-endpoint" },
      { "MCP servers",            "agent:list-mcp-servers" },
      { "Add an MCP server",      "agent:add-mcp-server" },
      { "Edit mcp_servers.lua",   "agent:edit-mcp-servers" },
      { "Show configuration",     "agent:show-config" },
      { "Context and compaction", "agent:show-context" },
      { "Token usage",            "agent:show-usage" },
      { "Current permissions",    "agent:show-permissions" },
    }
    local labels, bylabel = {}, {}
    for _, it in ipairs(items) do
      labels[#labels + 1] = it[1]
      bylabel[it[1]] = it[2]
    end
    core.command_view:enter("Settings:", function(text, item)
      local cmd = bylabel[item or text]
      if cmd then command.perform(cmd) end
    end, function(text) return common.fuzzy_match(labels, text) end)
  end,

  -- Attach a file by name. Inserts the @mention rather than the contents:
  -- expansion already happens on send, and putting a 40 KB file in the
  -- composer would be unreadable.
  ["agent:attach-file"] = function()
    local v = studio.open_agent()
    core.command_view:enter("Attach file:", function(text, item)
      local path = item or text
      if path == "" then return end
      local cur = v:input_text()
      local sep = (cur == "" or cur:sub(-1):match("%s")) and "" or " "
      v:set_input(cur .. sep .. "@" .. path .. " ")
      core.set_active_view(v)
    end, function(text)
      return common.fuzzy_match(core.project_files_as_paths and
        core.project_files_as_paths() or studio.project_paths(), text)
    end)
  end,

  -- ---- build / run --------------------------------------------------------
  -- Deliberately routed through the agent's own bash tool rather than a second
  -- process-spawning path: it is already non-blocking, already bounded, and
  -- already streams into the panel.
  ["agent:run-command"] = function()
    prompt("Run:", function(text)
      if text == "" then return end
      studio.last_command = text
      local v = studio.open_agent()
      v:push("tool", text, "bash")
      -- Off the frame loop: bog.tools.run("bash") yields to the scheduler (which
      -- the studio pumps), so the window keeps painting instead of freezing while
      -- the command runs. Negative id -> not a thread row, no FLEET entry.
      local co = coroutine.create(function()
        local r = bog.tools.run("bash", { command = text })
        v:push("assistant", r)
      end)
      if bog.sched and bog.sched.add then bog.sched.add(-800001, co)
      else v:push("assistant", (bog.tools.run("bash", { command = text }))) end
    end, studio.last_command or "")
  end,
})

-- ---------------------------------------------------------------------------
-- Keymap
-- ---------------------------------------------------------------------------

keymap.add {
  -- doc:newline-below first so ctrl+return still inserts a line in the editor
  -- (it only performs in a focused DocView); elsewhere it toggles the agent panel.
  ["ctrl+return"]     = { "doc:newline-below", "agent:toggle-panel" },
  ["ctrl+shift+a"]    = "agent:open-panel",
  ["ctrl+shift+e"]    = "agent:explain-selection",
  ["ctrl+shift+r"]    = "agent:review-selection",
  ["ctrl+shift+b"]    = "agent:run-command",
  ["ctrl+shift+g"]    = "agent:toggle-approval",
  ["ctrl+b"]          = "studio:toggle-sidebar",
  ["ctrl+shift+w"]    = "agent:workflows",
  ["ctrl+shift+l"]    = "agent:library",
  ["ctrl+v"]          = "agent:paste",
  ["cmd+v"]           = "agent:paste",
  ["ctrl+c"]          = "agent:copy",
  ["cmd+c"]           = "agent:copy",
  ["ctrl+x"]          = "agent:cut",
  ["cmd+x"]           = "agent:cut",
  ["ctrl+a"]          = "agent:select-all",
  ["cmd+a"]           = "agent:select-all",
  ["ctrl+o"]          = "studio:open-file",
  ["ctrl+shift+o"]    = "studio:open-folder",
  ["ctrl+alt+o"]      = "studio:add-folder",
  ["ctrl+shift+m"]    = "swarm:open",
}

return studio
