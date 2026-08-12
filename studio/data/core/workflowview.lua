-- workflowview.lua -- the workflow builder.
--
-- A chat message is a thing you say once. A workflow is a thing you build: an
-- ordered list of prompts with {{variables}}, a model chosen per step, a tool
-- allowlist per step, and a form for its inputs. That is the idea worth taking
-- from MindStudio -- the agent is an artifact with a shape you can see and
-- edit, not a paragraph you retype with different nouns in it.
--
-- The data lives in ~/.boggart/workflows/<name>.txt and the format is defined
-- in core/recipes.lua, next to the recipe format it extends. Nothing here
-- writes into the project.
--
-- Execution follows agentview.lua exactly, because it must: lite owns the frame
-- loop and calls update() sixty times a second, so a run is a coroutine that
-- gets turned a little each frame and yields whenever the transport would
-- block. A four-step workflow against a slow model is minutes of work and the
-- window stays live throughout. The turn loop itself is bog.api.run_on -- the
-- same one the chat panel uses, with a different session per step -- so there
-- is one implementation of "talk to the model until it stops", not two.
--
-- Each step gets a *fresh* session rather than appending to one growing
-- conversation. That is what makes per-step models meaningful (you cannot hand
-- one model's transcript to another and pretend it is the same conversation)
-- and it is what makes a step reproducible: its input is exactly its filled
-- prompt, nothing else.
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"
local widgets = require "core.widgets"
local recipes = require "core.recipes"

local workflows = recipes.workflows

local WorkflowView = View:extend()

local RAIL = 180 * SCALE
local OUTPUT_ROWS = 14      -- how much of a step's answer the card shows
local PROMPT_ROWS = 10      -- ...and of its prompt

-- Status colours for a step. ASCII markers only: this renderer has one font and
-- an exotic glyph draws as an empty box.
local STATE = {
  pending = { mark = "-",  color = "dim"   },
  running = { mark = ">",  color = "warn"  },
  done    = { mark = "ok", color = "good"  },
  failed  = { mark = "!!", color = "error" },
  stopped = { mark = "--", color = "dim"   },
}

function WorkflowView:new()
  WorkflowView.super.new(self)
  self.scrollable = true
  self.names = {}
  self.selected = nil
  self.wf = nil
  self.focus = nil          -- { kind = "prompt"|"name"|"model"|"tools"|"var", i }
  self.buffer = ""
  self.fields = {}          -- focus descriptors in visual order, rebuilt by draw
  self.hits = {}
  self.form = nil           -- { { name, value }, ... } while a run is being set up
  self.runner = nil
  self.co = nil
  self.busy = false
  self.notice = nil
  self:refresh()
end

function WorkflowView:get_name()
  return self.busy and "Workflows ..." or "Workflows"
end

-- ---------------------------------------------------------------------------
-- The list
-- ---------------------------------------------------------------------------
--
-- Re-read on demand, not per frame: this is a directory listing, and it changes
-- when you create or edit a workflow, which is not sixty times a second.

function WorkflowView:refresh()
  self.names = workflows.list()
  -- An empty list is where someone learns what a workflow is, so seed a working
  -- one rather than opening to a bare screen -- the same bargain the recipe list
  -- strikes. seed_example guards on emptiness, so this never overwrites anything
  -- the user made, and reappears only if they delete every workflow.
  if #self.names == 0 then
    if workflows.seed_example() then
      self.names = workflows.list()
      self.notice = { text = "seeded an example workflow -- edit it, or press Run" }
    end
  end
  if self.selected and not workflows.load(self.selected) then
    self.selected, self.wf = nil, nil
  end
  if not self.selected and #self.names > 0 then self:select(self.names[1]) end
  core.redraw = true
end

function WorkflowView:select(name)
  self.focus, self.buffer = nil, ""
  self.form, self.runner = nil, nil
  self.selected = name
  self.wf = name and workflows.load(name) or nil
  core.redraw = true
end

function WorkflowView:persist()
  if not (self.selected and self.wf) then return end
  local ok, err = pcall(workflows.save, self.selected, self.wf)
  self.notice = ok and { text = "saved" } or { text = tostring(err), bad = true }
  core.redraw = true
end

-- A new workflow is not empty. An empty one gives you nothing to react to, and
-- the two-step shape below is the whole idea in miniature -- a variable, a
-- second step that consumes the first through {{previous}}.
function WorkflowView:create(name)
  name = tostring(name or ""):gsub("[^%w_%-]", "-")
  if name == "" then return end
  if not workflows.load(name) then
    workflows.save(name, {
      description = "# " .. name .. " -- edit the steps, then press Run.",
      steps = {
        { name = "Draft", prompt = "Write a short note about {{topic}}." },
        { name = "Tighten",
          prompt = "Cut this to three sentences, keeping the meaning:\n\n{{previous}}" },
      },
    })
  end
  self:refresh()
  self:select(name)
end

-- ---------------------------------------------------------------------------
-- Editing
-- ---------------------------------------------------------------------------
--
-- One focused field and one buffer, the same mechanism settingsview uses, so
-- there is a single way to type into a field in this application. It differs
-- in one respect: the buffer starts as the current value rather than blank,
-- because a workflow prompt is something you amend and an API key is something
-- you replace.

function WorkflowView:edit(kind, i, current)
  self.focus = { kind = kind, i = i }
  self.buffer = tostring(current or "")
  core.set_active_view(self)
  core.redraw = true
end

function WorkflowView:commit()
  local f = self.focus
  if not f then return end
  local value = self.buffer
  self.focus, self.buffer = nil, ""
  if f.kind == "var" then
    if self.form and self.form[f.i] then self.form[f.i].value = value end
    core.redraw = true
    return
  end
  local step = self.wf and self.wf.steps[f.i]
  if not step then return end
  if f.kind == "prompt" then
    step.prompt = value
  elseif f.kind == "name" then
    step.name = (value ~= "" and value) or nil
  elseif f.kind == "model" then
    step.model = (value ~= "" and value) or nil
  elseif f.kind == "tools" then
    local list = workflows.split_list(value)
    step.tools = (#list > 0) and list or nil
  end
  self:persist()
end

function WorkflowView:focus_index()
  for i, f in ipairs(self.fields) do
    if self.focus and f.kind == self.focus.kind and f.i == self.focus.i then
      return i
    end
  end
end

-- Adding, moving or deleting a step renumbers the run that is on screen, and a
-- result shown against the wrong step is worse than no result at all. Editing
-- a prompt does not: the output still came from that step, and seeing what it
-- used to say is the reason you are editing it.
function WorkflowView:add_step()
  if not self.wf then return end
  self.wf.steps[#self.wf.steps + 1] = { prompt = "" }
  self.runner = nil
  self:persist()
  self:edit("prompt", #self.wf.steps, "")
end

function WorkflowView:move_step(i, dir)
  local steps = self.wf and self.wf.steps
  if not steps then return end
  local j = i + dir
  if j < 1 or j > #steps then return end
  steps[i], steps[j] = steps[j], steps[i]
  self.runner = nil
  self:persist()
end

function WorkflowView:remove_step(i)
  if not (self.wf and self.wf.steps[i]) then return end
  table.remove(self.wf.steps, i)
  self.focus, self.runner = nil, nil
  self:persist()
end

-- ---------------------------------------------------------------------------
-- Running
-- ---------------------------------------------------------------------------

-- Ask for the variables first, all of them, once. Asking per step would mean
-- the run stops in the middle to interrogate you, which is exactly the thing a
-- workflow exists to avoid.
function WorkflowView:prepare_run()
  if self.busy then return end
  if not self.wf or #self.wf.steps == 0 then
    self.notice = { text = "nothing to run -- add a step first", bad = true }
    return
  end
  local params = workflows.params(self.wf)
  if #params == 0 then return self:start({}) end
  self.form = {}
  for _, p in ipairs(params) do
    self.form[#self.form + 1] = { name = p, value = "" }
  end
  self:edit("var", 1, "")
end

-- A step's tools. No `tools:` header means no tools at all, and that default is
-- deliberate: a workflow runs several prompts without stopping to ask, so the
-- file itself has to be where you say "this step may write files". The
-- allowlist is the approval -- there is no per-call gate here as there is in
-- the chat panel, which is the honest cost of unattended execution.
local function allow_set(step)
  if not step.tools or #step.tools == 0 then return nil end
  local allow = {}
  for _, t in ipairs(step.tools) do allow[t] = true end
  return allow
end

local function err_text(e)
  if type(e) == "table" then return tostring(e.message or e.kind or "error") end
  return tostring(e)
end

function WorkflowView:start(values)
  if self.busy or not self.wf then return end
  if not (bog and bog.api) then
    self.notice = { text = "the agent harness is not available in this build",
                    bad = true }
    return
  end
  self.form = nil
  self.focus, self.buffer = nil, ""

  local wf = self.wf
  local run = { name = self.selected, started = os.time(), steps = {}, i = 0 }
  for i in ipairs(wf.steps) do
    run.steps[i] = { status = "pending", out = "", tools = {} }
  end
  -- The inputs as given, kept separately: `values` gains a key per step as the
  -- run proceeds, and "what did I actually type" should not scroll away.
  local shown = {}
  for k, v in pairs(values) do
    shown[#shown + 1] = k .. " = " .. tostring(v):gsub("%s+", " "):sub(1, 60)
  end
  table.sort(shown)
  run.inputs = table.concat(shown, "   ")
  self.runner = run
  self.busy = true
  self.notice = nil

  self.co = coroutine.create(function()
    for i, step in ipairs(wf.steps) do
      local r = run.steps[i]
      run.i = i
      r.status = "running"
      r.model = (step.model and step.model ~= "" and step.model)
                or (bog.session and bog.session.model)
      core.redraw = true

      local filled = recipes.fill(step.prompt or "", values)
      r.prompt = filled
      local allow = allow_set(step)

      -- A private session per step: fresh messages, this step's model. run_on
      -- accepts any table shaped like a session, which is what makes reusing
      -- the real turn loop free here.
      local sess = {
        model = r.model,
        messages = {},
        max_tokens = (bog.session and bog.session.max_tokens) or 16000,
      }

      local ok, msg = pcall(bog.api.run_on, sess, filled,
        function(chunk)
          r.out = r.out .. chunk
          core.redraw = true
        end,
        {
          async = true,
          tools = function()
            if not allow then return {} end
            return bog.tools.schemas_for(allow)
          end,
          on_tool = function(name, input)
            local hint = ""
            if type(input) == "table" then
              local h = input.command or input.path or input.query or input.name
              if h then hint = " " .. tostring(h):gsub("%s+", " "):sub(1, 60) end
            end
            r.tools[#r.tools + 1] = name .. hint
            core.redraw = true
          end,
          run_tool = function(name, input)
            -- The schemas were filtered already; this is the second lock, for
            -- the model that calls a tool it was never offered.
            if not (allow and bog.tools.allowed(allow, name)) then
              return "Tool error: [permission_error] this workflow step does not "
                .. "permit the " .. name .. " tool. Answer without it."
            end
            return bog.tools.run(name, input or {})
          end,
        })

      if not ok then
        r.status, r.error = "failed", err_text(msg)
        run.failed = i
        break
      end
      -- A step whose whole answer was tool calls streams no text; the message
      -- still has some, so take it from there rather than reporting nothing.
      if r.out == "" and type(msg) == "table" then
        r.out = bog.api.msg_text(msg) or ""
      end
      r.status = "done"
      values[workflows.slot(step, i)] = r.out
      values.previous = r.out
      core.redraw = true
    end
    run.done = true
    run.values = values
    self.busy = false
    core.redraw = true
  end)
end

function WorkflowView:stop()
  if not self.busy then return end
  self.co, self.busy = nil, false
  if self.runner then
    local r = self.runner.steps[self.runner.i]
    if r and r.status == "running" then r.status = "stopped" end
    self.runner.done = true
  end
  core.redraw = true
end

-- One slice per frame, and it must always return quickly. Identical in shape to
-- AgentView:tick -- the yields come from the same transport.
function WorkflowView:tick()
  if not self.co then return end
  if coroutine.status(self.co) == "dead" then self.co = nil; return end

  local ok, kind = coroutine.resume(self.co)
  if not ok then
    local r = self.runner and self.runner.steps[self.runner.i]
    if r then r.status, r.error = "failed", err_text(kind) end
    if self.runner then self.runner.done = true end
    self.co, self.busy = nil, false
    core.redraw = true
    return
  end

  if kind == "io" then
    pcall(http.pump, 0)
  elseif kind == "proc" then
    local okuv, uv = pcall(require, "uv")
    if okuv then pcall(uv.run, "nowait") end
  end
end

function WorkflowView:update()
  self:tick()
  if self.busy then core.redraw = true end
  WorkflowView.super.update(self)
end

-- ---------------------------------------------------------------------------
-- Keyboard
-- ---------------------------------------------------------------------------

function WorkflowView:on_text_input(text)
  if self.focus then
    self.buffer = self.buffer .. text
    core.redraw = true
  end
end

function WorkflowView:on_key_pressed(key)
  if key == "ctrl+return" and self.form then
    self:commit()
    local values = {}
    for _, f in ipairs(self.form) do values[f.name] = f.value end
    self:start(values)
    return true
  end

  if not self.focus then
    if key == "escape" and self.busy then self:stop(); return true end
    return false
  end

  if key == "escape" then
    self.focus, self.buffer = nil, ""
  elseif key == "shift+return" then
    -- Prompts are paragraphs. There is no second text-editing widget in this
    -- app, so the one field grows instead.
    self.buffer = self.buffer .. "\n"
  elseif key == "return" then
    self:commit()
  elseif key == "backspace" then
    self.buffer = self.buffer:sub(1, -2)
  elseif key == "tab" then
    local at = self:focus_index()
    local fields = self.fields
    self:commit()
    if at and #fields > 0 then
      local nxt = fields[(at % #fields) + 1]
      self:edit(nxt.kind, nxt.i, nxt.value)
    end
  else
    return false
  end
  core.redraw = true
  return true
end

-- ---------------------------------------------------------------------------
-- Mouse
-- ---------------------------------------------------------------------------

function WorkflowView:on_mouse_moved(x, y, dx, dy)
  WorkflowView.super.on_mouse_moved(self, x, y, dx, dy)
  self.mouse = { x = x, y = y }
  local item = widgets.hit(self.hits, x, y)
  local was = self.hover
  self.hover = item and (item.id or item.label) or nil
  if was ~= self.hover then core.redraw = true end
  self.cursor = "arrow"
end

function WorkflowView:on_mouse_pressed(button, x, y, clicks)
  if WorkflowView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  core.set_active_view(self)
  local item = widgets.hit(self.hits, x, y)
  if item then
    if item.action then item.action()
    elseif item.command then require("core.command").perform(item.command) end
  end
  return true
end

function WorkflowView:get_scrollable_size()
  return self.content_height or math.huge
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

-- Hard-wrap for the monospace font, where a column is a character. The control
-- variable of a for-in loop is read-only in Lua 5.5, hence the copy.
local function wrap(text, cols)
  local rows = {}
  for raw in (tostring(text or "") .. "\n"):gmatch("(.-)\r?\n") do
    local line = raw
    while #line > cols do
      -- Break at the last space that fits; cut mid-word only when a single
      -- word is wider than the column.
      local cut = line:sub(1, cols + 1):match("^.*()%s")
      if not cut or cut <= 1 then cut = cols + 1 end
      rows[#rows + 1] = line:sub(1, cut - 1)
      line = line:sub(cut):gsub("^%s+", "")
    end
    rows[#rows + 1] = line
  end
  if #rows > 0 and rows[#rows] == "" then table.remove(rows) end
  return rows
end

function WorkflowView:draw()
  self:draw_background(style.background)
  local font, mono = style.font, style.code_font
  local lh = font:get_height() * config.line_height
  local mlh = mono:get_height() * config.line_height
  local pad, vpad = style.padding.x, style.padding.y
  local bh = widgets.height(font)
  local charw = mono:get_width("0")
  self.hits, self.fields = {}, {}

  local function add(hit, item)
    hit.item = item
    self.hits[#self.hits + 1] = hit
    return hit
  end
  local function hovered(x, y, w, h)
    return self.mouse ~= nil
      and widgets.inside({ x = x, y = y, w = w, h = h }, self.mouse.x, self.mouse.y)
  end

  -- ---- toolbar ------------------------------------------------------------
  local top = self.position.y
  local toolbar_h = bh + vpad * 2
  renderer.draw_rect(self.position.x, top, self.size.x, toolbar_h, style.background2)
  renderer.draw_rect(self.position.x, top + toolbar_h - 1, self.size.x, 1, style.divider)
  for _, hit in ipairs(widgets.row(font, {
    -- The name prompt lives here rather than behind a command, so the view is
    -- usable on its own: opening it is the only wiring studio.lua has to do.
    { label = "New workflow", action = function()
        core.command_view:enter("New workflow name:", function(text)
          self:create(text)
        end, function() return {} end)
      end },
    { label = "Reload", action = function() self:refresh() end },
    { label = "Chat", command = "agent:open-panel" },
    { label = "Close", action = function()
        local node = core.root_view:get_primary_node()
        node:close_active_view(core.root_view.root_node)
      end },
  }, self.position.x + pad, top + vpad, self.mouse)) do
    self.hits[#self.hits + 1] = hit
  end

  local body_top = top + toolbar_h
  local bottom = self.position.y + self.size.y
  local function vis(y, h) return y + (h or lh) > body_top and y < bottom end

  -- ---- the rail: which workflows exist ------------------------------------
  local rw = math.min(RAIL, self.size.x / 3)
  renderer.draw_rect(self.position.x, body_top, rw, self.size.y - toolbar_h,
    style.background2)
  renderer.draw_rect(self.position.x + rw - 1, body_top, 1, self.size.y - toolbar_h,
    style.divider)
  local rx = self.position.x + pad * 0.5
  local ry = body_top + vpad
  common.draw_text(font, style.dim, "Workflows", "left", rx, ry, rw - pad, lh)
  ry = ry + lh
  for _, name in ipairs(self.names) do
    if ry + lh < bottom then
      local active = (name == self.selected)
      local hov = hovered(rx, ry, rw - pad, lh)
      if active or hov then
        renderer.draw_rect(rx, ry, rw - pad, lh,
          active and style.selection or style.line_highlight)
      end
      common.draw_text(font, active and style.text or style.dim, name,
        "left", rx + pad * 0.4, ry, rw - pad, lh)
      local picked = name
      add({ x = rx, y = ry, w = rw - pad, h = lh },
        { id = "wf:" .. name, action = function() self:select(picked) end })
      ry = ry + lh
    end
  end
  if #self.names == 0 then
    common.draw_text(font, style.dim, "none yet", "left", rx + pad * 0.4, ry,
      rw - pad, lh)
  end

  -- ---- the detail pane ----------------------------------------------------
  local x = self.position.x + rw + pad
  local w = self.size.x - rw - pad * 2
  local cols = math.max(20, math.floor((w - pad * 2) / charw))
  local y = body_top + vpad - self.scroll.y

  -- Only reached when the user has deleted every workflow, since a fresh view
  -- seeds one. It still has to teach: this is where the idea gets explained
  -- before there is an example to point at.
  if not self.wf then
    for _, para in ipairs({ workflows.WHAT_IT_IS, workflows.VERSUS,
                            "Press New workflow to make one." }) do
      for _, row in ipairs(wrap(para, cols)) do
        if vis(y) then common.draw_text(font, style.dim, row, "left", x, y, w, lh) end
        y = y + lh
      end
      y = y + vpad
    end
    self.content_height = (y + self.scroll.y) - self.position.y + vpad * 2
    self:draw_scrollbar()
    return
  end

  common.draw_text(style.big_font or font, style.text, self.selected,
    "left", x, y, w, lh * 1.5)
  y = y + lh * 2

  if self.wf.description ~= "" then
    for _, row in ipairs(wrap(self.wf.description, cols)) do
      if vis(y) then
        common.draw_text(mono, style.dim, row, "left", x, y, w, mlh)
      end
      y = y + mlh
    end
    y = y + vpad
  end

  -- actions for this workflow
  local actions = {
    { label = self.busy and "Stop" or "Run",
      tone = self.busy and (style.warn or style.accent) or nil,
      action = function()
        if self.busy then self:stop() else self:prepare_run() end
      end },
    { label = "Add step", action = function() self:add_step() end },
    { label = "Edit as text", action = function()
        core.root_view:open_doc(core.open_doc(workflows.path(self.selected)))
      end },
  }
  for _, hit in ipairs(widgets.row(font, actions, x, y, self.mouse)) do
    self.hits[#self.hits + 1] = hit
  end
  y = y + bh + vpad

  -- ---- the variables form -------------------------------------------------
  --
  -- Same shape as the settings screen: a labelled box per field, enter commits,
  -- tab moves on, esc cancels. One way to type into a field in this app.
  if self.form then
    if vis(y) then
      common.draw_text(font, style.accent, "Inputs", "left", x, y, w, lh)
    end
    y = y + lh
    for i, f in ipairs(self.form) do
      local editing = self.focus and self.focus.kind == "var" and self.focus.i == i
      self.fields[#self.fields + 1] = { kind = "var", i = i, value = f.value }
      if vis(y) then
        common.draw_text(mono, style.dim, "{{" .. f.name .. "}}", "left", x, y, w, mlh)
      end
      y = y + mlh
      local boxh = mlh + vpad
      if vis(y, boxh) then
        renderer.draw_rect(x, y, w, boxh, style.background2)
        local border = editing and style.accent
          or (hovered(x, y, w, boxh) and style.dim or style.divider)
        renderer.draw_rect(x, y, w, 1, border)
        renderer.draw_rect(x, y + boxh - 1, w, 1, border)
        renderer.draw_rect(x, y, 1, boxh, border)
        renderer.draw_rect(x + w - 1, y, 1, boxh, border)
        local shown = editing and (self.buffer .. "|") or f.value
        common.draw_text(mono, (shown == "" and style.dim) or style.text,
          shown == "" and "(empty)" or shown, "left", x + pad / 2, y, w - pad, boxh)
      end
      local slot = i
      add({ x = x, y = y, w = w, h = boxh },
        { id = "var" .. i, action = function() self:edit("var", slot, self.form[slot].value) end })
      y = y + boxh + vpad * 0.5
    end
    if vis(y) then
      common.draw_text(font, style.dim,
        "enter saves, tab for the next input, ctrl+enter runs",
        "left", x, y, w, lh)
    end
    y = y + lh
    local runhits = widgets.row(font, {
      { label = "Run now", action = function()
          self:commit()
          local values = {}
          for _, f in ipairs(self.form) do values[f.name] = f.value end
          self:start(values)
        end },
      { label = "Cancel", action = function()
          self.form, self.focus, self.buffer = nil, nil, ""
        end },
    }, x, y, self.mouse)
    for _, hit in ipairs(runhits) do self.hits[#self.hits + 1] = hit end
    y = y + bh + vpad
  end

  -- ---- progress banner ----------------------------------------------------
  if self.runner then
    local run = self.runner
    local text
    if run.failed then
      text = string.format("step %d failed", run.failed)
    elseif run.done then
      text = string.format("finished %d step(s)", #run.steps)
    else
      text = string.format("running step %d of %d", run.i, #run.steps)
    end
    if vis(y) then
      renderer.draw_rect(x, y, w, lh, style.background2)
      common.draw_text(font,
        run.failed and style.error or (run.done and style.good or (style.warn or style.accent)),
        "  " .. text, "left", x, y, w, lh)
    end
    y = y + lh
    if run.inputs ~= "" then
      if vis(y) then
        common.draw_text(mono, style.dim, "  " .. run.inputs, "left", x, y, w, mlh)
      end
      y = y + mlh
    end
    y = y + vpad * 0.5
  end

  -- ---- the steps ----------------------------------------------------------
  local steps = self.wf.steps
  for i, step in ipairs(steps) do
    local r = self.runner and self.runner.steps[i]
    local st = STATE[(r and r.status) or "pending"]

    -- header: number, name, state, and the reordering controls
    local head = string.format("%d. %s", i, step.name or "(unnamed)")
    if vis(y) then
      renderer.draw_rect(x, y, w, 1, style.divider)
      common.draw_text(font, style.text, head, "left", x, y + vpad * 0.5, w, lh)
      if r then
        common.draw_text(font, style[st.color] or style.dim, st.mark,
          "right", x, y + vpad * 0.5, w - pad * 7, lh)
      end
    end
    do
      local slot = i
      self.fields[#self.fields + 1] = { kind = "name", i = i, value = step.name or "" }
      add({ x = x, y = y, w = w - pad * 7, h = lh },
        { id = "name" .. i,
          action = function() self:edit("name", slot, steps[slot].name or "") end })
      local rowhits = widgets.row(font, {
        { label = "^", action = function() self:move_step(slot, -1) end, dim = i == 1 },
        { label = "v", action = function() self:move_step(slot, 1) end, dim = i == #steps },
        { label = "x", action = function() self:remove_step(slot) end },
      }, x + w - pad * 6, y, self.mouse)
      for _, hit in ipairs(rowhits) do self.hits[#self.hits + 1] = hit end
    end
    y = y + math.max(lh, bh) + vpad * 0.5

    -- model and tools, both editable in place
    do
      local slot = i
      local mlabel = "model: " .. (step.model or "(session default)")
      local editing_model = self.focus and self.focus.kind == "model" and self.focus.i == i
      if editing_model then mlabel = "model: " .. self.buffer .. "|" end
      local mw = math.min(w / 2 - pad, math.max(charw * 8, mono:get_width(mlabel) + pad))
      if vis(y) then
        common.draw_text(mono, editing_model and style.text or style.dim, mlabel,
          "left", x, y, mw, mlh)
      end
      self.fields[#self.fields + 1] = { kind = "model", i = i, value = step.model or "" }
      add({ x = x, y = y, w = mw, h = mlh },
        { id = "model" .. i,
          action = function() self:edit("model", slot, steps[slot].model or "") end })

      local tlabel = "tools: " .. ((step.tools and #step.tools > 0)
        and table.concat(step.tools, ", ") or "none")
      local editing_tools = self.focus and self.focus.kind == "tools" and self.focus.i == i
      if editing_tools then tlabel = "tools: " .. self.buffer .. "|" end
      local tx = x + w / 2
      if vis(y) then
        common.draw_text(mono, editing_tools and style.text or style.dim, tlabel,
          "left", tx, y, w / 2, mlh)
      end
      self.fields[#self.fields + 1] = { kind = "tools", i = i,
        value = (step.tools and table.concat(step.tools, ", ")) or "" }
      add({ x = tx, y = y, w = w / 2, h = mlh },
        { id = "tools" .. i, action = function()
            self:edit("tools", slot, (steps[slot].tools
              and table.concat(steps[slot].tools, ", ")) or "")
          end })
      y = y + mlh + vpad * 0.5
    end

    -- the prompt
    do
      local slot = i
      local editing = self.focus and self.focus.kind == "prompt" and self.focus.i == i
      local text = editing and (self.buffer .. "|") or (step.prompt or "")
      local rows = wrap(text ~= "" and text or "(empty -- click to write the prompt)", cols)
      local shown = math.min(#rows, editing and 40 or PROMPT_ROWS)
      local boxh = shown * mlh + vpad
      if vis(y, boxh) then
        renderer.draw_rect(x, y, w, boxh, style.background2)
        local border = editing and style.accent
          or (hovered(x, y, w, boxh) and style.dim or style.divider)
        renderer.draw_rect(x, y, w, 1, border)
        renderer.draw_rect(x, y + boxh - 1, w, 1, border)
        renderer.draw_rect(x, y, 1, boxh, border)
        renderer.draw_rect(x + w - 1, y, 1, boxh, border)
        for k = 1, shown do
          common.draw_text(mono, (step.prompt or "") == "" and style.dim or style.text,
            rows[k], "left", x + pad / 2, y + vpad / 2 + (k - 1) * mlh, w - pad, mlh)
        end
      end
      self.fields[#self.fields + 1] = { kind = "prompt", i = i, value = step.prompt or "" }
      add({ x = x, y = y, w = w, h = boxh },
        { id = "prompt" .. i,
          action = function() self:edit("prompt", slot, steps[slot].prompt or "") end })
      y = y + boxh
      if #rows > shown then
        if vis(y) then
          common.draw_text(mono, style.dim,
            string.format("... %d more line(s) -- shift+enter adds a line, Edit as text for the file",
              #rows - shown), "left", x, y, w, mlh)
        end
        y = y + mlh
      elseif editing then
        if vis(y) then
          common.draw_text(mono, style.dim,
            "enter saves, shift+enter adds a line, esc cancels",
            "left", x, y, w, mlh)
        end
        y = y + mlh
      end
      y = y + vpad * 0.5
    end

    -- what the step produced. The slot name is shown because it is what the
    -- next step has to type to read it.
    if r then
      local slotname = workflows.slot(step, i)
      if vis(y) then
        common.draw_text(mono, style[st.color] or style.dim,
          string.format("-> {{%s}} / {{previous}}   %s%s", slotname, r.status,
            r.model and ("   " .. r.model) or ""),
          "left", x, y, w, mlh)
      end
      y = y + mlh
      for _, t in ipairs(r.tools) do
        if vis(y) then
          common.draw_text(mono, style.keyword, "  >> " .. t, "left", x, y, w, mlh)
        end
        y = y + mlh
      end
      if r.error then
        for _, row in ipairs(wrap(r.error, cols)) do
          if vis(y) then
            common.draw_text(mono, style.error, row, "left", x + pad / 2, y, w, mlh)
          end
          y = y + mlh
        end
      end
      if r.out ~= "" then
        local rows = wrap(r.out, cols - 2)
        -- While a step streams, the end is the interesting part; once it is
        -- finished, the beginning is.
        local first, last = 1, #rows
        if #rows > OUTPUT_ROWS then
          if r.status == "running" then first = #rows - OUTPUT_ROWS + 1
          else last = OUTPUT_ROWS end
        end
        if first > 1 and vis(y) then
          common.draw_text(mono, style.dim, string.format("  ... %d earlier line(s)",
            first - 1), "left", x + pad / 2, y, w, mlh)
        end
        if first > 1 then y = y + mlh end
        for k = first, last do
          if vis(y) then
            renderer.draw_rect(x, y, w, mlh, style.background2)
            common.draw_text(mono, style.text, rows[k], "left", x + pad / 2, y, w - pad, mlh)
          end
          y = y + mlh
        end
        if last < #rows then
          if vis(y) then
            common.draw_text(mono, style.dim,
              string.format("  ... %d more line(s)", #rows - last),
              "left", x + pad / 2, y, w, mlh)
          end
          y = y + mlh
        end
      end
      y = y + vpad * 0.5
    end

    y = y + vpad
  end

  if #steps == 0 then
    common.draw_text(font, style.dim, "No steps yet -- press Add step.",
      "left", x, y, w, lh)
    y = y + lh
  end

  -- ---- the result ---------------------------------------------------------
  if self.runner and self.runner.done and not self.runner.failed then
    local out = self.runner.values and self.runner.values.previous or ""
    local hits = widgets.row(font, {
      { label = "Send to chat", action = function()
          -- Required lazily: core.studio requires this file, so requiring it at
          -- the top would be a cycle.
          local studio = require "core.studio"
          local v = studio.open_agent()
          v:push("system", "workflow '" .. tostring(self.runner.name) .. "' finished")
          v:push("assistant", out)
          core.set_active_view(v)
        end },
      { label = "Run again", action = function() self:prepare_run() end },
    }, x, y, self.mouse)
    for _, hit in ipairs(hits) do self.hits[#self.hits + 1] = hit end
    y = y + bh + vpad
  end

  if self.notice then
    common.draw_text(mono, self.notice.bad and style.error or style.dim,
      self.notice.text, "left", x, y, w, mlh)
    y = y + mlh
  end

  -- Where this actually lives. A builder that hides its own storage invites
  -- the belief that the workflow is trapped inside the app; it is a text file.
  y = y + vpad
  for _, row in ipairs(wrap(workflows.dir()
      .. "/  -- one text file per workflow, edit them anywhere", cols)) do
    common.draw_text(mono, style.dim, row, "left", x, y, w, mlh)
    y = y + mlh
  end

  self.content_height = (y + self.scroll.y) - self.position.y + vpad * 2
  self:draw_scrollbar()
end

return WorkflowView
