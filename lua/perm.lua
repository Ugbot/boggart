-- perm.lua -- permission modes and approval records for every front end.
--
-- Four useful points, the same ones the studio settled on: never ask, always
-- ask, ask about writes/edits/commands, and do not use tools at all. The TUI
-- and the studio both call policy_for so a mode means the same thing on both
-- surfaces. Shift-Tab cycles; y/n/always resolve a parked ask.
local M = {}

-- Tools that change the world. Read, list and the model's own helpers are not
-- worth interrupting for under "smart".
M.GATED = { write = true, edit = true, bash = true }

M.MODES = {
  { id = "auto",   label = "Autonomous",      help = "tools run without asking" },
  { id = "smart",  label = "Smart approval",  help = "ask before writes, edits and commands" },
  { id = "manual", label = "Manual approval", help = "ask before every tool" },
  { id = "chat",   label = "Chat only",       help = "no tools at all" },
}

local BY_ID = {}
for i, m in ipairs(M.MODES) do BY_ID[m.id] = i end

-- Shared live state so /mode, Shift-Tab and policy_for agree across the TUI
-- and the studio. Front ends may keep a local copy; set_mode is the writer.
function M.state()
  if type(bog) ~= "table" then
    return { mode = "smart", approve_all = false, tool_policy = {} }
  end
  bog.perm_state = bog.perm_state or { mode = "smart", approve_all = false, tool_policy = {} }
  return bog.perm_state
end

function M.mode_at(id)
  local i = BY_ID[id or ""]
  return i and M.MODES[i] or M.MODES[2] -- smart
end

function M.cycle(id)
  local i = BY_ID[id or ""] or 2
  local n = M.MODES[(i % #M.MODES) + 1]
  return n.id, n
end

function M.set_mode(id)
  local m = M.mode_at(id)
  local st = M.state()
  if BY_ID[id or ""] then
    st.mode = m.id
    st.approve_all = false
  end
  return m, BY_ID[id or ""] ~= nil
end

-- What should happen when the model calls `name`: "allow", "ask" or "deny".
-- st may carry approve_all and tool_policy[name] = "allow"|"ask"|"deny".
function M.policy_for(name, st)
  st = st or M.state()
  local mode = st.mode or "smart"
  if mode == "chat" then return "deny" end
  local explicit = st.tool_policy and st.tool_policy[name]
  if explicit then
    return (explicit == "allow" or explicit == "ask") and explicit or "deny"
  end
  if mode == "auto" or st.approve_all then return "allow" end
  if mode == "manual" then return "ask" end
  return M.GATED[name] and "ask" or "allow"
end

-- Resolve an already-required approval without a human. An explicit profile
-- is required even when an ordinary mode would allow: guards can still ask.
-- Queue is a refusal/pending signal, not an approval or a durable queue.
function M.headless_decision(name, st)
  st = st or M.state()
  if M.policy_for(name, st) == "deny" then return "deny" end
  local hd = st.headless
  if hd == nil then hd = os.getenv("BOGGART_HEADLESS_POLICY") end
  if hd == "allow" or hd == "queue" then return hd end
  return "deny" -- missing, malformed and unknown profiles fail closed
end

-- One-line summary of a tool call, for the approval bar.
function M.summarise(name, input)
  input = input or {}
  if name == "bash" then return tostring(input.command or "") end
  if name == "write" or name == "edit" then return tostring(input.path or "(no path)") end
  local h = input.command or input.path or input.query or input.name or input.title
  return h and tostring(h) or ""
end

local function vis_w(s)
  if sys and sys.width then return sys.width(s) end
  return #(s or "")
end

-- Prefer the studio's patience differ when that module is on the path; the
-- small lua/diff.lua hunk is the TUI fallback. Same record shape either way.
local function load_differ()
  local ok, d = pcall(require, "core.diff")
  if ok and d and d.compute then return d end
  ok, d = pcall(require, "diff")
  if ok and d and d.compute then return d end
  return nil
end

-- Build the record the UI shows and the coroutine waits on. For write/edit
-- this includes a diff of what would happen, so the user can read it first.
function M.request(name, input)
  local rec = { name = name, input = input or {}, decision = nil,
                summary = M.summarise(name, input) }
  if name == "write" or name == "edit" then
    local path = input and input.path
    rec.path = path
    local diff = load_differ()
    if diff then
      local old = (path and bog and bog.util and bog.util.read_file and bog.util.read_file(path)) or ""
      local new
      if name == "write" then
        new = (input and input.content) or ""
      else
        local needle = (input and input.old) or ""
        local first = old:find(needle, 1, true)
        local second = first and old:find(needle, first + 1, true)
        if not first or second then return rec end
        new = old:sub(1, first - 1) .. ((input and input.new) or "")
            .. old:sub(first + #needle)
      end
      rec.diff = diff.compute(old, new)
      rec.summary = diff.summary and diff.summary(rec.diff, path or "(no path)") or rec.summary
    end
  end
  return rec
end

-- Styled run-lines for the approval bar (Contract B).
function M.runs(rec, width)
  width = math.max(8, math.floor(tonumber(width) or 80))
  local ACCENT, TEXT, DIM, GOOD, ERR = "e1e1e6", "97979c", "525257", "7fb77e", "f77483"
  local lines = {}
  local function add(runs) lines[#lines + 1] = runs end
  add({ { text = "approve  ", fg = ACCENT, attr = { bold = true } },
        { text = tostring(rec.name or "tool"), fg = ACCENT },
        { text = rec.path and ("  " .. rec.path) or "", fg = TEXT } })
  local sum = tostring(rec.summary or ""):gsub("\n", " ")
  if #sum > width - 2 then sum = sum:sub(1, width - 5) .. "..." end
  if sum ~= "" then add({ { text = "  " .. sum, fg = TEXT } }) end
  -- Why it is asking, when a guard or a rule (rather than the mode) is the
  -- reason. Being asked without being told why is how people learn to hit "a".
  if rec.why then add({ { text = "  why: " .. tostring(rec.why), fg = DIM } }) end
  add({ { text = "  y/enter yes   n/esc no   a always   shift-tab mode", fg = DIM } })
  if rec.diff and rec.diff.hunk and not rec.diff.unchanged then
    local n = 0
    for _, row in ipairs(rec.diff.hunk) do
      if n >= 8 then
        add({ { text = "  …", fg = DIM } })
        break
      end
      local kind, text = row[1], row[2] or ""
      local fg = (kind == "+" and GOOD) or (kind == "-" and ERR) or DIM
      local mark = (kind == " " and "  ") or (kind .. " ")
      if vis_w(mark .. text) > width then
        text = (text or ""):sub(1, math.max(0, width - 4))
      end
      add({ { text = mark .. text, fg = fg } })
      n = n + 1
    end
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- Rules: a policy engine over the mode enum
-- ---------------------------------------------------------------------------
--
-- The four modes answer "how much should it ask?" and nothing else, so the only
-- way to say "git is fine but never touch ~/.ssh" was to sit there answering
-- prompts. Rules add the missing axis -- WHICH call, not just which tool -- as
-- plain data that can be read before a run, diffed, shipped in a pack, and
-- handed to a sub-agent. The mode enum stays exactly as it was and remains the
-- default when no rule matches; nothing here removes a capability.
--
--   permissions = {
--     ["*"] = "ask",
--     bash  = { ["*"] = "ask", ["git *"] = "allow", ["sudo *"] = "deny" },
--     edit  = { ["src/**"] = "allow", ["~/.ssh/**"] = "deny" },
--     read  = { ["**/.env"] = "deny" },
--   }
--
-- Resolution, in order, with the FIRST answer winning:
--   1. an explicit runtime tool_policy entry (the "always allow" a human just
--      gave in this session)
--   2. a guard verdict (doom loop / outside the workspace / a secret file)
--   3. a rule match, last match wins within a tool's table, the tool's own
--      table beating the "*" catch-all
--   4. the mode enum, unchanged
--
-- An agent may NARROW what it inherited and never widen it: a sub-agent's rules
-- can turn allow into ask or deny, never deny into allow. That is what makes a
-- per-agent profile a safety property rather than a suggestion.
M.rules = M.rules or {}

local RANK = { allow = 1, ask = 2, deny = 3 }
local function stricter(a, b)
  if not a then return b end
  if not b then return a end
  return (RANK[a] or 0) >= (RANK[b] or 0) and a or b
end
M.stricter = stricter

-- Glob -> Lua pattern. `**` crosses separators, `*` does not, `?` is one
-- character. `~` and `$HOME` expand so a rule can name a home-relative path.
local function expand_home(s)
  local home = (sys and sys.home and sys.home()) or os.getenv("HOME") or ""
  s = s:gsub("^~", home)
  s = s:gsub("%$HOME", home)
  return s
end

-- Which tools have a PATH as their subject. It matters because `/` is a
-- separator in a path and an ordinary character in a shell command: making `*`
-- stop at a slash is what lets "src/*" mean one directory level, and is exactly
-- wrong for "sudo *", which must match "sudo rmdir /tmp/x". So segmentation is
-- a property of the subject, not of the pattern.
M.PATH_TOOLS = { read = true, write = true, edit = true, list = true }

function M.glob(pattern, subject, segmented)
  if pattern == nil or subject == nil then return false end
  if segmented == nil then segmented = true end
  pattern, subject = tostring(pattern), tostring(subject)
  if pattern == "*" or pattern == "**" then return true end
  pattern = expand_home(pattern)
  local star = segmented and "[^/]*" or ".*"
  local any = segmented and "[^/]" or "."
  local out, i, n = "^", 1, #pattern
  while i <= n do
    local c = pattern:sub(i, i)
    if c == "*" then
      if pattern:sub(i + 1, i + 1) == "*" then
        out = out .. ".*"        -- ** always crosses separators
        i = i + 2
        if pattern:sub(i, i) == "/" then i = i + 1 end
      else
        out = out .. star
        i = i + 1
      end
    elseif c == "?" then
      out = out .. any
      i = i + 1
    else
      out = out .. c:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0")
      i = i + 1
    end
  end
  return subject:match(out .. "$") ~= nil
end

-- What a rule matches against, per tool: the thing a human would name when
-- saying "not that one". Unknown tools match on a compact rendering of their
-- input so a rule can still address them.
function M.subject(name, input)
  input = input or {}
  if name == "bash" then return tostring(input.command or "") end
  local path = input.path or input.file or input.filename
  if path then return tostring(path) end
  local one = input.name or input.query or input.url or input.pattern or input.title
  return one and tostring(one) or ""
end

-- Resolve a rule table. Returns "allow"/"ask"/"deny" or nil for "no opinion".
-- Within one tool's table the LAST matching pattern wins, so a broad rule can
-- be written first and the exceptions after it, which is how everyone else's
-- config reads and therefore how people will expect this to behave.
function M.rule_for(name, input, rules)
  rules = rules or M.rules
  if type(rules) ~= "table" then return nil end
  local subject = M.subject(name, input)
  local segmented = M.PATH_TOOLS[name] or false
  local verdict
  local function scan(tbl)
    if type(tbl) == "string" then verdict = tbl; return end
    if type(tbl) ~= "table" then return end
    -- ipairs-free: rule tables are keyed by pattern, and pairs order is not
    -- stable, so "last match wins" is taken over a sorted key list to keep the
    -- answer deterministic for the same table.
    local keys = {}
    for k in pairs(tbl) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, pat in ipairs(keys) do
      local v = tbl[pat]
      if type(v) == "string" and M.glob(pat, subject, segmented) then verdict = v end
    end
  end
  scan(rules["*"])              -- the catch-all first...
  local own = rules[name]
  if own ~= nil then scan(own) end   -- ...so the tool's own table wins
  return verdict
end

-- ---- guards ---------------------------------------------------------------
--
-- Three things every peer now refuses by default and boggart did not notice at
-- all. Each is a default, not a law: a rule or an explicit tool_policy entry
-- resolves before them (see decide), so they can be turned off per project.

M.DOOM_LIMIT = 3     -- the same call this many times running is a loop
M.SECRETS = { "**/.env", "**/.env.*", "**/id_rsa", "**/id_ed25519",
              "**/.ssh/**", "**/.aws/credentials", "**/.netrc" }

local function is_path_tool(name) return M.PATH_TOOLS[name] == true end

-- Is `path` outside the workspace? Answered textually: an absolute path that is
-- not under cwd, or a relative one that climbs out of it.
function M.outside_workspace(path)
  if type(path) ~= "string" or path == "" then return false end
  path = expand_home(path)
  local cwd = (sys and sys.cwd and sys.cwd()) or "."
  if path:sub(1, 1) == "/" then
    return path:sub(1, #cwd) ~= cwd
  end
  -- count how far a relative path climbs
  local depth = 0
  for seg in path:gmatch("[^/]+") do
    if seg == ".." then depth = depth - 1
    elseif seg ~= "." then depth = depth + 1 end
    if depth < 0 then return true end
  end
  return false
end

function M.guard(name, input, st)
  st = st or M.state()
  input = input or {}
  if st.guards == false then return nil end
  local subject = M.subject(name, input)

  -- a secret, read or written, is denied unless a rule says otherwise
  if is_path_tool(name) then
    for _, pat in ipairs(M.SECRETS) do
      if M.glob(pat, subject, true) then
        return "deny", "that file holds credentials"
      end
    end
    if M.outside_workspace(subject) then
      return "ask", "outside the workspace"
    end
  end

  -- the same call, over and over: the model is stuck, and running it again is
  -- at best waste and at worst a runaway. Ask rather than deny, because a
  -- retry loop is sometimes legitimate and the human can say so.
  st.recent = st.recent or {}
  local key = name .. "\0" .. subject
  local last = st.recent[#st.recent]
  if last and last.key == key then
    last.n = last.n + 1
    if last.n >= M.DOOM_LIMIT then
      return "ask", string.format("the same %s call %d times running", name, last.n)
    end
  else
    st.recent[#st.recent + 1] = { key = key, n = 1 }
    if #st.recent > 8 then table.remove(st.recent, 1) end
  end
  return nil
end

-- The full decision for one call. Returns verdict, why.
-- policy_for stays the mode-only answer for the callers (and front ends) that
-- have a tool name but no input yet.
function M.decide(name, input, st)
  st = st or M.state()
  if st.mode == "chat" then return "deny", "chat mode does not permit tools" end
  local explicit = st.tool_policy and st.tool_policy[name]
  if explicit and explicit ~= "allow" and explicit ~= "ask" and explicit ~= "deny" then
    return "deny", "invalid tool policy"
  end

  local rule = M.rule_for(name, input, st.rules or M.rules)
  local guard, why = M.guard(name, input, st)
  -- A rule is an explicit statement about THIS call and outranks a guard's
  -- default -- except that a rule can never soften a deny into an allow when
  -- the guard found credentials, which is the one case worth being rude about.
  local verdict = stricter(rule, explicit)
  if guard and (not verdict or guard == "deny") then
    verdict = stricter(verdict, guard)
  end
  if not verdict then
    verdict = M.policy_for(name, st)
    why = nil
  end

  -- an agent narrows what it inherited, never widens it
  local agent = st.agent_rules and M.rule_for(name, input, st.agent_rules)
  if agent then verdict = stricter(verdict, agent) end
  -- Generic scopes are additional restrictions, never an alternate allow
  -- path. Descriptor/resource evaluators come from the trusted host registry.
  if st.policy ~= nil or st.policy_scopes ~= nil then
    local policy = require "policy"
    local compiled, err = st.policy
    if compiled == nil then compiled, err = policy.compile(st.policy_scopes) end
    if not compiled then return "deny", "invalid policy scopes: " .. tostring(err) end
    local descriptor = st.capabilities and st.capabilities[name]
    local decision = policy.decide(compiled, descriptor, input, st.policy_usage)
    verdict = stricter(verdict, decision.verdict)
    if #decision.reasons > 0 then why = table.concat(decision.reasons, "; ") end
  end
  return verdict, why
end

-- Load a rules table from the overlay (`<data dir>/lua/permissions.lua`) if the
-- user wrote one. Best-effort and silent when absent: an install with no file
-- behaves exactly as it did before rules existed.
function M.load_rules()
  local ok, mod = pcall(require, "permissions")
  if ok and type(mod) == "table" then
    M.rules = mod
    return mod
  end
  return nil
end

-- Wrap a run_tool so deny/ask/allow match the studio gate. on_ask receives the
-- parked record; the caller must set rec.decision (approve/reject) before the
-- yield loop returns. Used by the cTUI; AgentView keeps its own hook so it can
-- push a diff entry at the decision point.
function M.wrap_run(run, st, hooks)
  hooks=hooks or {}; st=st or M.state()
  local invoke=require("invoke")
  local function approve(name,input,why)
    if not hooks.on_ask then return false end
    local rec=M.request(name,input) or {tool=name,input=input}
    rec.why=why
    hooks.on_ask(rec)
    while rec.decision==nil do coroutine.yield("approve") end
    if hooks.on_done then hooks.on_done(rec) end
    return rec.decision=="approve"
  end
  local context=invoke.context({state=st,approve=hooks.on_ask and approve or nil},hooks.context)
  return function(name,input)
    local options
    if run and run~=require("tools").run then options={runner=run} end
    local result=invoke.string(context,name,input,options)
    if hooks.on_deny and type(result)=="string" and result:find("^Tool error: %[permission_error%]") then
      hooks.on_deny(name,input)
    end
    return result
  end
end

-- Options a turn driver passes to api.run_on so chat-mode, the approval wrap,
-- and an extra table agree across the REPL, the cTUI and the studio. extra
-- wins on any key already set (studio's custom run_tool, a coordinator's
-- tools/system). Chat mode withholds schemas unless extra.tools is already
-- a function -- denying a tool the model can still see invites retries.
function M.turn_opts(extra, hooks)
  extra = extra or {}
  local st = extra.state or M.state()
  if extra.run_tool == nil then
    extra.run_tool = M.wrap_run(bog.tools.run, st, hooks)
  end
  if st.mode == "chat" and extra.tools == nil then
    extra.tools = function() return {} end
  end
  return extra
end

return M
