-- skill: memory -- durable cross-session memory.
return {
  description = "Save and recall durable facts (FTS-backed).",
  instructions = "Save durable facts with `remember`; search them with `recall`.",
  tools = { "remember", "recall", "forget" },
}
