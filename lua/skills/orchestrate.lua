-- skill: orchestrate -- fan out to sub-agents and gather their results.
return {
  description = "Spawn sub-agents and await their results.",

  -- before: read-only state. Read who is already running (threads, no-arg) as
  -- CODE so the model starts knowing the live fleet instead of spending a turn
  -- to check it. Guarded so it degrades to {} with no runtime present. No
  -- short-circuit: whether to fan out is the model's call.
  before = function()
    local ok, running = pcall(function() return bog.C("threads")({}) end)
    if ok and type(running) == "string" and running ~= "" then
      return { set = { running = running } }
    end
    return {}
  end,

  instructions = function(ctx)
    local running = ctx and ctx.running
    local head = (running and running ~= "") and ("Already running (threads):\n" .. running .. "\n\n") or ""
    return head .. "For genuinely independent subtasks, `spawn` sub-agents (optionally naming a "
      .. "standard agent like researcher/coder/critic) and then `await` their ids to collect "
      .. "results, then synthesize. Delegate only when the parallelism or specialization is worth "
      .. "the overhead; otherwise just do the work yourself. Use `threads` to see who is running."
  end,
  tools = { "spawn", "await", "threads" },
}
