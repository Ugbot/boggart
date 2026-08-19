-- skill: tdd -- red → green test-driven development (model-invoked).
-- Adapted from mattpocock/skills engineering/tdd for boggart's skill template.
return {
  description = "Test-driven development: red→green vertical slices. Use when "
    .. "building features or fixing bugs test-first, or when the user mentions TDD.",
  invocation = "model",
  fallback = "core",
  tools = { "read", "write", "edit", "bash", "list", "choose" },
  instructions = [[
# Test-Driven Development

Work the red → green loop. Produce tests worth keeping: behaviour through public
interfaces, not implementation details.

If `CONTEXT.md` exists, read it so test names and vocabulary match the domain.

## STEP 1 — Agree seams
A seam is the public boundary you test at. List the seams under test and confirm
them with the user via `choose` (or a short numbered question). No test is written
at an unconfirmed seam.

## STEP 2 — One vertical slice
One seam, one failing test, then only enough code to pass it.
- Red before green. Do not anticipate future tests or speculative features.
- Expected values come from an independent source of truth (literal, worked
  example, or spec) — never tautological recomputation of the code under test.
- Avoid implementation-coupled tests (private methods, internal mocks, DB side
  channels). Avoid horizontal slicing (all tests then all code).

## STEP 3 — Run the suite
Use `bash` for the project's test command. Show the failing run (red), then the
passing run (green). Fix until green.

## STEP 4 — Report
Summarize: seams agreed, tests added/changed (paths), and the command that
proves green. Do not dump large output into chat.

Refactoring is NOT part of this loop — use the `code_review` skill for that.
]],
}
