-- skill: verify_complete -- the completion gate. Ported from ai-grind
-- verification-before-completion. No "done/passing/fixed" claim without fresh
-- command evidence. The check runs as CODE (lua/verify_cmd.lua), so proving a
-- claim costs zero model turns and a false "it passes" cannot slip through.
local vcmd = require("verify_cmd")
return {
  description = "Gate before claiming work complete, fixed, or passing. Runs the "
    .. "project's verification command and confirms the output. Use before any "
    .. "commit, PR, or success claim.",
  invocation = "model",
  fallback = { "core" },
  tools = { "bash", "read" },

  -- Detect the command that proves the claim, so the model starts already
  -- knowing what to run. Pure read; degrades to a nudge when none is found.
  before = function()
    local cmd = vcmd.detect_test()
    return { set = { verify_cmd = cmd } }
  end,

  instructions = function(ctx)
    local cmd = ctx and ctx.verify_cmd
    local line = cmd
      and ("Detected verification command: `" .. cmd .. "`.")
      or "No standard test command detected. Identify the one that proves the claim."
    return [[
# Verification before completion

Evidence before claims, always. If you have not run the verification command in
this turn, you cannot claim it passes.

]] .. line .. [[


Before any completion claim:
1. Run the FULL command fresh. Read the whole output, check the exit code, count
   failures.
2. State the claim only with that evidence attached. No "should", "probably",
   "seems to".
3. A bug is fixed only when the original failing case now passes, not because
   the code changed.

The verify step below re-runs the command in code and blocks a false claim.
]]
  end,

  -- The gate itself, as code: green or the failure output. Arg-free, over the
  -- whole tree, so it runs cleanly in finally.
  verify = function()
    return vcmd.green()
  end,
}
