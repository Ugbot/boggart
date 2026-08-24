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
  local explicit = st.tool_policy and st.tool_policy[name]
  if explicit then return explicit end
  local mode = st.mode or "smart"
  if mode == "chat" then return "deny" end
  if mode == "auto" or st.approve_all then return "allow" end
  if mode == "manual" then return "ask" end
  return M.GATED[name] and "ask" or "allow"
end

-- Headless resolution. When NO interactive approver is attached (a one-shot, a
-- swarm/CLI worker), an "ask" cannot park for a human -- so instead of running a
-- gated tool blind (the old bypass-by-default hole: swarm/CLI agents ran
-- write/edit/bash unattended), we resolve it here by policy. "allow"/"deny" from
-- policy_for are honoured as-is; an "ask" that no one can answer falls back to
-- the headless default, which is ALLOW so headless automation still works, but
-- is a SINGLE governed, auditable, overridable point: set st.headless="deny" or
-- BOGGART_HEADLESS_POLICY=deny (or perm mode chat) to withhold gated tools when
-- unattended. Returns "allow" or "deny".
function M.headless_decision(name, st)
  st = st or M.state()
  local p = M.policy_for(name, st)
  if p == "deny" then return "deny" end
  if p == "allow" then return "allow" end
  local hd = st.headless or os.getenv("BOGGART_HEADLESS_POLICY") or "allow"
  return (hd == "deny") and "deny" or "allow"
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

-- Wrap a run_tool so deny/ask/allow match the studio gate. on_ask receives the
-- parked record; the caller must set rec.decision (approve/reject) before the
-- yield loop returns. Used by the cTUI; AgentView keeps its own hook so it can
-- push a diff entry at the decision point.
function M.wrap_run(run, st, hooks)
  hooks = hooks or {}
  st = st or M.state()
  run = run or function(name, input) return bog.tools.run(name, input) end
  -- Audit a decision to the record envelope (telemetry) at the moment it is
  -- made. Only for GATED tools -- auditing every read would be noise. Stamped
  -- with the running agent + its run so a fan-out's decisions group.
  local function audit(name, policy, decision)
    if not (M.GATED[name] and bog and bog.telemetry) then return end
    local aid = bog.sched and bog.sched.current and bog.sched.current()
    local rec = aid and bog.thread and bog.thread.live_recs and bog.thread.live_recs[aid]
    pcall(bog.telemetry.decision,
      { run_id = (rec and rec.run_id) or aid, agent_id = aid },
      { tool = name, policy = policy, decision = decision })
  end
  return function(name, input)
    input = input or {}
    local policy = M.policy_for(name, st)
    local audited = false
    local function A(dec) if not audited then audited = true; audit(name, policy, dec) end end
    if policy == "deny" then
      A("deny")
      if hooks.on_deny then hooks.on_deny(name, input) end
      return "Tool error: [permission_error] the user's settings do not "
        .. "permit the " .. name .. " tool. Do not retry it; say what you "
        .. "would have done and ask."
    end
    if policy == "ask" then
      if hooks.on_ask then
        -- Interactive: park the coroutine until a front end resolves the record.
        local rec = M.request(name, input)
        if rec then
          hooks.on_ask(rec)
          while rec.decision == nil do coroutine.yield("approve") end
          if hooks.on_done then hooks.on_done(rec) end
          if rec.decision == "reject" then
            A("deny")
            return "Tool error: [permission_error] the user rejected this "
              .. name .. " call. Do not retry it; ask what to do instead."
          end
        end
      elseif M.headless_decision(name, st) == "deny" then
        A("deny")
        -- No approver attached: resolve by policy rather than run unattended.
        return "Tool error: [permission_error] the " .. name .. " tool is gated "
          .. "and no approver is attached (headless). Do not retry it; say what "
          .. "you would have done."
      end
    end
    A("allow") -- every gated call is audited exactly once, on its outcome
    return run(name, input)
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
