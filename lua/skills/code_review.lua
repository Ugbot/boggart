-- skill: code_review -- two-axis Standards + Spec review (model-invoked).
-- Adapted from mattpocock/skills engineering/code-review for boggart swarm.
return {
  description = "Two-axis review (Standards + Spec) of the diff since a fixed "
    .. "point, via parallel sub-agents. Use when reviewing a branch, PR, or WIP.",
  invocation = "model",
  fallback = { "core", "orchestrate" },
  tools = {
    "read", "write", "edit", "bash", "list", "choose",
    "git_diff", "spawn", "await", "threads",
  },
  instructions = [[
# Code Review (two axes)

Review `git diff <fixed-point>...HEAD` along two axes, separately:

- **Standards** — does the code follow this repo's documented standards + the
  Fowler smell baseline below?
- **Spec** — does it faithfully implement the originating issue/spec?

## STEP 1 — Pin the fixed point
If the user did not name one, ask with `choose` (e.g. main / HEAD~5 / custom).
Confirm `git rev-parse` and a non-empty three-dot diff. Fail here on a bad ref
or empty diff — do not spawn reviewers yet.

## STEP 2 — Spec source
Find the originating spec, in order: issue refs in commit messages → path the
user gave → `docs/` / `specs/` / `.scratch/` matching the branch → ask the user.
If none, Spec axis reports "no spec available".

## STEP 3 — Standards sources
Collect `CODING_STANDARDS.md`, `CONTRIBUTING.md`, AGENTS.md/CLAUDE.md, and any
project instructions. Repo docs override the smell baseline. Smells are always
judgement calls; skip anything tooling already enforces.

Smell baseline (what → fix): Mysterious Name → rename; Duplicated Code → extract;
Feature Envy → move to the data; Data Clumps → bundle a type; Primitive Obsession
→ domain type; Repeated Switches → polymorphism/map; Shotgun Surgery → gather;
Divergent Change → split; Speculative Generality → delete; Message Chains → hide
behind one method; Middle Man → cut; Refused Bequest → composition.

## STEP 4 — Spawn parallel reviewers
`spawn` two sub-agents (skills: core) with disjoint briefs — Standards gets the
diff + standards paths + smell baseline; Spec gets the diff + spec contents.
Await both. Cap each report under ~400 words.

## STEP 5 — Aggregate to a file
Write `## Standards` and `## Spec` (verbatim or lightly cleaned — do NOT merge
or re-rank across axes) to a review file (e.g. `.scratch/review-<date>.md`).
End with findings-per-axis and the worst issue within each axis. Reply with the
path and a one-line summary only.
]],
}
