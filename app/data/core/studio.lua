-- studio.lua -- boggart-studio: the app layer over lite.
--
-- Adds the agent panel, the commands that drive it, and the configuration
-- surfaces (credentials, model, MCP servers, sessions). Loaded from
-- core/init.lua after the editor is up.
--
-- Everything here is ordinary lite Lua and ordinary boggart Lua in one
-- interpreter, which is the point: the agent can edit this file and reload it,
-- so the application's own UI is inside the agent's reach.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local AgentView = require "core.agentview"
local recipes = require "core.recipes"

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

function studio.open_agent()
  local existing = studio.agent_view()
  if existing then
    core.set_active_view(existing)
    return existing
  end
  local view = AgentView()
  studio.view = view
  -- Split right: the agent belongs beside the code, not on top of it.
  local node = core.root_view:get_active_node()
  -- No `locked` third argument. A locked node is pinned to its view's current
  -- size, and a freshly constructed View is 0x0 -- so locking it here gave the
  -- panel zero width for the lifetime of the process. Unlocked, it is an
  -- ordinary split the user can drag.
  node:split("right", view)
  core.set_active_view(view)
  return view
end

function studio.toggle_agent()
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
  local v = studio.agent_view()
  local out = { style.dim, "agent ", style.text, (bog.session and bog.session.model) or "?" }

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
  if bog.api and bog.api.context_fraction then
    local frac, used = bog.api.context_fraction(bog.session)
    if used > 0 then
      local ratio = bog.api.COMPACT_RATIO or 0.8
      out[#out + 1] = (frac >= ratio and (style.warn or style.accent))
        or (frac >= ratio * 0.75 and style.text) or style.dim
      out[#out + 1] = string.format("  ctx %s (%d%%)", human_tokens(used), frac * 100 + 0.5)
    end
  end

  if studio.schedule then
    out[#out + 1] = style.dim
    out[#out + 1] = string.format("  [every %gm: %s]",
      studio.schedule.minutes, studio.schedule.name)
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

function studio.stop_schedule()
  if not studio.schedule then return false end
  studio.schedule.stop = true
  studio.schedule = nil
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

  -- ---- approval -----------------------------------------------------------
  ["agent:toggle-approval"] = function()
    local v = studio.open_agent()
    v:set_mode(v.mode == "auto" and "smart" or "auto")
    core.log("mode: %s", v:mode_label())
  end,

  ["agent:set-mode"] = function()
    local v = studio.open_agent()
    local items, byname = {}, {}
    for _, m in ipairs(v.MODES) do
      local label = string.format("%s -- %s", m.label, m.help)
      items[#items + 1] = label
      byname[label] = m.id
    end
    core.command_view:enter("Permission mode:", function(text, item)
      local id = byname[item or text]
      if id then v:set_mode(id) end
    end, function(text) return common.fuzzy_match(items, text) end)
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
    core.log("mode %s%s (details in the log)", v:mode_label(),
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
    if used == 0 then core.log("nothing to compact"); return end
    core.log("compacting %d tokens (%d%%)...", used, frac * 100 + 0.5)
    -- Synchronous on purpose: this is a deliberate, user-initiated pause, and
    -- the alternative is a second concurrent turn against the same session.
    local ok, err = pcall(bog.api.compact, bog.session, {})
    if not ok then core.error("compaction failed: %s", tostring(err)); return end
    if v then
      v:repaint(bog.session.messages)
      v:push("system", "context compacted by hand")
    end
    core.log("compacted -- now %d tokens", select(2, bog.api.context_fraction(bog.session)))
  end,

  ["agent:show-context"] = function()
    local frac, used = bog.api.context_fraction(bog.session)
    core.log("context %d / %d tokens (%d%%), compacts at %d%%; %d compaction(s) so far",
      used, bog.api.context_limit(bog.session), frac * 100 + 0.5,
      (bog.api.COMPACT_RATIO or 0.8) * 100,
      (bog.session.usage and bog.session.usage.compactions) or 0)
  end,

  -- ---- usage --------------------------------------------------------------
  ["agent:show-usage"] = function()
    local u = bog.session and bog.session.usage
    if not u or not u.turns or u.turns == 0 then
      core.log("no usage recorded in this session yet")
      return
    end
    core.log("%d turns | %d input (+%d cached) | %d output | last request %d tokens",
      u.turns, u.input or 0, u.cached or 0, u.output or 0, u.last_input or 0)
  end,

  -- ---- configuration ------------------------------------------------------
  ["agent:set-api-key"] = function()
    prompt("Anthropic API key:", function(text)
      if text == "" then return end
      auth.set("api_key", text)
      if bog.api and bog.api.forget_auth then bog.api.forget_auth() end
      core.log("stored api key %s", select(1, auth.masked()))
    end)
  end,

  ["agent:set-endpoint"] = function()
    prompt("Base URL (blank for the Anthropic API):", function(text)
      if text == "" then
        auth.clear("base_url")
        core.log("using the Anthropic API")
      else
        auth.set("base_url", text)
        if bog.api and bog.api.forget_auth then bog.api.forget_auth() end
        core.log("endpoint: %s", bog.api.endpoint())
      end
    end, auth.base_url() or "http://127.0.0.1:8000")
  end,

  ["agent:set-model"] = function()
    prompt("Model:", function(text)
      if text == "" then return end
      auth.set("model", text)
      bog.session.model = text
      core.log("model: %s", text)
    end, (bog.session and bog.session.model) or "")
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
    local rows = bog.store.sess_list(30)
    local items, byname = {}, {}
    for _, s in ipairs(rows) do
      local label = string.format("%d  %s  %s", s.id,
        os.date("%m-%d %H:%M", s.updated), s.title or "(untitled)")
      items[#items + 1] = label
      byname[label] = s.id
    end
    core.command_view:enter("Resume session:", function(text, item)
      local id = byname[item or text]
      if not id then return end
      if bog.resume_session(id) then
        local v = studio.open_agent()
        v:repaint(bog.session.messages)
        v:push("system", string.format("resumed session %d (%d messages, model %s)",
          id, #bog.session.messages, bog.session.model))
      end
    end, function(text)
      return common.fuzzy_match(items, text)
    end)
  end,

  -- ---- tools: the self-extension surface, made visible --------------------
  ["agent:show-tools"] = function()
    local report = bog.tools.report({})
    for line in (report .. "\n"):gmatch("(.-)\n") do
      if line ~= "" then core.log_quiet("%s", line) end
    end
    core.log("tool report written to the log (ctrl+l)")
  end,

  -- ---- MCP servers --------------------------------------------------------
  -- Servers are declared in ~/.boggart/lua/mcp_servers.lua, which boot.lua
  -- already reads at startup. These commands edit that file rather than
  -- inventing a second registry, so what the GUI configures is exactly what
  -- the terminal boggart connects to.
  ["agent:list-mcp-servers"] = function()
    local live = bog.mcphost and bog.mcphost.list() or {}
    if #live == 0 then
      core.log("no MCP servers connected -- 'agent: add mcp server' to add one")
      return
    end
    for _, e in ipairs(live) do
      core.log_quiet("%s (%d tools): %s", e.server, #e.tools,
        table.concat(e.tools, ", "))
    end
    core.log("%d MCP server(s) connected -- details in the log (ctrl+l)", #live)
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
        local names, err = bog.mcphost.add(spec)
        if not names then
          core.error("mcp '%s': %s", name, tostring(err))
          return
        end
        studio.save_mcp_server(spec)
        core.log("connected '%s' (%d tools), saved to mcp_servers.lua",
          name, #names)
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

  -- ---- recipes ------------------------------------------------------------
  ["agent:run-recipe"] = function()
    local names = recipes.list()
    if #names == 0 then
      core.log("no recipes yet -- 'agent: save recipe' stores the current draft")
      return
    end
    core.command_view:enter("Recipe:", function(text, item)
      local name = item or text
      local body = recipes.load(name)
      if not body then core.error("no recipe '%s'", name); return end
      local v = studio.open_agent()
      recipes.prompt_params(body, function(filled)
        v:push("system", "recipe: " .. name)
        v:submit(v:expand_mentions(filled))
      end)
    end, function(text) return common.fuzzy_match(names, text) end)
  end,

  ["agent:save-recipe"] = function()
    local v = studio.open_agent()
    local draft = v:input_text()
    if draft == "" then
      core.error("nothing in the input to save -- type the prompt first")
      return
    end
    prompt("Recipe name:", function(name)
      if name == "" then return end
      name = name:gsub("[^%w_%-]", "-")
      local path = recipes.save(name, draft)
      local params = recipes.params(draft)
      core.log("saved %s%s", path, #params > 0
        and (" (parameters: " .. table.concat(params, ", ") .. ")") or "")
      v:push("system", "saved recipe '" .. name .. "' -- {{name}} marks a parameter")
    end)
  end,

  ["agent:edit-recipe"] = function()
    local names = recipes.list()
    if #names == 0 then core.log("no recipes yet"); return end
    core.command_view:enter("Edit recipe:", function(text, item)
      local name = item or text
      if recipes.load(name) then
        core.root_view:open_doc(core.open_doc(recipes.path(name)))
      end
    end, function(text) return common.fuzzy_match(names, text) end)
  end,

  -- ---- scheduler ----------------------------------------------------------
  -- In-process and while-the-window-is-open only. A scheduler that outlives
  -- the app would need a daemon, a persisted queue and a story for what
  -- happens when a run wants approval while nobody is watching -- and boggart
  -- already has `boggart swarm` for unattended work. This is the small honest
  -- version: repeat a recipe on an interval, visibly, in front of you.
  ["agent:schedule-recipe"] = function()
    local names = recipes.list()
    if #names == 0 then core.log("no recipes to schedule"); return end
    core.command_view:enter("Schedule recipe:", function(text, item)
      local name = item or text
      local body = recipes.load(name)
      if not body then return end
      if #recipes.params(body) > 0 then
        core.error("'%s' takes parameters; schedule only runs fixed prompts", name)
        return
      end
      prompt("Every how many minutes:", function(mins)
        local n = tonumber(mins)
        if not n or n <= 0 then core.error("not a number of minutes"); return end
        studio.stop_schedule()
        local v = studio.open_agent()
        studio.schedule = { name = name, minutes = n, runs = 0, stop = false }
        core.add_thread(function()
          while studio.schedule and not studio.schedule.stop do
            for _ = 1, math.floor(n * 60 / 0.5) do
              if not studio.schedule or studio.schedule.stop then return end
              coroutine.yield(0.5)
            end
            if studio.schedule and not studio.schedule.stop and not v.busy then
              studio.schedule.runs = studio.schedule.runs + 1
              v:push("system", string.format("scheduled run %d of '%s'",
                studio.schedule.runs, name))
              v:submit(body)
            end
          end
        end)
        core.log("'%s' every %g min -- 'agent: stop schedule' to cancel", name, n)
      end, "30")
    end, function(text) return common.fuzzy_match(names, text) end)
  end,

  ["agent:stop-schedule"] = function()
    if studio.stop_schedule() then core.log("schedule stopped")
    else core.log("nothing scheduled") end
  end,

  -- ---- build / run --------------------------------------------------------
  -- Deliberately routed through the agent's own bash tool rather than a second
  -- process-spawning path: it is already non-blocking, already bounded, and
  -- already streams into the panel.
  ["agent:run-command"] = function()
    prompt("Run:", function(text)
      if text == "" then return end
      local v = studio.open_agent()
      v:push("tool", text, "bash")
      local r = bog.tools.run("bash", { command = text })
      v:push("assistant", r)
    end, studio.last_command or "")
  end,
})

-- ---------------------------------------------------------------------------
-- Keymap
-- ---------------------------------------------------------------------------

keymap.add {
  ["ctrl+return"]     = "agent:toggle-panel",
  ["ctrl+shift+a"]    = "agent:open-panel",
  ["ctrl+shift+e"]    = "agent:explain-selection",
  ["ctrl+shift+r"]    = "agent:review-selection",
  ["ctrl+shift+b"]    = "agent:run-command",
  ["ctrl+shift+g"]    = "agent:toggle-approval",
}

return studio
