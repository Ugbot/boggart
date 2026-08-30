-- skill: selfmod -- grow the harness at runtime.
return {
  description = "Define new tools and hot-reload the harness; skills can carry code.",
  instructions = "Author new tools with `define_tool` (a Lua body returning a string) -- it "
    .. "registers the tool immediately, so it is callable this same session. If you instead "
    .. "`write` a tool file to a tools/ dir yourself, it is NOT live until you `reload_tools` "
    .. "(a cheap rescan of the tool dirs) or `reload` (a full harness reload, for edits to "
    .. "harness files under ~/.boggart/lua/). A skill can also CARRY its own tools: pass "
    .. "`provides` to `define_skill` (each { name, description, input_schema, body }). They "
    .. "compile through the same sandbox as define_tool and are offered to any agent granted "
    .. "the skill as skill__<skill>__<tool> -- so a skill is a code package, not just prose. "
    .. "(A tool inseparable from a way of working belongs in its skill's `provides`; a "
    .. "general-purpose helper belongs in `define_tool`.)",
  tools = { "define_tool", "reload", "reload_tools" },
  -- A baked-in skill is trusted, so a provided entry may be a real Lua function
  -- (full authority) rather than a sandboxed body string. This one is pure -- it
  -- doubles as the live example the model reads with the `skills` tool.
  provides = {
    word_count = {
      description = "Count the whitespace-separated words in args.text.",
      input_schema = { type = "object", properties = { text = { type = "string" } },
                       required = { "text" } },
      run = function(args)
        local n = 0
        for _ in tostring(args.text or ""):gmatch("%S+") do n = n + 1 end
        return tostring(n)
      end,
    },
  },
}
