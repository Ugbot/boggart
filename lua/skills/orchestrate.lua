-- skill: orchestrate -- fan out to sub-agents and gather their results.
return {
  description = "Spawn sub-agents and await their results.",
  instructions = "For genuinely independent subtasks, `spawn` sub-agents (optionally naming a "
    .. "standard agent like researcher/coder/critic) and then `await` their ids to collect "
    .. "results, then synthesize. Delegate only when the parallelism or specialization is worth "
    .. "the overhead; otherwise just do the work yourself. Use `threads` to see who is running.",
  tools = { "spawn", "await", "threads" },
}
