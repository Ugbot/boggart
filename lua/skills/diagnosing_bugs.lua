-- skill: diagnosing_bugs -- disciplined diagnosis loop (model-invoked).
-- Adapted from mattpocock/skills engineering/diagnosing-bugs.
return {
  description = "Hard-bug diagnosis: build a red-capable feedback loop before "
    .. "hypothesising. Use when something is broken, throwing, failing, or slow.",
  invocation = "model",
  fallback = "core",
  tools = { "read", "write", "edit", "bash", "list", "choose" },
  instructions = [[
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
]],
}
