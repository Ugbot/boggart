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

local function vis_len(s)
  s = tostring(s or "")
  if sys and sys.width then return sys.width(s) end
  local n = utf8 and utf8.len(s)
  return n or #s
end

-- Word-wrap plain text to `width` display columns.
local function wrap_plain(text, width)
  width = math.max(1, math.floor(tonumber(width) or 80))
  local rows, cur, used = {}, {}, 0
  local function flush()
    if #cur > 0 then rows[#rows + 1] = table.concat(cur); cur, used = {}, 0 end
  end
  for word in tostring(text or ""):gmatch("%S+") do
    local w = vis_len(word)
    local extra = (#cur > 0) and 1 or 0
    if used + extra + w > width and #cur > 0 then flush(); extra = 0 end
    if w > width then
      flush()
      local rest = word
      while vis_len(rest) > width do
        local head
        if sys and sys.wtake then
          head = sys.wtake(rest, width)
        else
          local off = utf8 and utf8.offset(rest, width + 1)
          head = off and rest:sub(1, off - 1) or rest:sub(1, width)
        end
        if head == "" then head = rest:sub(1, 1) end
        rows[#rows + 1] = head
        rest = rest:sub(#head + 1)
      end
      if rest ~= "" then cur[1] = rest; used = vis_len(rest) end
    else
      if extra > 0 then cur[#cur + 1] = " "; used = used + 1 end
      cur[#cur + 1] = word
      used = used + w
    end
  end
  flush()
  if #rows == 0 then rows[1] = "" end
  return rows
end

-- Styled run-lines for the cTUI. Prompt and each option wrap to `width` with a
-- hanging indent under `a) ` so lists stay enumerated instead of clipping.
function M.runs(rec, width)
  width = math.max(8, math.floor(tonumber(width) or 80))
  local ACCENT, TEXT, DIM = "e1e1e6", "97979c", "525257"
  local lines = {}
  for _, row in ipairs(wrap_plain(rec.prompt or "Choose:", width)) do
    lines[#lines + 1] = { { text = row, fg = ACCENT } }
  end
  for _, o in ipairs(rec.options or {}) do
    local prefix = "  " .. tostring(o.key) .. ") "
    local plen = vis_len(prefix)
    local inner = math.max(4, width - plen)
    local body = wrap_plain(o.label, inner)
    for i, b in ipairs(body) do
      if i == 1 then
        lines[#lines + 1] = { { text = prefix, fg = ACCENT }, { text = b, fg = TEXT } }
      else
        lines[#lines + 1] = { { text = string.rep(" ", plen) }, { text = b, fg = TEXT } }
      end
    end
  end
  if rec.allow_input then
    for _, row in ipairs(wrap_plain("  (press a letter, or type your own + Enter)", width)) do
      lines[#lines + 1] = { { text = row, fg = DIM } }
    end
  end
  return lines
end

-- Which option a typed key refers to: the option's own key, or the positional
-- a/b/c letter (so a numbered menu still answers to `a`).
function M.index_for_key(rec, k)
  if type(k) ~= "string" or k == "" then return nil end
  k = k:lower()
  for i, o in ipairs(rec.options or {}) do
    if o.key == k then return i end
  end
  if #k == 1 then
    local idx = KEYS:find(k, 1, true)
    if idx and rec.options[idx] then return idx end
  end
  return nil
end

-- Map a typed line to a decision: a lone option letter/digit picks it, else input.
function M.parse_line(rec, line)
  line = (line or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if line == "" then return { cancel = true } end
  if #line == 1 then
    local i = M.index_for_key(rec, line)
    if i then return { index = i } end
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
  local opts, used = {}, {}
  for i, o in ipairs(a.options) do
    if type(o) ~= "table" or type(o.label) ~= "string" or o.label == "" then
      return nil, "option " .. i .. " needs a string `label`"
    end
    local k = (type(o.key) == "string" and o.key ~= "" and o.key:sub(1, 1):lower()) or nil
    if not k or used[k] then
      k = nil
      for j = 1, #KEYS do
        local cand = KEYS:sub(j, j)
        if not used[cand] then k = cand; break end
      end
    end
    if not k then return nil, "too many options (max " .. #KEYS .. ")" end
    used[k] = true
    opts[i] = { key = k, label = o.label, prompt = o.prompt, run = o.run }
  end
  return { prompt = tostring(a.prompt or "Choose:"), options = opts,
           allow_input = a.input ~= false, decision = nil }
end

-- The tool body (a real function -> full access; it must be able to yield).
function M.run(a)
  local rec, err = M.build(a)
  if not rec then return "Tool error: [invalid] " .. err end

  if bog.choice_ui and coroutine.isyieldable and coroutine.isyieldable() then
    -- async front end (cTUI / studio): publish + park until it decides
    bog.choice = rec
    pcall(events.emit, "ui:choice", rec)
    local spins = 0
    while rec.decision == nil do
      spins = spins + 1
      if spins > 6000 then rec.decision = { cancel = true } end  -- ~safety, never wedge
      coroutine.yield("choose")
    end
    bog.choice = nil
  elseif type(bog.choose_ask) == "function" then
    -- synchronous front end (REPL): it prompts and returns the decision
    local ok, d = pcall(bog.choose_ask, rec)
    rec.decision = (ok and type(d) == "table") and d or { cancel = true }
  else
    -- headless / one-shot: surface the options; don't block a non-interactive run
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
  if rec and rec.decision == nil then rec.decision = decision end
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
