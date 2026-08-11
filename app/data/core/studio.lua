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

local studio = {}

-- ---------------------------------------------------------------------------
-- The panel
-- ---------------------------------------------------------------------------

function studio.agent_view()
  if studio.view and studio.view.node and not studio.view.node.is_deleted then
    return studio.view
  end
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
  node:split("right", view, true)
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

  -- Token usage: what this conversation has cost, and how big the next
  -- request will be. The second number is the one that predicts a compaction.
  local u = bog.session and bog.session.usage
  if u and u.turns and u.turns > 0 then
    out[#out + 1] = style.dim
    out[#out + 1] = string.format("  %s in / %s out",
      human_tokens((u.input or 0) + (u.cached or 0)), human_tokens(u.output))
    if u.last_input and u.last_input > 0 then
      out[#out + 1] = "  ctx " .. human_tokens(u.last_input)
    end
  end

  if v then
    if v.pending then
      out[#out + 1] = style.warn or style.accent
      out[#out + 1] = "  [approve?]"
    elseif v.busy then
      out[#out + 1] = style.dim
      out[#out + 1] = "  [" .. (v.status or "busy") .. "]"
    elseif not v.gate then
      out[#out + 1] = style.warn or style.dim
      out[#out + 1] = "  [approval off]"
    end
  end
  return out
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
    v.gate = not v.gate
    core.log("approval %s", v.gate and "on -- writes, edits and commands will ask"
                                    or "OFF -- the agent acts without asking")
  end,
  ["agent:approve"] = function()
    local v = studio.agent_view(); if v then v:decide("approve") end
  end,
  ["agent:reject"] = function()
    local v = studio.agent_view(); if v then v:decide("reject") end
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
