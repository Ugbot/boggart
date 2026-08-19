-- tui/gate.lua -- permission bar + run_tool wrap for the cTUI. Same modes and
-- messages as studio AgentView; the record and policy live in lua/perm.lua.
local perm = require("perm")

local M = {}

function M.sync(st)
  local s = perm.state()
  st.mode = s.mode
  st.approve_all = s.approve_all
  st.tool_policy = s.tool_policy
end

function M.cycle(st)
  local id, m = perm.cycle(st.mode)
  perm.set_mode(id)
  M.sync(st)
  return m
end

function M.set_mode(st, id)
  local m = perm.set_mode(id)
  M.sync(st)
  return m
end

-- Wrap bog.tools.run so a gated call parks on st.pending until y/n/a.
function M.run_tool(st)
  return perm.wrap_run(function(name, input)
    return bog.tools.run(name, input)
  end, st, {
    on_ask = function(rec)
      st.pending = rec
      st.dirty = true
    end,
    on_done = function()
      st.pending = nil
      st.dirty = true
    end,
    on_deny = function(name)
      st.entries[#st.entries + 1] = { role = "system", text = "blocked: " .. name }
      st.dirty = true
    end,
  })
end

-- Sub-agents honour the same mode. Park on the same approval bar, one at a time.
function M.install_approve(st)
  bog.approve = function(name, input, agent_id)
    if st.coord and agent_id == st.coord.id then return true end
    local policy = perm.policy_for(name, st)
    if policy == "allow" or st.approve_all then return true end
    local why = string.format("sub-agent #%s: '%s' needs approval (mode: %s)",
      tostring(agent_id), name, tostring(st.mode or "?"))
    if policy == "deny" then return false, why end
    if not coroutine.isyieldable() then return false, why end
    while st.pending and st.pending.decision == nil do
      coroutine.yield("approve")
    end
    local rec = perm.request(name, input)
    rec.agent_id = agent_id
    st.pending = rec
    st.dirty = true
    while rec.decision == nil do coroutine.yield("approve") end
    st.pending = nil
    st.dirty = true
    if rec.decision == "reject" then return false, why end
    return true
  end
end

-- Consume a key if the approval bar or Shift-Tab owns it. Returns true if eaten.
function M.key(st, ev)
  if not ev or ev.type == "paste" then return false end
  if ev.key == "tab" and ev.shift then
    local m = M.cycle(st)
    st.entries[#st.entries + 1] = {
      role = "system", text = "mode: " .. m.label .. " -- " .. m.help }
    st.dirty = true
    return true
  end
  local rec = st.pending
  if not (rec and rec.decision == nil) then return false end
  local ch = (ev.key == "char" and ev.char) or ""
  if ev.key == "enter" or ch == "y" then
    rec.decision = "approve"
    st.dirty = true
    return true
  end
  if ch == "a" then
    st.approve_all = true
    perm.state().approve_all = true
    rec.decision = "approve"
    st.dirty = true
    return true
  end
  if ev.key == "esc" or ev.key == "escape" or ch == "n" then
    rec.decision = "reject"
    st.dirty = true
    return true
  end
  return true -- swallow everything else while a destructive call is parked
end

return M
