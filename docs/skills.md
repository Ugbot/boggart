# Skills — a described library of capabilities (that can be code)

A **skill** is the extension substrate — all-in on Lua, where other harnesses have the
model write Python/Node. It's a Lua table, stored as a file under `lua/skills/<name>.lua`
(baked in), `~/.boggart/lua/skills/<name>.lua` (overlay), **or in the database**:

```lua
return {
  description  = "one line, for listings",
  instructions = "spliced into the agent's system prompt under # Skills",
  tools        = { "read", "bash", "mcp__github__*" },  -- allow-list of tool names
  provides     = { … },                                 -- its OWN tools, keyed by name
}
```

`description`/`instructions`/`tools` are prose + permissions. **`provides` is the code
half** — a described table of the tools the skill carries.

## `provides` — a table keyed by tool name

`provides` maps a tool name to its described definition. Each value has an optional
`description` + `input_schema` (its model-facing doc/schema) and **exactly one of**:

- **`run = function(args) … end`** — a real Lua function, **full authority**. Only honoured
  from a **built-in, in-repo** skill file (reviewed code). Structural: the serializer can't
  write a function, so a `run` entry can only exist in a hand-written baked file.
- **`body = "…lua source…"`** — a Lua source string, compiled through the **same sandbox as
  `define_tool`** (`build_def` → `tool_env` + an instruction/memory budget). This is what the
  model writes, so **everything model-authored is sandboxed by construction.**

```lua
provides = {
  word_count = {
    description  = "Count the whitespace-separated words in args.text.",
    input_schema = { type = "object", properties = { text = { type = "string" } } },
    run = function(args)
      local n = 0; for _ in tostring(args.text or ""):gmatch("%S+") do n = n + 1 end
      return tostring(n)
    end,
  },
}
```

**Managed exactly like MCP tools.** A provided tool is registered into the shared registry as
**`skill__<skill>__<tool>`** (parallel to `mcp__<server>__<tool>`), and a skill grants its
whole namespace with **one wildcard** `skill__<skill>__*` (parallel to `mcp__<server>__*`).
Provided tools are excluded from the unrestricted default tool list — like an MCP server's
tools, they surface only for an agent the skill was granted to.

## Importing markdown — including code

`import_skill` compiles an ecosystem SKILL.md (YAML frontmatter + prose) into a Lua skill —
one substrate. A **`## Tools`** section becomes the skill's `provides`:

```markdown
---
name: text-kit
description: Text helpers
---
Use these for text.

## Tools

### shout
Uppercase args.text.

```lua
return tostring(args.text or ""):upper()
```
```

Each `### <name>` subsection → a provided tool: its prose is the `description`, its ```lua
fence is the `body` (sandboxed like any model-authored code). The rest of the markdown is the
skill's `instructions`.

## Storage — files or the database

Authored/imported skills persist as a **Lua file** by default (editable, hot-reloadable).
Pass **`store="db"`** to `define_skill`/`import_skill` to keep the same Lua source in the
SQLite kv store instead (portable, travels with the store, no stray files). Load precedence:
overlay file → embedded → database (a file/builtin of the same name shadows a DB skill).
`doctor` and the `skills` tool list all three; `list()` marks each skill's source.

## Trust: hybrid by default, switchable

- Built-in skills carry trusted `run` functions.
- Model-authored skill code (`body`) is **sandboxed** by default (no `io`, no destructive
  `os`, no `require`, plus a runtime budget).
- **`/trust full`** (or `BOGGART_SKILL_TRUST=full`) compiles model bodies against the full
  `_G` with no budget; `/trust sandboxed` restores it. The current mode shows in `doctor`.
  An explicit, loud opt-in — in `full`, model-written Lua has unrestricted io/os/network.

## Lifecycle

- **`resolve`** (per spawn) stays pure and cheap: it folds a skill's `skill__<skill>__*`
  wildcard into the allowlist. No compilation on the hot path.
- **materialize** (at `tools.lua` load, on `/reload`, and on `skills.save`) compiles bodies →
  registry, keyed by body so an edit re-registers, with authoritative pruning of dropped
  tools. A body that fails to compile is skipped + logged — it never breaks a spawn.
- **`define_skill`** authors skills (each `body` compile-checked before it persists);
  **`import_skill`** compiles markdown (including its `## Tools`).

## `provides` vs `define_tool`

Two authoring surfaces, one sandbox. Use **`define_tool`** for a standalone, scoped
(session/project/global), provenance-tracked helper stored under `~/.boggart/lua/tools/`. Use a
skill's **`provides`** for tools *inseparable from a way of working* — they travel with the
skill. Both compile through `build_def`/`run_bounded`, so there is exactly one sandbox and one
budget for all model-authored Lua.
