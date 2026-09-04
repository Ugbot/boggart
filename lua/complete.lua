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

-- Skills as slash completions. Names collide with commands are skipped so /help
-- and /model stay commands; everything else is offered as /<skill>.
local function skill_items()
  local out = {}
  local rows = safe(function() return require("skills").list() end) or {}
  for _, r in ipairs(rows) do
    if r.name and not M.map[r.name] then
      out[#out + 1] = { text = "/" .. r.name, help = "skill" }
    end
  end
  table.sort(out, function(a, b) return a.text < b.text end)
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
  { name = "trust",    help = "how model-authored skill code runs (sandboxed | full)",
                       args = { "sandboxed", "full" } },
  { name = "reset",    help = "delete an overlay file (or all with no arg), then reload",
                       args = overlay_names },
  { name = "model",    help = "list models (numbered), or switch by number / name / preset", args = model_names },
  { name = "models",   help = "the model catalog: providers, which have a key, and what each role points at" },
  { name = "endpoint", help = "saved endpoint presets: list, save <name>, <name> to switch, rm <name>" },
  { name = "effort",   help = "reasoning effort: minimal|low|medium|high|xhigh|max|none (xhigh/max are Anthropic-only)" },
  { name = "agents",   help = "live fleet status: how many agents are running and what each is doing" },
  { name = "kpis",     help = "reliability scoreboard for this run: deliverable rate, tokens, think:output" },
  { name = "trace",    help = "tail the fabric bus live: /trace [pattern] to start, /trace off to stop" },
  { name = "fork",     help = "branch the active session into a new one seeded with its transcript" },
  { name = "until",    help = "run turns until a goal is met, or the budget is spent" },
  { name = "react",    help = "ReAct loop: Thought → Act → Observe until the goal is met" },
  { name = "new",      help = "start a fresh conversation (new saved session)" },
  { name = "clear",    help = "clear the conversation (same as /new, also wipes the transcript)" },
  { name = "compact",  help = "summarise the conversation to free context" },
  { name = "cost",     help = "show estimated token spend for this conversation" },
  { name = "copy",     help = "copy the last assistant reply" },
  { name = "mode",     help = "approval mode: auto | smart | manual | chat",
                       args = { "auto", "smart", "manual", "chat" } },
  { name = "dispatch", help = "optional auto-routing: hand different-enough requests to a specialist",
                       args = { "on", "off" } },
  -- common git tasks: run directly, fall back to the model on failure
  { name = "status",   help = "git status (short)" },
  { name = "diff",     help = "git diff of the working tree" },
  { name = "commit",   help = "stage all + commit (with a message, or let the model write one)" },
  { name = "push",     help = "git push; hands a rejection to the agent to resolve" },
  { name = "sync",     help = "git pull --rebase; hands conflicts to the agent" },
  { name = "quit",     help = "exit" },
  { name = "wq",       help = "save and exit; in the TUI, prints `boggart --tui --resume <id>` to reopen here" },
}

-- name -> entry, built once. Alias exit->quit so both dispatch and completion
-- agree the pair exists without listing it twice in /help.
M.map = {}
for _, c in ipairs(M.commands) do M.map[c.name] = c end
M.aliases = { exit = "quit" }

-- ---- /help -----------------------------------------------------------------
-- Generated from the registry so it cannot describe a command that is gone or
-- omit one that is new. boot.lua prints this.
-- /help, grouped.
--
-- There are forty-odd commands, and printed as one flat list they read as a
-- wall: a new user cannot tell which three they need today from the thirty they
-- will never type. The groups are the questions people actually arrive with --
-- how do I talk to it, which model, what is it allowed to do, what is it doing
-- now -- and anything not claimed by a group still appears, under "more", so a
-- command can never be added and silently vanish from the help.
M.GROUPS = {
  { title = "the conversation",
    names = { "new", "clear", "compact", "cost", "copy", "fork", "sessions", "resume" } },
  { title = "model and credentials",
    names = { "model", "models", "auth", "endpoint", "effort" } },
  { title = "what it may do",
    names = { "mode", "trust", "tools" } },
  { title = "running work",
    names = { "until", "react", "agents", "dispatch", "kpis", "trace" } },
  { title = "git",
    names = { "status", "diff", "commit", "push", "sync" } },
  { title = "the harness itself",
    names = { "reload", "reset", "memory", "doctor", "help" } },
}

function M.help_text()
  local by_name, claimed = {}, {}
  for _, c in ipairs(M.commands) do by_name[c.name] = c end

  local L = { "boggart commands:" }
  local function line(c)
    local arg = c.args and " <arg>" or ""
    L[#L + 1] = string.format("  /%-14s %s", c.name .. arg, c.help)
  end
  for _, g in ipairs(M.GROUPS) do
    local rows = {}
    for _, n in ipairs(g.names) do
      if by_name[n] then rows[#rows + 1] = by_name[n]; claimed[n] = true end
    end
    if #rows > 0 then
      L[#L + 1] = ""
      L[#L + 1] = g.title
      for _, c in ipairs(rows) do line(c) end
    end
  end
  local rest = {}
  for _, c in ipairs(M.commands) do
    if not claimed[c.name] then rest[#rest + 1] = c end
  end
  if #rest > 0 then
    L[#L + 1] = ""
    L[#L + 1] = "more"
    for _, c in ipairs(rest) do line(c) end
  end
  L[#L + 1] = ""
  L[#L + 1] = "Anything else is sent to the agent. @path references a file. /<skill> follows a named skill."
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
--
-- `@lua/comp` is path-shaped: list that directory. `@complete` has no slash, so
-- also search the tree by basename (lua/complete.lua), which is what people
-- mean by "at-symbol autocomplete".
local SKIP_WALK = {
  [".git"] = true, [".hg"] = true, [".svn"] = true, [".cache"] = true,
  node_modules = true, __pycache__ = true, CMakeFiles = true,
  vendor = true, build = true,
}
local WALK_CAP, WALK_DEPTH = 48, 8

local function expand_path(p)
  if p == "" or p == "." then return "." end
  if p == "~" then return (sys.home and sys.home()) or "." end
  if p:sub(1, 2) == "~/" then
    return ((sys.home and sys.home()) or ".") .. p:sub(2)
  end
  return p
end

local function file_items(word)
  local at = word:sub(1, 1) == "@"
  local raw = at and word:sub(2) or word
  local prefix = at and "@" or ""
  local dir, leaf = raw:match("^(.*/)([^/]*)$")
  if not dir then dir, leaf = "", raw end
  local hide_dot = leaf:sub(1, 1) ~= "."
  local out, seen = {}, {}

  local function add(rel, isdir)
    if isdir and rel:sub(-1) ~= "/" then rel = rel .. "/" end
    local text = prefix .. rel
    if seen[text] then return end
    seen[text] = true
    out[#out + 1] = { text = text, help = isdir and "dir" or "file" }
  end

  local function list_dir(typed, real, leaf_pfx)
    real = expand_path(real)
    local names = safe(function() return sys.listdir(real) end) or {}
    table.sort(names)
    for _, f in ipairs(names) do
      if f:sub(1, #leaf_pfx) == leaf_pfx and (not hide_dot or f:sub(1, 1) ~= ".") then
        local disk = (real == "." and f) or (real:gsub("/$", "") .. "/" .. f)
        add(typed .. f, sys.stat(disk) == "dir")
      end
    end
  end

  list_dir(dir, dir == "" and "." or dir, leaf)

  -- `@name` with no slash: cwd listing is not enough. Walk for a basename or
  -- relative-path prefix, skipping build/vcs trees so Tab stays snappy.
  if dir == "" and leaf ~= "" then
    local q = leaf:lower()
    local function walk(base, depth)
      if #out >= WALK_CAP or depth > WALK_DEPTH then return end
      local names = safe(function() return sys.listdir(base) end) or {}
      for _, f in ipairs(names) do
        if #out >= WALK_CAP then return end
        if not SKIP_WALK[f] and not (hide_dot and f:sub(1, 1) == ".") then
          local rel = (base == "." and f) or (base .. "/" .. f)
          local kind = sys.stat(rel)
          local fl, rl = f:lower(), rel:lower()
          if fl:sub(1, #q) == q or rl:sub(1, #q) == q then
            add(rel, kind == "dir")
          end
          if kind == "dir" then walk(rel, depth + 1) end
        end
      end
    end
    walk(".", 0)
  end

  table.sort(out, function(a, b)
    local da, db = a.text:sub(-1) == "/", b.text:sub(-1) == "/"
    if da ~= db then return da end
    if #a.text ~= #b.text then return #a.text < #b.text end
    return a.text < b.text
  end)
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
  -- argument, or in free prose the agent will read. file_items already
  -- filters (including basename search), so a second prefix filter would
  -- drop `@lua/complete.lua` when the user typed `@complete`.
  if word:sub(1, 1) == "@" then return file_items(word) end

  if first_word then
    -- Completing the command itself. Only offer when it looks like a command;
    -- free prose (the common case) returns nothing so Tab stays out of the way.
    if word:sub(1, 1) ~= "/" and word ~= "" then return {} end
    local out = {}
    for _, c in ipairs(M.commands) do out[#out + 1] = { text = "/" .. c.name, help = c.help } end
    for _, s in ipairs(skill_items()) do out[#out + 1] = s end
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
