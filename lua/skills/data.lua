-- skill: data -- structured local state.
return {
  description = "Query the local SQLite DB and a key/value store.",
  instructions = "Use `sql` for structured local state and `kv` for simple key/value metadata.",
  tools = { "sql", "kv" },
}
