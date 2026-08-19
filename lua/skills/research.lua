-- skill: research -- primary-source investigation → cited markdown (model-invoked).
-- Adapted from mattpocock/skills engineering/research.
return {
  description = "Investigate a question against primary sources and write cited "
    .. "findings to a Markdown file. Use when research or docs/API facts are needed.",
  invocation = "model",
  fallback = { "core", "memory" },
  tools = {
    "read", "write", "edit", "bash", "list",
    "remember", "recall", "spawn", "await",
  },
  instructions = [[
# Research

## STEP 1 — Scope
Restate the question in one sentence. Prefer primary sources: official docs,
source code, specs, first-party APIs — not secondary write-ups. Follow every
claim back to the source that owns it.

## STEP 2 — Investigate
Read and cite. When the question is large or independent of the current turn,
`spawn` a researcher sub-agent (skills: research or core+memory) and `await` it
so the coordinator can keep working. Otherwise do the reading yourself.

## STEP 3 — Write the deliverable
Save findings to ONE Markdown file where the repo already keeps notes; if none,
use something sensible (e.g. `docs/research/<slug>.md` or `.scratch/`) and say
where. Every non-obvious claim gets a citation (URL, path, or commit).

## STEP 4 — Hand back
Reply with the file path and a short abstract (≤5 bullets). Do not paste the
whole document into chat. Optionally `remember` durable project facts you found.
]],
}
