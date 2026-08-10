-- gold.test -- a tiny assert harness so tools (and the agent) can self-test.
-- Usage:
--   local t = gold.test.new()
--   t.eq(2+2, 4, "math"); t.ok(cond, "name")
--   local passed, failed, report = t.summary()
local M = {}

function M.new()
  local self = { passed = 0, failed = 0, failures = {} }
  function self.ok(cond, name)
    if cond then self.passed = self.passed + 1
    else self.failed = self.failed + 1; self.failures[#self.failures + 1] = name or "?" end
  end
  function self.eq(a, b, name)
    if a == b then self.passed = self.passed + 1
    else
      self.failed = self.failed + 1
      self.failures[#self.failures + 1] =
        string.format("%s (%s ~= %s)", name or "?", tostring(a), tostring(b))
    end
  end
  function self.summary()
    local report = string.format("%d passed, %d failed", self.passed, self.failed)
    if #self.failures > 0 then report = report .. "\n  - " .. table.concat(self.failures, "\n  - ") end
    return self.passed, self.failed, report
  end
  return self
end

return M
