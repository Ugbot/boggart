# Skills — a described library of capabilities (that can be code)

A **skill** in boggart is a Lua file under `lua/skills/<name>.lua` (baked in) or
`~/.boggart/lua/skills/<name>.lua` (overlay). An agent's spec names skills; resolving
them gives the agent instruction text and a tool allowlist. Skills are *the* extension
substrate — all-in on Lua, where other harnesses have the model write Python/Node.

A skill is a table:

```lua
return {
  description  = "one line, shown in listings",
  instructions = "spliced into the agent's system prompt under # Skills",
  tools        = { "read", "bash", "mcp__github__*" },  -- allow-list of tool names
  provides     = { … },                                 -- its OWN callable tools (code)
}
```

`description`/`instructions`/`tools` are the prose+permissions half. **`provides` is the
code half**: a described table of tools the skill carries. That is what makes a skill a
*code package* rather than only prose.

## `provides` — entries that are real code

Each entry has a `name`, an optional `description` + `input_schema` (its model-facing
doc/schema), and **exactly one of**:

- **`run = function(args) … end`** — a real Lua function, **full authority**. Only honoured
  from a **built-in, in-repo** skill file (reviewed code). Structural, not a check: the
  serializer can't write a function, so a `run` entry can only ever exist in a hand-written
  baked file.
- **`body = "…lua source…"`** — a Lua source string, compiled through the **same sandbox as
  `define_tool`** (`build_def` → `tool_env` + an instruction/memory budget). This is what the
  model writes via `define_skill`, so **everything model-authored is sandboxed by default.**

A provided tool is registered as **`skill__<skill>__<tool>`** and offered to any agent
granted the skill. It is *excluded* from the unrestricted default tool list — a provided tool
is meaningless without its skill's instructions, so it only appears once the skill is granted.

Example (baked-in `selfmod` skill):

```lua
provides = {
  { name = "word_count",
    description = "Count the whitespace-separated words in args.text.",
    input_schema = { type = "object", properties = { text = { type = "string" } } },
    run = function(args)
      local n = 0; for _ in tostring(args.text or ""):gmatch("%S+") do n = n + 1 end
      return tostring(n)
    end },
}
```

## Trust: hybrid by default, switchable to full power

- Built-in skills carry trusted `run` functions.
- Model-authored skill code (`body`) is **sandboxed** by default: no `io`, no destructive
  `os`, no `require`, and a runtime instruction/memory budget.
- Flip it with **`/trust full`** (or `BOGGART_SKILL_TRUST=full`): model bodies then compile
  against the full `_G` with no budget — the model's Lua runs exactly like an in-repo
  function. `/trust sandboxed` restores the default. The current mode shows in `doctor`.
  This is an explicit, loud opt-in: in `full`, model-written Lua has unrestricted io/os/network.

## Lifecycle

- **`resolve`** (per agent spawn) stays pure and cheap: it folds a skill's provided tool
  *names* into the allowlist. No compilation on the hot path.
- **materialize** (at `tools.lua` load, on `/reload`, and on `skills.save`) compiles bodies →
  registry, keyed by body so an edit re-registers, with authoritative pruning so a dropped
  entry is removed. A body that fails to compile is skipped + logged — it never breaks a spawn.
- The model authors skills with **`define_skill`** (pass `provides`; each body is
  compile-checked before it persists) and imports markdown ones with **`import_skill`**.

## `provides` vs `define_tool`

Two authoring surfaces, one sandbox. Use **`define_tool`** for a standalone, scoped
(session/project/global), provenance-tracked helper stored under `~/.boggart/lua/tools/`. Use a
skill's **`provides`** for tools *inseparable from a way of working* — they travel with the
skill's instructions as one package. Both compile through `build_def`/`run_bounded`, so there
is exactly one sandbox and one budget for all model-authored Lua.
