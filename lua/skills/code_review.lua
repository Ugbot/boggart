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
  -- before: the deterministic setup, run as CODE (docs/callables.md). Pins the
  -- fixed point, fails fast on an empty diff (zero model turns), and collects
  -- the standards docs that are actually present. Threads ref/diff/standards
  -- into the turn, so the model starts STEP 4 already knowing them.
  before = function(ctx)
    local args = (type(ctx.args) == "table" and ctx.args) or {}
    local ref = args.ref or "HEAD"
    local diff = bog.C("git_diff")({ ref = ref })
    if type(diff) == "string" and diff:find("^Tool error:") then
      return { done = "code_review: cannot diff against '" .. ref .. "': " .. diff }
    end
    if diff == "(no differences)" or diff == "" then
      return { done = "nothing to review: the diff against '" .. ref .. "' is empty" }
    end
    -- Standards sources that exist here, checked with code not a tool call.
    local found = {}
    for _, name in ipairs({ "CODING_STANDARDS.md", "CONTRIBUTING.md",
                            "AGENTS.md", "CLAUDE.md" }) do
      if sys.stat and sys.stat(name) == "file" then found[#found + 1] = name end
    end
    return { set = { ref = ref, diff = diff, standards = found } }
  end,

  instructions = function(ctx)
    local ref = (ctx and ctx.ref) or "HEAD"
    local standards = (ctx and ctx.standards) or {}
    local slist = #standards > 0 and table.concat(standards, ", ") or "(none present)"
    return [[
# Code Review (two axes)

The diff against `]] .. ref .. [[` is already pinned and non-empty (setup ran
in code). Standards docs found in this repo: ]] .. slist .. [[.

Review it along two axes, separately:

- **Standards** — does the code follow this repo's documented standards + the
  Fowler smell baseline below?
- **Spec** — does it faithfully implement the originating issue/spec?

## STEP 1 — Spec source
Find the originating spec, in order: issue refs in commit messages → path the
user gave → `docs/` / `specs/` / `.scratch/` matching the branch → ask the user.
If none, Spec axis reports "no spec available".

Smell baseline (what → fix): Mysterious Name → rename; Duplicated Code → extract;
Feature Envy → move to the data; Data Clumps → bundle a type; Primitive Obsession
→ domain type; Repeated Switches → polymorphism/map; Shotgun Surgery → gather;
Divergent Change → split; Speculative Generality → delete; Message Chains → hide
behind one method; Middle Man → cut; Refused Bequest → composition. Repo docs
override the baseline; skip anything tooling already enforces.

## STEP 2 — Spawn parallel reviewers
`spawn` two sub-agents (skills: core) with disjoint briefs — Standards gets the
diff + the standards docs above + the smell baseline; Spec gets the diff + spec
contents. Await both. Cap each report under ~400 words.

## STEP 3 — Aggregate to a file
Write `## Standards` and `## Spec` (verbatim or lightly cleaned — do NOT merge
or re-rank across axes) to a review file (e.g. `.scratch/review-<date>.md`).
End with findings-per-axis and the worst issue within each axis. Reply with the
path and a one-line summary only.
]]
  end,
}
