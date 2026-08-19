-- skill: grilling -- design-tree interview primitive (model-invoked).
-- Adapted from mattpocock/skills productivity/grilling. Prefer `choose` for
-- enumerated branches so REPL/TUI/studio auto-capture works.
return {
  description = "Relentless design-tree interview until every branch is settled. "
    .. "Use when a plan or decision needs stress-testing.",
  invocation = "model",
  tools = { "read", "list", "bash", "choose", "spawn", "await" },
  instructions = [[
# Grilling

Map the topic as a **design tree**: every decision branches into the decisions
that hang off it. Work in **rounds**.

The **frontier** is every decision whose prerequisites are already settled —
questions you can ask now without guessing. Ask the whole frontier in one round,
then wait for answers before the next.

## STEP 1 — Open the frontier
For each frontier question:
- Prefer the `choose` tool when there are 2–8 concrete options (so the UI renders
  A/B/C). Otherwise number the questions and give your recommended answer.
- Finding facts is YOUR job: spawn a sub-agent or use tools; never ask the user
  for something you could look up. A running exploration is an unsettled
  prerequisite — ask the rest of the frontier now.

## STEP 2 — Wait and recompute
After answers, reshape the tree. Settled decisions push the frontier outward.
Questions that depend on still-open answers belong to a later round.

## STEP 3 — Close
Done when the frontier is empty: every branch visited, nothing silently assumed.
Do NOT act on the plan until the user confirms shared understanding. Summarize
the settled tree briefly (file under `.scratch/` if long).
]],
}
