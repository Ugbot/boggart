-- shell/init.lua -- the studio shell (default window composition).
--
-- Ground-up redesign that SUPERSEDES the legacy composition (core/studio.lua +
-- sidebarview + the everything-is-a-tab primary node). It reuses the proven
-- engine (the agent turn loop, the scheduler pump, the Node split layout, marks)
-- and rebuilds the shell on top: a menu bar, switchable full-screen workspaces
-- (AGENT / EDIT / FLEET), and an app-wide neovim spine.
--
-- Restore the legacy window with BOGGART_STUDIO_LEGACY=1.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local MenuBar = require "shell.menubar"

local shell = {}
shell.workspaces = { "agent", "edit", "fleet" }
shell.current = nil -- set by the first shell.switch(); nil means "nothing entered
                    -- yet", so the first switch doesn't stash a phantom workspace.

local function primary() return core.root_view:get_primary_node() end

shell._stash = {} -- workspace name -> { views = {...}, active = view }

-- Every NON-LOCKED leaf under the tree, in a/b traversal order. Locked leaves
-- (the menu bar, the file tree) are docks -- excluded here so the walk sees only
-- the content leaves a workspace owns. `get_primary_node()` returns just the
-- FIRST of these; the whole point of this helper is to see the rest too.
local function each_content_leaf(node, t)
  if node.type == "leaf" then
    if not node.locked then t[#t + 1] = node end
  else
    each_content_leaf(node.a, t)
    each_content_leaf(node.b, t)
  end
  return t
end

-- Merge the primary sub-tree back down to a SINGLE content leaf after the user
-- has split it (Ctrl-w s / v). We reuse the exact tree-merge close_active_view
-- performs: consume the split node's OTHER child into the split node, which
-- drops one content leaf per pass. `get_locked_size()` is truthy only for a
-- fully-locked subtree, so a dock is never swallowed -- its sibling (the content
-- block) always stays put. Content has already been stashed by the caller, so
-- which leaf survives doesn't matter; the caller re-fetches primary() after.
local function collapse_content_leaves(root)
  while true do
    local leaves = each_content_leaf(root, {})
    if #leaves <= 1 then return end
    local merged = false
    for _, leaf in ipairs(leaves) do
      local parent = leaf:get_parent_node(root)
      if parent then
        local other = (parent.a == leaf) and parent.b or parent.a
        if not other:get_locked_size() then
          parent:consume(other)
          merged = true
          break
        end
      end
    end
    -- Only dock-adjacent leaves left (structurally unreachable in this shell):
    -- bail instead of looping forever rather than risk swallowing a dock.
    if not merged then return end
  end
end

-- Switch workspace WITH content isolation: each workspace keeps its own set of
-- views in the primary leaf, so EDIT is a clean editor and AGENT is a clean
-- conversation -- not everything piled into one tab strip. The file tree and
-- other docks are toggled by each workspace's enter()/leave().
--
-- STRATEGY: this flattens splits into tabs (option B). If the user has split the
-- primary (Ctrl-w s / v) there are MULTIPLE content leaves; we collect every
-- view from all of them into the stash, then collapse back to one leaf. This
-- loses split *geometry* across a switch but never loses a view's content (the
-- old code stashed only the first leaf and stranded the rest -- a data-loss bug,
-- plus the orphaned sibling rendered stale content into the next workspace). To
-- upgrade to option A (preserve geometry), stash/rebuild the content sub-tree's
-- shape here instead of flattening -- see collapse_content_leaves above.
function shell.switch(name)
  local ok, ws = pcall(require, "shell.workspaces." .. name)
  if not ok or type(ws) ~= "table" then return end
  local EmptyView = require("core.rootview").EmptyView
  local node = primary()
  if not node then return end

  -- Already here: don't stash/restore self (that churns the leaf and can strand
  -- views). Just re-run enter() so the workspace re-docks/re-focuses. This is the
  -- path agent commands take when they route through the AGENT workspace.
  if name == shell.current then
    if ws.enter then pcall(ws.enter) end
    core.redraw = true
    return
  end

  -- stash the current workspace's views, run its leave (hide its docks)
  if shell.current then
    local root = core.root_view.root_node
    local leaves = each_content_leaf(root, {})
    -- Flatten every content leaf's views (in tree order, deduped, splash
    -- placeholders dropped) so a split workspace stashes ALL its content, not
    -- just the first leaf's.
    local views, seen = {}, {}
    for _, leaf in ipairs(leaves) do
      for _, v in ipairs(leaf.views) do
        if not seen[v] and not v:is(EmptyView) then
          seen[v] = true
          views[#views + 1] = v
        end
      end
    end
    -- Keep the focused view as the restored active. Prefer the globally focused
    -- view (it may live in a split pane other than the first leaf), fall back to
    -- the primary leaf's, then to the last tab. `seen` excludes EmptyView and any
    -- dropped view, so whatever we pick is a real, surviving content view.
    local active = core.active_view
    if not active or not seen[active] then active = node.active_view end
    if not active or not seen[active] then active = views[#views] end
    shell._stash[shell.current] = { views = views, active = active }

    -- Collapse the extra split panes back to one leaf so the sibling can't
    -- render stale content into the next workspace. Note once, since flattening
    -- silently discards the user's split layout.
    if #leaves > 1 then
      if not shell._warned_flatten then
        shell._warned_flatten = true
        core.log("shell: split panes flattened into tabs on workspace switch (geometry not yet preserved)")
      end
      collapse_content_leaves(root)
      node = primary() -- the tree changed under us; re-fetch the surviving leaf
      if not node then return end
    end

    if shell.current_ws and shell.current_ws.leave then pcall(shell.current_ws.leave) end
  end

  -- reset the leaf to the target's stashed views (or the splash placeholder)
  node.views = {}
  local st = shell._stash[name]
  if st and #st.views > 0 then
    for _, v in ipairs(st.views) do node.views[#node.views + 1] = v end
    node.active_view = st.active or node.views[#node.views]
  else
    node.views = { EmptyView() }
    node.active_view = node.views[1]
  end
  if node.active_view then core.set_active_view(node.active_view) end

  shell.current, shell.current_ws = name, ws
  if ws.enter then pcall(ws.enter) end
  pcall(function() core.root_view.root_node:update_layout() end)
  core.redraw = true
end

-- A menu title opens that menu's grouped chooser (fuzzy-filterable, with key
-- hints) from the shared registry. The chooser is also what leader/which-key
-- uses; anchored dropdowns are the P6 visual pass.
function shell.open_menu(name)
  local choices = require("shell.registry").choices(name)
  if not choices or #choices == 0 then return command.perform("core:find-command") end
  require("shell.modal").chooser(name, choices, function(pick)
    command.perform(pick.cmd)
  end)
end

-- Draw the menu dropdown ON TOP of the content and route global mouse to it, by
-- wrapping RootView (the dropdown is an overlay, not a docked view).
function shell.install_menu_overlay()
  if shell.menu_overlay_installed then return end
  shell.menu_overlay_installed = true
  local RootView = require "core.rootview"
  local odraw = RootView.draw
  function RootView:draw(...)
    odraw(self, ...)
    if shell.menubar and shell.menubar.open then shell.menubar:draw_dropdown() end
  end
  local omp = RootView.on_mouse_pressed
  function RootView:on_mouse_pressed(button, x, y, clicks)
    if shell.menubar and shell.menubar:handle_press(x, y) then return end
    return omp(self, button, x, y, clicks)
  end
  local omm = RootView.on_mouse_moved
  function RootView:on_mouse_moved(x, y, dx, dy)
    if shell.menubar then shell.menubar:handle_move(x, y) end
    return omm(self, x, y, dx, dy)
  end
end

-- Cycle AGENT -> EDIT -> FLEET (nvim `gt`/`gT`, leader `t`).
function shell.cycle_workspace(dir)
  local order, i = shell.workspaces, 1
  for j, w in ipairs(order) do if w == shell.current then i = j end end
  shell.switch(order[((i - 1 + (dir or 1)) % #order) + 1])
end

-- Docks that belong to one workspace. AGENT gets the session list (the same
-- recents rail the legacy sidebar was), EDIT gets the file tree, FLEET gets
-- neither. Called from each workspace's enter() so a Files-button toggle in
-- AGENT cannot leak the tree into FLEET, and leaving AGENT hides the recents.
function shell.set_docks(which)
  local studio = package.loaded["core.studio"]
  if studio and studio.sidebar then
    studio.sidebar.visible = (which == "agent")
  end
  local ok, tree = pcall(require, "plugins.treeview")
  if ok and type(tree) == "table" and tree.visible ~= nil then
    tree.visible = (which == "edit")
  end
end

-- Compose the window: reuse the agent engine, drop the legacy chrome, dock the
-- menu bar, and open the AGENT workspace. Called from core.init in place of
-- the legacy core.studio.attach().
function shell.attach()
  if shell.attached then return end
  shell.attached = true

  local studio = require "core.studio"
  local AgentView = require "core.agentview"

  -- ---- reconcile studio's invariant with workspace isolation ---------------
  --
  -- studio.lua was written around "the AgentView lives in the primary node" and
  -- locates it with get_node_for_view. Workspace isolation stashes the view OUT
  -- of the live tree when you leave AGENT, so from EDIT/FLEET that lookup returns
  -- nil -- and open_agent then builds a SECOND AgentView, orphaning the real
  -- conversation and polluting the other workspace. Fix at the source: studio.view
  -- is the single source of truth (it always exists after attach), and reaching
  -- the conversation means switching to the AGENT workspace -- which re-docks the
  -- one view -- never constructing another.
  studio.agent_view = function() return studio.view end
  studio.open_agent = function()
    shell.switch("agent")
    return studio.view
  end

  -- visual identity first, so the first frame is already the ember theme
  core.try(function() require("shell.theme").apply("dark") end)

  -- engine + look, without the old composition
  core.try(function() require("core.uitools").register(studio) end)
  core.try(function()
    local problems = require("core.fonts").apply()
    for _, p2 in ipairs(problems or {}) do core.log("%s", p2) end
  end)

  -- menu bar across the top of the content area (locked dock) + its dropdown overlay
  shell.menubar = MenuBar()
  primary():split("up", shell.menubar, true)
  shell.install_menu_overlay()

  -- Recents rail, the same SidebarView the legacy layout used, minus the
  -- Chat/Code control (workspaces replace that). Docked left of the content
  -- leaf so AGENT has conversations on the left the way EDIT has files.
  -- Visibility is owned by shell.set_docks, called from each workspace enter.
  core.try(function()
    local SidebarView = require "core.sidebarview"
    local rail = SidebarView()
    rail.shell_rail = true
    studio.sidebar = rail
    primary():split("left", rail, true)
  end)

  -- AGENT is the default workspace: build its AgentView, then enter it (which
  -- docks the sessions rail and shows the conversation).
  local view = AgentView()
  studio.view = view
  studio.attached = true -- keep the old attach from also firing

  core.try(studio.setup_swarm)

  -- Land the user back in their last conversation on every launch after the
  -- first (like Claude/ChatGPT desktop). The welcome screen owns the first run
  -- and must start empty, so defer to it by asking the same question. core.try:
  -- a store that cannot be read must still leave a usable chat window. (The old
  -- studio.attach does this too, but the shell suppresses that path, so the
  -- behaviour has to be reproduced here.)
  core.try(function()
    if require("core.welcomeview").is_first_run() then return end
    if not (bog.resume_startup and bog.resume_startup()) then
      local recent = bog.store.sess_list(1)
      local id = recent and recent[1] and recent[1].id
      if id then bog.resume_session(id) end
    end
    if bog.session and bog.session.id then view:repaint(bog.session.messages) end
  end)

  -- the app-wide neovim spine: Ctrl-w panes, g/gt, leader, normal-mode nav
  core.try(function() require("shell.modal").install() end)
  -- swarm approval gate: spawned sub-agents honour the coordinator's mode
  core.try(function() require("shell.agent.approval").install() end)
  -- FLEET is the swarm surface. `agent:swarm` / `swarm:open` used to add a
  -- second roster as a tab in whichever workspace you were in; they now switch
  -- here so there is one view on one scheduler.
  core.try(function()
    local SwarmView = require "core.swarmview"
    function SwarmView.open()
      shell.switch("fleet")
      return SwarmView.current()
    end
  end)
  -- The anchored dropdown (core/menu.lua). It was written, wired to the model
  -- and permission-mode chips, and never installed -- so `menu.show` set a flag
  -- that nothing drew and nothing routed clicks to, and clicking either chip
  -- did nothing at all. Installed AFTER the modal spine so its Escape and
  -- arrow keys are seen first: an open dropdown owns those keys while it is up.
  core.try(function() require("core.menu").install() end)

  shell.switch("agent")
  core.try(function() require("core.welcomeview").maybe_open() end)
  -- The shell suppresses studio.attach, which is otherwise the only MCP start.
  core.try(studio.start_mcp)
end

-- Workspace switching: Ctrl-1/2/3 now; `gt`/leader added with the modal spine
-- in P1.
command.add(nil, {
  ["shell:workspace-agent"] = function() shell.switch("agent") end,
  ["shell:workspace-edit"]  = function() shell.switch("edit") end,
  ["shell:workspace-fleet"] = function() shell.switch("fleet") end,
  ["shell:toggle-theme"]    = function() require("shell.theme").toggle() end,

  -- Automations: one saved-prompt concept (Run menu), superseding the old
  -- recipes / workflows / schedule split. The pickers live in shell.automations
  -- so the toolbar/sidebar agent:* entry points (and the legacy composition)
  -- share exactly this flow.
  ["automations:run"]      = function() require("shell.automations").run_picker() end,
  ["automations:new"]      = function() require("shell.automations").new_prompt() end,
  ["automations:manage"]   = function() require("shell.automations").edit_picker() end,
  ["automations:schedule"] = function() require("shell.automations").schedule_picker() end,
  ["automations:stop-schedule"] = function()
    if require("shell.automations").stop_schedule() then core.log("schedule stopped")
    else core.log("nothing scheduled") end
  end,

  -- ---- the model catalog, from the desktop --------------------------------
  --
  -- Picking a model is the one configuration act people do repeatedly, and it
  -- was previously "know the id, type it into /model". The picker lists what
  -- the catalog knows, says which providers actually have a key, and shows the
  -- context window -- the three things you weigh when choosing.
  ["agent:models"] = function()
    local catalog = require "catalog"
    local items = {}
    for _, m in ipairs(catalog.models{}) do
      local p = m.provider and catalog.provider(m.provider)
      local keyed = p and auth.has_key and auth.has_key(p.key_slot or p.name)
      items[#items + 1] = {
        text = m.id,
        info = string.format("%s%s  %s", m.provider or "?",
          keyed and "" or " (no key)",
          m.context and (math.floor(m.context / 1000) .. "k") or ""),
        model = m.id,
      }
    end
    table.sort(items, function(x, y) return x.text < y.text end)
    if #items == 0 then core.log("no models catalogued"); return end
    require("shell.modal").chooser("Model:", items, function(pick)
      command.perform("agent:set-model", pick.model)
      core.log("model: %s", pick.model)
    end)
  end,
  ["agent:roles"] = function()
    local catalog = require "catalog"
    local roles = catalog.roles()
    local items = {}
    for name, chain in pairs(roles) do
      items[#items + 1] = { text = name, info = table.concat(chain, " -> ") }
    end
    table.sort(items, function(x, y) return x.text < y.text end)
    if #items == 0 then core.log("no roles bound yet"); return end
    require("shell.modal").chooser("Role:", items, function(pick)
      core.log("%s -> %s", pick.text, pick.info)
    end)
  end,

  -- ---- the control plane, from the desktop --------------------------------
  --
  -- Same door the CLI's `boggart serve` opens: the C listener (src/lserve.c)
  -- with the Lua routes (lua/control.lua) on top. Exposed here because a
  -- feature nobody can find is a feature nobody has -- the studio is where
  -- most people will want to turn this on, hand the URL to a phone or a
  -- webhook, and turn it off again.
  ["service:start"] = function()
    local control = require "control"
    if control.server then core.log("service already on: %s", control.url()); return end
    local srv, url = control.start{}
    if not srv then core.error("service: %s", tostring(url)); return end
    core.log("service on: %s  (routes: %s/routes)", url, url)
  end,
  ["service:stop"] = function()
    if require("control").stop() then core.log("service off")
    else core.log("service was not running") end
  end,
  ["service:status"] = function()
    local control = require "control"
    if not control.server then core.log("service: off"); return end
    core.log("service: %s  %d event client(s)%s", control.url(),
      control.server:clients(), control.token and "  [token set]" or "")
  end,
  ["service:copy-url"] = function()
    local control = require "control"
    if not control.url() then core.log("service is off"); return end
    system.set_clipboard(control.url())
    core.log("copied %s", control.url())
  end,
})
keymap.add {
  ["ctrl+1"] = "shell:workspace-agent",
  ["ctrl+2"] = "shell:workspace-edit",
  ["ctrl+3"] = "shell:workspace-fleet",
  ["ctrl+shift+r"] = "agent:review",   -- cross-file review of the agent's edits
}

return shell
