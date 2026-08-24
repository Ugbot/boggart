-- sessionlog.lua -- event-sourced session state over the record envelope
-- (bog.store.records). A session's transcript is an append-only sequence of
-- ENTRIES; replaying a run's entries reconstructs the transcript, and FORKING
-- clones a run's entries under a new run id (a new lane) so a branch diverges
-- without duplicating anything up front. This is Phase 2's foundation: the same
-- records that carry telemetry now carry history, and the reducer that replays
-- them REJECTS an impossible sequence rather than silently repairing it -- a
-- resume is trustworthy or it fails loudly.
--
-- Additive: the existing sessions.messages blob checkpoint is unchanged; entries
-- are written alongside it. The reducer/branch machinery grows from here.
local M = {}

local function decode(s)
  if not s or s == "" then return {} end
  local ok, d = pcall(function() return bog.json.decode(s) end)
  return (ok and type(d) == "table") and d or {}
end

-- Append one transcript entry (a message) to a run's log. Order is the record
-- id (monotonic). Returns the record result.
function M.append(run_id, agent_id, role, content)
  return bog.store.record_append("entry", {
    run_id = run_id, agent_id = agent_id,
    payload = { role = role, content = content },
  })
end

-- Append a whole message array (e.g. when seeding a fork or snapshotting).
function M.append_all(run_id, agent_id, messages)
  for _, m in ipairs(messages or {}) do
    M.append(run_id, agent_id, m.role, m.content)
  end
  return #(messages or {})
end

-- Replay a run's entries into a message array, in append order. The reducer is
-- STRICT: an entry with no role (or non-table content) is corruption and is
-- refused -- returns nil, reason. A run with no entries replays to {} (a fresh
-- lane), which is valid.
function M.replay(run_id)
  local rows = bog.store.records_for(run_id) or {}
  local msgs, last_id = {}, nil
  for _, r in ipairs(rows) do
    if r.kind == "entry" then
      local p = decode(r.payload)
      if type(p.role) ~= "string" or p.role == "" then
        return nil, "corrupt entry " .. tostring(r.id) .. ": missing role"
      end
      if p.content ~= nil and type(p.content) ~= "table" and type(p.content) ~= "string" then
        return nil, "corrupt entry " .. tostring(r.id) .. ": bad content type"
      end
      -- records_for returns id-ordered rows; a non-monotonic id would mean the
      -- log was rewritten out of order -- refuse it.
      if last_id and r.id <= last_id then
        return nil, "corrupt log: entry " .. tostring(r.id) .. " out of order"
      end
      last_id = r.id
      msgs[#msgs + 1] = { role = p.role, content = p.content }
    end
  end
  return msgs
end

-- Fork: copy a run's entries under new_run_id (a new lane). The two lanes then
-- diverge as each appends its own entries. Returns the number copied, or nil,err
-- if the source log is corrupt (a fork of a broken log would inherit the break).
function M.fork(run_id, new_run_id)
  local msgs, err = M.replay(run_id)
  if not msgs then return nil, err end
  M.append_all(new_run_id, new_run_id, msgs)
  return #msgs
end

return M
