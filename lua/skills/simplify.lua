-- skill: simplify -- reduce complexity while preserving behavior exactly.
-- Ported from ai-grind code-simplification. Behavior preservation is checked in
-- CODE: the same tests that were green before must be green after, so "I did not
-- change behavior" is proven by verify, not asserted by the model.
local vcmd = require("verify_cmd")
return {
  description = "Simplify code without changing behavior: remove duplication, "
    .. "dead code, and needless abstraction. Use to pay down complexity on a "
    .. "working, tested area.",
  invocation = "model",
  fallback = { "core", "code_review" },
  tools = { "bash", "read", "write", "edit", "git_diff" },

  -- Load the repo conventions so the simplification respects them. Pure reads.
  before = function()
    local found = {}
    for _, name in ipairs({ "CLAUDE.md", "AGENTS.md", "CODING_STANDARDS.md" }) do
      if sys.stat and sys.stat(name) == "file" then found[#found + 1] = name end
    end
    return { set = { conventions = found, test_cmd = vcmd.detect_test() } }
  end,

  instructions = function(ctx)
    ctx = ctx or {}
    local conv = (ctx.conventions and #ctx.conventions > 0)
      and table.concat(ctx.conventions, ", ") or "(none present)"
    local tc = ctx.test_cmd and ("`" .. ctx.test_cmd .. "`") or "the project's tests"
    return [[
# Simplify without changing behavior

Conventions to respect: ]] .. conv .. [[.

1. Establish a green baseline: run ]] .. tc .. [[ and confirm it passes. If it is
   not green now, stop; simplification needs a known-good starting point.
2. Simplify in small steps: duplication to one place, dead code deleted,
   speculative generality removed, primitive obsession to a domain type. Do not
   add features or fix bugs; behavior stays identical.
3. Re-run the tests after each step. The verify below re-runs them in code and
   blocks the change if any test that should pass now fails.
]]
  end,

  -- Behavior preserved = the tests still pass. Arg-free code check.
  verify = function()
    return vcmd.green(nil)
  end,
}
