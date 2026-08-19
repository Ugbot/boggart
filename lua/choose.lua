-- choose.lua -- an interactive A/B/C/D (+ free input) menu the agent can raise
-- mid-turn, resolved by whichever front end is live (cTUI, studio, or the REPL).
--
-- The agent calls the `choose` tool. It PARKS the turn (like the approval gate)
-- until the user picks a letter or types their own answer, then RESOLVES the
-- outcome and returns it to the agent, which continues the same turn:
--   * a `prompt` option  -> the option's text is handed back (a prompt outcome)
--   * a `run` option     -> code runs and its result is handed back:
--        run = { tool = "bash", args = {…} }   a boggart tool
--        run = { lua  = "return …" }            sandboxed Lua (gets `args`)
--        run = { cmd  = "/agents" }             a slash command
--   * free input         -> the typed text is handed back
--
-- Prose auto-capture: when the assistant ends a turn with a question and an
-- enumerated list (a)/1./- bullets), the same menu is offered AFTER the turn so
-- REPL, cTUI, and studio render proper choice UX without the model calling the
-- tool. See detect(), capture_from_session(), present_after_turn().
--
-- Front ends cooperate through shared state, exactly like bog.approvals:
--   bog.choice      -- the pending record the UI renders (nil when none)
--   bog.choice_ui   -- truthy when an ASYNC chooser (cTUI/studio) is live -> park
--   bog.choose_ask  -- a SYNC resolver a REPL registers: fn(rec) -> decision
-- A decision is { index = i } | { text = "…" } | { cancel = true }.
local events = require("events")

local M = {}
local KEYS = "abcdefghijklmnopqrstuvwxyz"

-- Render the menu as plain text -- the REPL prompt, and the headless fallback.
function M.render(rec)
  local t = { rec.prompt }
  for _, o in ipairs(rec.options) do t[#t + 1] = "  " .. o.key .. ") " .. o.label end
  if rec.allow_input then t[#t + 1] = "  (or type your own answer)" end
  return table.concat(t, "\n")
end

-- Map a typed line to a decision: a lone option letter picks it, else it's input.
function M.parse_line(rec, line)
  line = (line or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if line == "" then return { cancel = true } end
  if #line == 1 then
    local k = line:lower()
    for i, o in ipairs(rec.options) do if o.key == k then return { index = i } end end
  end
  return { text = line }
end

-- Run a picked option's outcome, returning the string handed back to the agent.
local function resolve(o)
  local head = "[you chose " .. o.key .. ") " .. o.label .. "]"
  local r = o.run
  if type(r) ~= "table" then                     -- a prompt option (or bare label)
    return head .. (type(o.prompt) == "string" and ("\n" .. o.prompt) or "")
  end
  if type(r.tool) == "string" then
    local ok, out = pcall(function() return bog.tools.run(r.tool, r.args or {}) end)
    return head .. "\n" .. (ok and tostring(out) or ("tool error: " .. tostring(out)))
  elseif type(r.lua) == "string" then
    local T = require("tools")
    local env = T.tool_env(); env.args = r.args or {}
    local chunk, err = load(r.lua, "choose:lua", "t", env)
    if not chunk then return head .. "\nlua compile error: " .. tostring(err) end
    local ok, out = pcall(chunk)
    return head .. "\n" .. (ok and tostring(out) or ("lua error: " .. tostring(out)))
  elseif type(r.cmd) == "string" then
    if bog and bog.handle_command then pcall(bog.handle_command, r.cmd) end
    return head .. "\nran " .. r.cmd
  end
  return head
end

-- Normalise + validate the tool's arguments into a record.
function M.build(a)
  if type(a.options) ~= "table" or #a.options == 0 then
    return nil, "choose needs a non-empty `options` array of { label, prompt|run }"
  end
  local opts = {}
  for i, o in ipairs(a.options) do
    if type(o) ~= "table" or type(o.label) ~= "string" or o.label == "" then
      return nil, "option " .. i .. " needs a string `label`"
    end
    opts[i] = {
      key = (type(o.key) == "string" and o.key ~= "" and o.key:sub(1, 1):lower())
        or KEYS:sub(i, i),
      label = o.label, prompt = o.prompt, run = o.run,
    }
  end
  return { prompt = tostring(a.prompt or "Choose:"), options = opts,
           allow_input = a.input ~= false, decision = nil }
end

-- ---- prose detection (auto-capture enumerated questions) -------------------

local function trim(s)
  return (tostring(s or "")):gsub("^%s+", ""):gsub("%s+$", "")
end

local function is_hint_line(line)
  local l = line:lower()
  if l:match("^%(") and (l:match("type") or l:match("enter") or l:match("press")) then
    return true
  end
  return l:match("^please pick") or l:match("^pick one") or l:match("^choose one")
end

local function parse_option_line(line)
  line = trim(line)
  if line == "" or is_hint_line(line) then return nil end
  local key, label = line:match("^([a-z])%)[%s:]+(.+)$")
  if key and label then return trim(label), key:lower() end
  key, label = line:match("^([a-z])%.[%s:]+(.+)$")
  if key and label then return trim(label), key:lower() end
  key, label = line:match("^(%d+)%)[%s:]+(.+)$")
  if key and label then return trim(label), key end
  key, label = line:match("^(%d+)%.[%s:]+(.+)$")
  if key and label then return trim(label), key end
  label = line:match("^[-*•][%s:]+(.+)$")
  if label then return trim(label), nil end
  return nil
end

local function lines_outside_fences(text)
  local lines, in_fence = {}, false
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line:match("^%s*```") then
      in_fence = not in_fence
    elseif not in_fence then
      lines[#lines + 1] = line
    end
  end
  return lines
end

-- detect(text) -> { prompt, options = { { label, key? } }, input = true } | nil
-- Finds a trailing enumerated list (2-8 items) at the end of assistant prose.
function M.detect(text)
  if type(text) ~= "string" or not text:match("%S") then return nil end
  local lines = lines_outside_fences(text)
  if #lines == 0 then return nil end

  -- Walk up from the bottom, skipping trailing blanks and hint lines.
  local i = #lines
  while i >= 1 and (lines[i]:match("^%s*$") or is_hint_line(lines[i])) do i = i - 1 end
  if i < 1 then return nil end

  local opt_lo, opt_hi = i, i
  while opt_lo >= 1 do
    local line = lines[opt_lo]
    if line:match("^%s*$") then break end
    local label = parse_option_line(line)
    if not label then break end
    if #label > 240 then return nil end
    opt_lo = opt_lo - 1
  end
  opt_lo = opt_lo + 1

  local nopt = opt_hi - opt_lo + 1
  if nopt < 2 or nopt > 8 then return nil end

  local options = {}
  for n = opt_lo, opt_hi do
    local label, key = parse_option_line(lines[n])
    options[#options + 1] = { label = label, key = key, prompt = label }
  end

  -- Skip the blank line(s) between the question and the option list, then
  -- collect contiguous non-option prose above as the prompt.
  local j = opt_lo - 1
  while j >= 1 and lines[j]:match("^%s*$") do j = j - 1 end
  local prompt_lines = {}
  while j >= 1 do
    local line = lines[j]
    if line:match("^%s*$") then break end
    if parse_option_line(line) then break end
    prompt_lines[#prompt_lines + 1] = trim(line)
    j = j - 1
  end
  for k = 1, math.floor(#prompt_lines / 2) do
    local a, b = k, #prompt_lines - k + 1
    prompt_lines[a], prompt_lines[b] = prompt_lines[b], prompt_lines[a]
  end
  local prompt = trim(table.concat(prompt_lines, " "))
  if prompt == "" then prompt = "Choose:" end

  return { prompt = prompt, options = options, input = true }
end

-- ---- session helpers -------------------------------------------------------

function M.message_text(m)
  if type(m) ~= "table" then return "" end
  if type(m.content) == "string" then return m.content end
  if type(m.content) ~= "table" then return "" end
  local parts = {}
  for _, b in ipairs(m.content) do
    if type(b) == "table" and b.type == "text" and type(b.text) == "string" then
      parts[#parts + 1] = b.text
    end
  end
  return table.concat(parts, "\n")
end

function M.last_assistant_text(sess)
  if type(sess) ~= "table" or type(sess.messages) ~= "table" then return nil end
  for idx = #sess.messages, 1, -1 do
    local m = sess.messages[idx]
    if m.role == "assistant" then
      local t = M.message_text(m)
      return t:match("%S") and t or nil
    end
    if m.role == "user" then return nil end
  end
  return nil
end

function M.turn_used_choose(sess)
  if type(sess) ~= "table" or type(sess.messages) ~= "table" then return false end
  for idx = #sess.messages, 1, -1 do
    local m = sess.messages[idx]
    if m.role == "user" then break end
    if m.role == "assistant" and type(m.content) == "table" then
      for _, b in ipairs(m.content) do
        if b.type == "tool_use" and b.name == "choose" then return true end
      end
    end
  end
  return false
end

function M.format_user_reply(rec, decision)
  decision = decision or {}
  if decision.cancel then return nil end
  if type(decision.text) == "string" and decision.text ~= "" then return decision.text end
  local o = rec.options and rec.options[decision.index]
  if not o then return nil end
  return o.label
end

-- capture_from_session(sess) -> rec | nil
function M.capture_from_session(sess)
  if bog and bog.choice then return nil end
  if M.turn_used_choose(sess) then return nil end
  local text = M.last_assistant_text(sess)
  if not text then return nil end
  local args = M.detect(text)
  if not args then return nil end
  local rec, err = M.build(args)
  if not rec then return nil end
  rec.captured = true
  return rec
end

-- Park until the user decides (mid-turn tool path).
local function wait_for_decision(rec)
  if bog.choice_ui and coroutine.isyieldable and coroutine.isyieldable() then
    bog.choice = rec
    pcall(events.emit, "ui:choice", rec)
    local spins = 0
    while rec.decision == nil do
      spins = spins + 1
      if spins > 6000 then rec.decision = { cancel = true } end
      coroutine.yield("choose")
    end
    bog.choice = nil
    return true
  elseif type(bog.choose_ask) == "function" then
    local ok, d = pcall(bog.choose_ask, rec)
    rec.decision = (ok and type(d) == "table") and d or { cancel = true }
    return true
  end
  return false
end

-- present_after_turn(rec, on_decide) -- async UI after a turn completes.
function M.present_after_turn(rec, on_decide)
  if not rec then return end
  rec.on_decide = on_decide
  rec.after_turn = true
  rec.decision = nil
  bog.choice = rec
  pcall(events.emit, "ui:choice", rec)
end

-- capture_after_turn(sess) -> reply text for the next user message, or nil.
function M.capture_after_turn(sess)
  local rec = M.capture_from_session(sess)
  if not rec then return nil end
  if not wait_for_decision(rec) then
    io.write(M.render(rec), "\n(no interactive chooser here -- options shown for reference)\n")
    return nil
  end
  return M.format_user_reply(rec, rec.decision)
end

-- The tool body (a real function -> full access; it must be able to yield).
function M.run(a)
  local rec, err = M.build(a)
  if not rec then return "Tool error: [invalid] " .. err end

  if not wait_for_decision(rec) then
    return M.render(rec) .. "\n(no interactive chooser here -- options shown for reference)"
  end

  local d = rec.decision or {}
  if d.cancel then return "The user dismissed the menu without choosing." end
  if type(d.text) == "string" and d.text ~= "" then
    return "The user typed instead of picking a listed option: " .. d.text
  end
  local o = rec.options[d.index]
  if not o then return "No choice was made." end
  return resolve(o)
end

-- Set a decision from a front end (used by the cTUI / studio key handlers).
function M.decide(rec, decision)
  if not rec or rec.decision ~= nil then return end
  rec.decision = decision
  if type(rec.on_decide) == "function" then
    local cb = rec.on_decide
    rec.on_decide = nil
    bog.choice = nil
    pcall(cb, decision, rec)
  end
end

-- The tool definition, registered by lua/tools.lua.
M.def = {
  description = "Ask the user to pick from a small A/B/C/D menu (or type their own answer), "
    .. "and get their choice back so you continue THIS turn on it. Use it when the next step "
    .. "is genuinely the user's call. `options` is an array of { label, and ONE of: `prompt` "
    .. "(text handed back so you act on it) or `run` (code whose result is handed back): "
    .. "run = { tool=<name>, args={…} } | { lua=\"return …\" } | { cmd=\"/slash\" } }. Free "
    .. "input is allowed unless input=false. Renders in the cTUI, the studio, and the REPL.",
  input_schema = {
    type = "object",
    properties = {
      prompt = { type = "string", description = "the question shown above the options" },
      input = { type = "boolean", description = "allow a free-text answer too (default true)" },
      options = {
        type = "array", description = "2-8 choices",
        items = { type = "object", properties = {
          label = { type = "string", description = "shown next to the letter" },
          key = { type = "string", description = "override the a/b/c letter" },
          prompt = { type = "string", description = "prompt outcome: handed back to you" },
          run = { type = "object", description = "programmatic outcome: { tool,args } | { lua } | { cmd }" },
        }, required = { "label" } },
      },
    },
    required = { "options" },
  },
  run = M.run,
}

return M
