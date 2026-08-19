-- take.lua -- one door for a submitted composer line. The cTUI and the studio
-- both call parse() so `/commands`, `!bash` and `@file` mentions mean the same
-- thing on every surface.
local mention = require("mention")

local M = {}

function M.parse(line)
  line = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if line == "" then return { kind = "empty" } end
  if line:sub(1, 1) == "!" then
    return { kind = "bash", command = line:sub(2):gsub("^%s+", "") }
  end
  if line:match("^/%a") then
    return { kind = "slash", line = line }
  end
  local expanded, notes = mention.expand(line)
  return { kind = "prompt", text = expanded, notes = notes }
end

function M.run_bash(command)
  command = tostring(command or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if command == "" then return false, "empty command" end
  if not (bog and bog.tools and bog.tools.run) then
    return false, "bash is unavailable"
  end
  local ok, out = pcall(bog.tools.run, "bash", { command = command })
  if not ok then return false, tostring(out) end
  return true, tostring(out)
end

-- Last assistant reply in the active session, for /copy.
function M.last_assistant(sess)
  sess = sess or (bog and bog.active_session and bog.active_session())
  local msgs = sess and sess.messages or {}
  for i = #msgs, 1, -1 do
    local m = msgs[i]
    if m.role == "assistant" then
      if type(m.content) == "string" then return m.content end
      if type(m.content) == "table" then
        local parts = {}
        for _, b in ipairs(m.content) do
          if type(b) == "table" and b.type == "text" then
            parts[#parts + 1] = b.text or ""
          end
        end
        return table.concat(parts, "\n")
      end
    end
  end
  return ""
end

return M
