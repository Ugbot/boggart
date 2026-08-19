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
  shell.switch("agent")
  core.try(function() require("core.welcomeview").maybe_open() end)
end

-- Workspace switching: Ctrl-1/2/3 now; `gt`/leader added with the modal spine
-- in P1.
command.add(nil, {
  ["shell:workspace-agent"] = function() shell.switch("agent") end,
  ["shell:workspace-edit"]  = function() shell.switch("edit") end,
  ["shell:workspace-fleet"] = function() shell.switch("fleet") end,
  ["shell:toggle-theme"]    = function() require("shell.theme").toggle() end,

  -- Automations: one saved-prompt concept (Run menu), superseding the old
  -- recipes / workflows / schedule split.
  ["automations:run"] = function()
    local A = require "shell.automations"
    local choices = A.choices()
    if #choices == 0 then
      core.log("no automations yet -- Run \u{25b8} New automation\u{2026}"); return
    end
    require("shell.modal").chooser("Run automation", choices, function(p) A.run(p.name) end)
  end,
  ["automations:new"] = function()
    core.command_view:enter("Automation name", function(name)
      if not name or name == "" then return end
      core.command_view:enter("Prompt for '" .. name .. "'", function(prompt)
        require("shell.automations").save(name, prompt)
        core.log("saved automation '" .. name .. "'")
      end)
    end)
  end,
  ["automations:manage"] = function()
    local A = require "shell.automations"
    local choices = A.choices()
    if #choices == 0 then core.log("no automations yet"); return end
    for _, c in ipairs(choices) do c.info = "edit / delete" end
    require("shell.modal").chooser("Edit automation", choices, function(p)
      core.command_view:enter("Prompt for '" .. p.name .. "' (blank = delete)", function(prompt)
        if not prompt or prompt == "" then A.remove(p.name); core.log("deleted '" .. p.name .. "'")
        else A.save(p.name, prompt); core.log("updated '" .. p.name .. "'") end
      end, nil, nil, A.load(p.name) or "")
    end)
  end,
})
keymap.add {
  ["ctrl+1"] = "shell:workspace-agent",
  ["ctrl+2"] = "shell:workspace-edit",
  ["ctrl+3"] = "shell:workspace-fleet",
}

return shell
