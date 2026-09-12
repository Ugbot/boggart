-- skill: core -- files + shell.
return {
  description = "Read, write, edit files and run shell commands.",
  -- No before/verify: this is the generic file+shell capability grant with no
  -- target of its own, so there is no deterministic slice to read or check.
  instructions = function()
    return "Read files in bounded chunks; edit with a unique `old` rather than rewriting; "
      .. "don't dump large output as your answer. Use bash for builds/tests."
  end,
  tools = { "read", "write", "edit", "bash", "list" },
}
