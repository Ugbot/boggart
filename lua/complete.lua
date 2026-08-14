-- complete.lua -- the REPL command registry and the completion engine.
--
-- One source of truth for three things that used to drift: what /help prints,
-- what Tab completes, and (via a test) what handle_command is allowed to
-- dispatch. The dispatch itself still lives in boot.lua -- those handlers close
-- over REPL-local state (print_help, do_reset, the auth closures) and dragging
-- them out here would be churn for no gain -- but the *names*, the one-line
-- help, and the per-argument completers live here, so a command cannot exist in
-- one of those three places and be missing from another.
--
-- The C side (src/lterm.c) owns the isocline machinery; it calls M.complete with
-- the input up to the cursor and feeds the result to the completion menu. This
-- module is pure Lua and pure data-in/data-out: no terminal, no globals touched,
-- so tests/complete.lua exercises every branch with no tty and no model.
local M = {}

-- ---- dynamic candidate sources ---------------------------------------------
-- Each is wrapped so a failure (no store yet, a provider that will not load)
-- degrades to "no candidates" rather than throwing into the completer, which
-- runs inside a keystroke and must never raise.

local function safe(fn)
  local ok, v = pcall(fn)
  return ok and v or nil
end

local function tool_names()
  local out = {}
  local schemas = safe(function() return bog.tools.schemas() end) or {}
  for _, t in ipairs(schemas) do if t.name then out[#out + 1] = t.name end end
  table.sort(out)
  return out
end

-- Every model any known provider offers, plus whatever is running now, deduped.
-- The running model matters because a user who has switched to something the
-- provider table does not list should still see it offered back.
local function model_names()
  local seen, out = {}, {}
  local function add(m) if m and m ~= "" and not seen[m] then seen[m] = true; out[#out + 1] = m end end
  local provs = safe(function() return bog.api.providers() end) or {}
  for _, p in pairs(provs) do
    for _, m in ipairs(p.models or {}) do add(m) end
  end
  local st = safe(function() return bog.api.status() end)
  if st then add(st.model) end
  table.sort(out)
  return out
end

-- Sessions as completion items: the id is what /resume takes, the title is what
-- makes it recognisable, so the id is the completion and the title is the help.
local function session_items()
  local out = {}
  local rows = safe(function() return bog.store.sess_list(20) end) or {}
  for _, s in ipairs(rows) do
    out[#out + 1] = { text = tostring(s.id),
      display = tostring(s.id) .. "  " .. (s.title or "(untitled)"),
      help = safe(function() return os.date("%Y-%m-%d %H:%M", s.updated) end) }
  end
  return out
end

-- Overlay files under ~/.boggart/lua, which is what /reset deletes. Names only,
-- without the .lua, because that is how /reset names them.
local function overlay_names()
  local out = {}
  local dir = (bog.userdir or "") .. "/lua"
  if sys.stat(dir) == "dir" then
    for _, f in ipairs(sys.listdir(dir) or {}) do
      local n = f:match("^(.+)%.lua$")
      if n then out[#out + 1] = n end
    end
  end
  table.sort(out)
  return out
end

-- ---- the registry ----------------------------------------------------------
-- name : the command, without the slash.
-- help : one line, printed by /help and shown as completion help.
-- args : optional. Either a fixed list of tokens, or a function() returning
--        either a list of strings or a list of {text, display, help} items.
--        Called with no argument; filtering against the typed prefix happens in
--        M.complete, so a source just returns everything it knows.
M.commands = {
  { name = "help",     help = "this help" },
  { name = "tools",    help = "list tools with scope + usage; a name shows its source",
                       args = tool_names },
  { name = "auth",     help = "show or set stored credentials (key / url / model)",
                       args = { "show", "key", "url", "model", "clear" } },
  { name = "doctor",   help = "check the install: paths, store, credentials, overlays" },
  { name = "memory",   help = "list stored memories" },
  { name = "sessions", help = "list recent saved sessions" },
  { name = "resume",   help = "resume a saved session", args = session_items },
  { name = "reload",   help = "hot-reload the harness Lua" },
  { name = "reset",    help = "delete an overlay file (or all with no arg), then reload",
                       args = overlay_names },
  { name = "model",    help = "show the running model, or switch it", args = model_names },
  { name = "until",    help = "run turns until a goal is met, or the budget is spent" },
  { name = "new",      help = "start a fresh conversation (new saved session)" },
  { name = "quit",     help = "exit" },
}

-- name -> entry, built once. Alias exit->quit so both dispatch and completion
-- agree the pair exists without listing it twice in /help.
M.map = {}
for _, c in ipairs(M.commands) do M.map[c.name] = c end
M.aliases = { exit = "quit" }

-- ---- /help -----------------------------------------------------------------
-- Generated from the registry so it cannot describe a command that is gone or
-- omit one that is new. boot.lua prints this.
function M.help_text()
  local L = { "boggart commands:" }
  for _, c in ipairs(M.commands) do
    local arg = c.args and " <arg>" or ""
    L[#L + 1] = string.format("  /%-14s %s", c.name .. arg, c.help)
  end
  L[#L + 1] = "Anything else is sent to the agent. @path references a file."
  return table.concat(L, "\n") .. "\n"
end

-- ---- completion ------------------------------------------------------------
-- Keep only items whose text starts with the typed word. Forward-declared as a
-- local so the functions below can call it; a global would trip strict.lua.
local filter

-- Files under a word, used for the @file references the agent understands and
-- for path arguments. The '@' (when present) is kept on the returned text so the
-- token round-trips; a directory gets a trailing '/'. Dotfiles are hidden unless
-- the leaf being typed already starts with a dot.
local function file_items(word)
  local at = word:sub(1, 1) == "@"
  local raw = at and word:sub(2) or word
  local dir, leaf = raw:match("^(.*/)([^/]*)$")
  if not dir then dir, leaf = "", raw end
  local listdir = (dir == "" and ".") or dir
  local out = {}
  for _, f in ipairs(safe(function() return sys.listdir(listdir) end) or {}) do
    local hit = f:sub(1, #leaf) == leaf
    if hit and (leaf:sub(1, 1) == "." or f:sub(1, 1) ~= ".") then
      local full = dir .. f
      if sys.stat(full) == "dir" then full = full .. "/" end
      out[#out + 1] = { text = (at and "@" or "") .. full }
    end
  end
  return out
end

-- Normalise an args source (list or function, of strings or items) to a list of
-- {text, display?, help?} items.
local function items_of(spec)
  local raw = type(spec) == "function" and (safe(spec) or {}) or (spec or {})
  local out = {}
  for _, v in ipairs(raw) do
    if type(v) == "table" then out[#out + 1] = v
    else out[#out + 1] = { text = tostring(v) } end
  end
  return out
end

-- M.complete(prefix) -> { {text, display?, help?}, ... }
--
-- prefix is the input up to the cursor. The current *word* is the trailing run
-- of non-space characters (isocline replaces exactly that, so every returned
-- text is a full-word replacement). Context is decided from what precedes it:
-- first word -> a command (or an @file); a later word -> that command's args.
function M.complete(prefix)
  prefix = tostring(prefix or "")
  local word = prefix:match("(%S*)$") or ""
  local before = prefix:sub(1, #prefix - #word)
  local first_word = not before:find("%S")     -- nothing but space before us

  -- An @file reference is completed wherever it appears -- as a command
  -- argument, or in free prose the agent will read.
  if word:sub(1, 1) == "@" then return filter(file_items(word), word) end

  if first_word then
    -- Completing the command itself. Only offer when it looks like a command;
    -- free prose (the common case) returns nothing so Tab stays out of the way.
    if word:sub(1, 1) ~= "/" and word ~= "" then return {} end
    local out = {}
    for _, c in ipairs(M.commands) do out[#out + 1] = { text = "/" .. c.name, help = c.help } end
    return filter(out, word)
  end

  -- An argument. The command is the first token, without its slash.
  local cmd = before:match("^%s*/?(%S+)")
  local entry = cmd and (M.map[cmd] or M.map[M.aliases[cmd] or ""])
  if entry and entry.args then return filter(items_of(entry.args), word) end
  return {}
end

-- (forward-declared local above)
function filter(items, word)
  if word == "" then return items end
  local out = {}
  for _, it in ipairs(items) do
    if it.text:sub(1, #word) == word then out[#out + 1] = it end
  end
  return out
end

-- ---- highlighting ----------------------------------------------------------
-- M.style(line) -> { {pos, len, style}, ... }, the spans src/lterm.c colours as
-- the line is edited. pos is a 0-based byte offset (what isocline wants); style
-- is a named style defined in l_enable. The point of it: a leading /command is
-- coloured good when it exists and error when it does not, so a typo is visible
-- before Enter -- and @file references stand out wherever they appear.
function M.style(line)
  line = tostring(line or "")
  local spans = {}
  local cmd = line:match("^/(%S+)")
  if cmd then
    local known = M.map[cmd] or M.map[M.aliases[cmd] or ""]
    spans[#spans + 1] = { pos = 0, len = #cmd + 1, style = known and "bog-cmd" or "bog-bad" }
  end
  local init = 1
  while true do
    local s, e = line:find("@%S+", init)
    if not s then break end
    spans[#spans + 1] = { pos = s - 1, len = e - s + 1, style = "bog-file" }
    init = e + 1
  end
  return spans
end

return M
