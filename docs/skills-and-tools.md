# Authoring skills and tools — the canonical template

A **tool** is one capability (a name, a schema, a Lua body). A **skill** is a
*way of working*: instructions plus the tools an agent following it may use, and
optionally its own tools. This file is the template both conform to. `define_tool`,
`define_skill` and `import_skill` produce this shape; the golden skills match it.

The three patterns that make a skill trustworthy, in one line each:

1. **Verify** — a skill with a checkable outcome names the tool that checks it
   (`verify`), and boggart makes the agent run it before finishing.
2. **Single source** — the rules live in ONE place (a trusted Lua module, or a
   registered data capability); the instructions and checker both read them,
   so they never drift.
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
    -- receives `args`; MUST return a string. Facades: mediated sys functions,
    -- gold.re, gold.fs.read/write/glob, json, tools.call/names, events.notify,
    -- safe os time/getenv, and copied string/table/math/utf8 libraries.
    -- db, data, other gold facets and the raw registry are unavailable.
    -- Signal failure by returning "Tool error: [kind] …".
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

Sandboxed bodies have instruction and memory budgets. Nested tool calls share
the active count-hook authority instead of replacing it, and coroutines created
through the sandbox inherit that hook. The instruction counter measures Lua
execution only: native or blocking host calls need their own timeout. Trusted
built-ins and code enabled by `/trust full` execute at the host boundary without
the generated-body budget.

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

A string `verify` is still an instruction for the model to run the named tool.
For builtin Lua skills, a function-valued `verify` is a lifecycle verifier: only
`true` passes; false/nil/string returns and thrown errors fail the structured
Callable outcome before `finally` cleanup runs. See `docs/callables.md`.

### Conformance checklist

- **description**: what **and when** (an agent picks a skill by this line).
- **instructions**: numbered STEPS, each an action; if it produces a deliverable,
  one step **writes it to a file** (absolute path), not the chat.
- **verify**: present iff the skill has a checkable outcome, naming a real tool
  it provides or grants. Pure-capability skills (read files, send mail) omit it.
- **single source**: no rule hardcoded in two places. If a checker enforces a
  number/list the instructions also state, both read it from one module or
  registered capability, not two literals. Trusted installed skill code may use
  host modules directly; generated bodies must cross the invocation gate.
- **provides**: bodies obey the tool template (sandboxed, absolute paths,
  "Tool error:" on failure).

`skills.lint(name)` reports where a skill misses this checklist.

## Event handlers (`on_event` / `events.on`)

`on_event` compiles a session-only handler in the same capability environment
as a generated tool. `events.on` is also the Lua API used by trusted runtime
code and by visible user files under `~/.boggart/lua/events/`. Each callback has
a five-million-instruction ceiling. `emit` runs callbacks in isolated
coroutines, reports a throwing, yielding, or exhausted handler, and continues
to later handlers. `ask` applies the same instruction ceiling and returns the
first non-nil answer. A handler is removed after five failures.

Handler hooks compose with any enclosing Lua count hook and restore it on exit.
Exhausting the handler's own allowance is isolated as a
handler failure; exhausting the enclosing allowance propagates to the caller,
even if callback code catches the immediate hook exception. The ceiling counts
Lua instructions rather than elapsed time, so handlers must not block, yield,
or call native work without that operation's own timeout.

Runtime registrations survive a successful reload. User event files are
re-read, replacing the prior file-sourced registrations. If reload fails,
boggart restores the previous module table, module cache, and event-registration
state; arbitrary external side effects performed while loading a module cannot
be rolled back.
