-- Explicit batch boundary: feeding never calls Lua or subscribers.
local bus = require "bus"
local json = require "json"
local M = {}
function M.drain(term, pane_id)
  assert((math.type(pane_id) == "integer" and pane_id > 0)
    or (type(pane_id) == "string" and #pane_id > 0 and #pane_id <= 256 and not pane_id:find("%z")),
    "trusted pane identity required")
  local events, dropped = term:events()
  local published = 0
  for _, event in ipairs(events) do
    local allowed = true
    if event.type == "clipboard" then
      -- Earlier subscribers may revoke permission or close this terminal.
      local ok, policy = pcall(term.clipboard_policy, term)
      allowed = ok and policy.generation == event.clipboard_generation
        and (event.query and policy.read or not event.query and policy.write)
    end
    if allowed then
      event.pane_id = pane_id
      bus.publish("terminal." .. event.type, json.encode(event))
      published = published + 1
    end
  end
  return published, dropped
end
return M
