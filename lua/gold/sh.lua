-- gold.sh -- convenience wrappers over sys.exec for the common cases.
local M = {}

-- Full result table {out, code, timed_out, truncated}.
function M.run(cmd, timeout) return sys.exec(cmd, timeout or 120) end

-- true iff the command exited 0.
function M.ok(cmd, timeout) return sys.exec(cmd, timeout or 120).code == 0 end

-- trimmed stdout+stderr (ignores exit code).
function M.out(cmd, timeout)
  return (sys.exec(cmd, timeout or 120).out or ""):gsub("%s+$", "")
end

-- stdout+stderr, exit code   (two returns)
function M.capture(cmd, timeout)
  local r = sys.exec(cmd, timeout or 120)
  return r.out or "", r.code
end

return M
