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
  -- before: read-only state. Probe durable memory for what we already know about
  -- the question, so the model does not spend a `recall` turn to find prior
  -- findings. Only probes when a question/topic was passed; guarded so it
  -- degrades to {} without a store present. No short-circuit: research is work
  -- the model does even when memory is empty.
  before = function(ctx)
    local args = (ctx and type(ctx.args) == "table" and ctx.args) or {}
    local q = args.question or args.query or args.topic or args.task
    if type(q) ~= "string" or q == "" then return {} end
    local ok, prior = pcall(function() return bog.C("recall")({ query = q }) end)
    if ok and type(prior) == "string" and prior ~= "" and not prior:find("^%(no ") then
      return { set = { prior = prior } }
    end
    return {}
  end,

  instructions = function(ctx)
    local prior = ctx and ctx.prior
    local head = prior and ("## Prior findings recalled from memory\n" .. prior
      .. "\n\n(Build on these; do not re-derive what is already known.)\n\n") or ""
    return head .. [[
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
]]
  end,
}
