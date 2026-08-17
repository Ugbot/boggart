# Authoring skills and tools — the canonical template

A **tool** is one capability (a name, a schema, a Lua body). A **skill** is a
*way of working*: instructions plus the tools an agent following it may use, and
optionally its own tools. This file is the template both conform to. `define_tool`,
`define_skill` and `import_skill` produce this shape; the golden skills match it.

The three patterns that make a skill trustworthy, in one line each:

1. **Verify** — a skill with a checkable outcome names the tool that checks it
   (`verify`), and boggart makes the agent run it before finishing.
2. **Single source** — the rules live in ONE place (a Lua module, or `data.put`
   once); the instructions and the checker both read them, so they never drift.
3. **Compose** — `instructions` may be a function that pulls in only the bits it
   needs, rather than one monolith.

---

## Tool template (`define_tool`)

```lua
{
  name = "verb_noun",            -- [A-Za-z_][A-Za-z0-9_]*, imperative, unambiguous
  description =                  -- WHAT it does · WHEN to reach for it · args · returns.
    "One or two sentences. Say what it returns and when to use it over alternatives.",
  input_schema = {              -- JSON Schema; every field described; `required` listed
    type = "object",
    properties = { path = { type = "string", description = "absolute path to …" } },
    required = { "path" },
  },
  body = [=[                     -- runs SANDBOXED: no require/load/io/package
    -- receives `args`; MUST return a string. Globals: sys, json, gold, db,
    -- data (data.put/get), tools (tools.call/names), events, os (time/getenv),
    -- string/table/math/utf8. Signal failure by returning "Tool error: [kind] …".
    if type(args.path) ~= "string" then return "Tool error: [invalid] need 'path'" end
    local text = gold.fs.read(args.path)
    if not text then return "Tool error: [not_found] " .. args.path end
    return "…result…"
  ]=],
}
```

Body rules: absolute paths (a bare/`~` path lands in the process cwd); small,
composable output (don't dump — write files and summarize); `return "Tool error:
[kind] message"` on failure so the caller can branch.

---

## Skill template (`define_skill` / a `lua/skills/<name>.lua` file)

```lua
return {
  -- WHAT this way of working is · WHEN an agent should adopt it. One line.
  description = "Draft a chapter to the manuscript in the book's voice, self-checked.",

  -- The way of working. A STRING, or a function() that composes text at resolve
  -- time (so it can pull only the bits it needs from a single source).
  instructions = function()
    local rules = require("style").pull{ "sentence_dna", "ban_list" }  -- single source
    require("style").export()                                          -- publish for the checker
    return [[
## STEP 1 — <do the work>            (numbered steps; each an action)
## STEP 2 — SAVE to a file           (the deliverable is a file, never the chat)
## STEP 3 — self-check + fix
]] .. "\n\n# Rules (pulled from the guide)\n\n" .. rules
  end,

  tools = { "read", "write", "edit", "save_chapter", "check_prose_style" },  -- allow-list

  -- The skill's OWN tools (a skill is code, not just prose). Keyed by name; each
  -- is a tool per the tool template above. Offered as skill__<skill>__<tool>.
  provides = {
    check_prose_style = { description = "…", input_schema = {…}, body = [[ … ]] },
  },

  -- FIRST-CLASS verification: the tool (usually one you provide) that checks the
  -- outcome. boggart appends "run it and fix what it flags before you finish".
  verify = "check_prose_style",

  -- Optional: backup skills whose tools are also granted if a preferred one is
  -- absent (an MCP server down, a binary missing).
  fallback = { "core" },
}
```

### Conformance checklist

- **description**: what **and when** (an agent picks a skill by this line).
- **instructions**: numbered STEPS, each an action; if it produces a deliverable,
  one step **writes it to a file** (absolute path), not the chat.
- **verify**: present iff the skill has a checkable outcome, naming a real tool
  it provides or grants. Pure-capability skills (read files, send mail) omit it.
- **single source**: no rule hardcoded in two places. If a checker enforces a
  number/list the instructions also state, both read it from one module or
  `data.get`, not two literals. (See `~/.boggart/lua/style.lua` for the reference.)
- **provides**: bodies obey the tool template (sandboxed, absolute paths,
  "Tool error:" on failure).

`skills.lint(name)` reports where a skill misses this checklist.
