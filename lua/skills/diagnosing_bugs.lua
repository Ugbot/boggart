-- skill: diagnosing_bugs -- disciplined diagnosis loop (model-invoked).
-- Adapted from mattpocock/skills engineering/diagnosing-bugs.
return {
  description = "Hard-bug diagnosis: build a red-capable feedback loop before "
    .. "hypothesising. Use when something is broken, throwing, failing, or slow.",
  invocation = "model",
  fallback = "core",
  tools = { "read", "write", "edit", "bash", "list", "choose" },

  -- before: safe reads only. Pin the repo root, and gather the state that already
  -- exists on disk -- CONTEXT.md and any prior repro note -- so the model starts
  -- STEP 1 holding them instead of spending turns re-reading. NEVER runs a build
  -- or test here (that is the action the model decides to take). Every external
  -- call is guarded so before degrades to {} without a daemon or git present.
  before = function()
    local function sh(cmd)
      local ok, out = pcall(function() return bog.C("bash")({ command = cmd }) end)
      if ok and type(out) == "string" then return out end
      return nil
    end
    local set = {}
    local root = sh("git rev-parse --show-toplevel 2>/dev/null")
    if root then root = root:gsub("%s+$", "") end
    if root and root ~= "" and not root:find("^Tool error:") then set.root = root end
    -- Fixed docs that carry prior context/repro, read only if present.
    if sys.stat and sys.stat("CONTEXT.md") == "file" then
      set.context = sh("cat CONTEXT.md 2>/dev/null")
    end
    if sys.stat and sys.stat(".scratch/repro.md") == "file" then
      set.repro = sh("cat .scratch/repro.md 2>/dev/null")
    end
    return { set = set }
  end,

  -- verify: no arg-free code check fits here -- "is the bug fixed?" is the Step 1
  -- loop, whose command the model chose at runtime. Keep it as a model-run nudge.
  verify = { tool = "bash", nudge = "re-run the Step 1 reproduce loop on the "
    .. "original scenario and confirm it now passes (was red, now green); remove "
    .. "all [DEBUG-...] instrumentation before finishing." },

  instructions = function(ctx)
    local root = ctx and ctx.root
    local context = ctx and ctx.context
    local repro = ctx and ctx.repro
    local head = ""
    if root then head = head .. "Repo root: `" .. root .. "`.\n" end
    if context then head = head .. "\n## CONTEXT.md (already read)\n" .. context .. "\n" end
    if repro then head = head .. "\n## .scratch/repro.md (prior repro, already read)\n" .. repro .. "\n" end
    return head .. [[
# Diagnosing Bugs

Skip phases only when explicitly justified. Redact secrets (`<REDACTED>`) in any
command output you show. If `CONTEXT.md` exists, read it first.

## STEP 1 — Build a feedback loop (the skill)
Do not hypothesise until you have a tight, red-capable command you have already
run once. Prefer, in order: failing test → curl/script → CLI fixture → harness →
bisect/differential → HITL last.

Done when you can name ONE command that is:
- red-capable (asserts the user's exact symptom)
- deterministic (or high repro rate for flakes)
- fast (seconds)
- agent-runnable

Write that command (and a short note of what "red" looks like) to a file under
the project (e.g. `.scratch/repro.md` or next to the failing test). Chat is not
the deliverable.

## STEP 2 — Reproduce + minimise
Run the loop red. Shrink the repro one cut at a time until every remaining
element is load-bearing.

## STEP 3 — Hypothesise
Generate 3–5 ranked, falsifiable hypotheses. Show them with `choose` so the user
can re-rank or rule out. Format each: "If X is the cause, then Y will make the
bug disappear / worse."

## STEP 4 — Instrument
One variable at a time. Prefer debugger/REPL, then tagged logs (`[DEBUG-xxxx]`).
For perf: measure first, then bisect.

## STEP 5 — Fix + regression
If a correct seam exists: failing regression test first, then fix, then re-run
the Phase 1 loop on the original scenario. If no correct seam exists, document
that as the finding.

## STEP 6 — Cleanup
- Original loop is green
- Regression test passes (or seam absence noted)
- All `[DEBUG-…]` instrumentation removed
- Throwaway harnesses deleted or clearly marked
- State the winning hypothesis in the summary
]]
  end,
}
