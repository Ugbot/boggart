-- skill: selfmod -- grow the harness at runtime.
return {
  description = "Define new tools and hot-reload the harness.",
  instructions = "Author new tools with `define_tool` (a Lua body returning a string); call "
    .. "`reload` after editing harness files under ~/.boggart/lua/.",
  tools = { "define_tool", "reload" },
}
