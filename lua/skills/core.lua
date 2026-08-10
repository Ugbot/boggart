-- skill: core -- files + shell.
return {
  description = "Read, write, edit files and run shell commands.",
  instructions = "Read files in bounded chunks; edit with a unique `old` rather than rewriting; "
    .. "don't dump large output as your answer. Use bash for builds/tests.",
  tools = { "read", "write", "edit", "bash", "list" },
}
