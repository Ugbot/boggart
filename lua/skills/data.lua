-- skill: data -- structured local state.
return {
  description = "Query the local SQLite DB and a key/value store.",
  -- No before/verify: every read here (a SQL query, a kv key) needs an argument
  -- the model chooses at runtime, so there is no arg-free slice to run in before.
  instructions = function()
    return "Use `sql` for structured local state and `kv` for simple key/value metadata."
  end,
  tools = { "sql", "kv" },
}
