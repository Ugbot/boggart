# Extending boggart: tools, skills, MCP, A2A

How boggart grows new capability, and why it grows it this way. The authoring
templates live in docs/skills-and-tools.md; the execution model in
docs/callables.md; this is the map over all of it, and the philosophy that
picks between the routes.

## The philosophy

**One substrate.** Every capability is Lua the agent can read, edit, and
reload. Not a plugin format, not a config schema, not a second language for
extensions. When something arrives from outside — a markdown skill, an MCP
server, a peer's tool — it is converted to Lua once and from then on is an
ordinary skill or tool the agent can change. Two extension substrates with
different rules would mean the second one is inert: not editable, not
hot-reloadable, not able to compute. So there is one.

**Code over prose, earned.** A capability starts as the cheapest thing that
works — often prose the model executes. As it proves out, the deterministic
parts move into code (docs/callables.md), and the model is left only the
judgment. The runtime measurably converts model calls into Lua over time. This
is the north star: it rewrites itself.

**The gate is at the boundary, not the author.** Any capability, however it
was written, calls tools through the permission engine. Trust tiers decide
whether authored code runs full or sandboxed (docs/team.md); the gate decides
whether a call is allowed. More code never means fewer checks.

**Convert, don't adopt.** boggart consumes foreign protocols at the boundary
and speaks Lua inside. An MCP server's tools become boggart tools; a peer agent
becomes a callable; a markdown skill becomes a skill file. The wire format is a
detail at the seam, never the internal model.

## Four routes, and when to use each

| Route | It is | Reach for it when |
|---|---|---|
| **Tool** | one capability: name, schema, Lua body | a single action the model invokes: read a thing, run a check, transform data |
| **Skill** | a way of working: instructions + tool grants + optional own tools + lifecycle code | a procedure, a role, a bundle of tools that belong together |
| **MCP** | a bridge to an external tool server | a capability already exists as an MCP server (LLM Station, a vendor's) |
| **A2A** | another agent as a callable | the work belongs to a different agent, local or remote |

They are the same shape underneath: all four resolve to a Callable
(docs/callables.md), invoked by name, composable, gated. The differences are
where the capability's code lives and who runs it.

## Tools

A tool is a name, a JSON schema, and a Lua body (sandboxed) or `run` function
(trusted, builtin only). Template and the full sandbox contract:
docs/skills-and-tools.md.

- The agent writes one at runtime with `define_tool`; it registers live and is
  callable that turn.
- `bog.tools.get(name)` returns it as a Callable, so any Lua invokes it the way
  the model does, and it composes into `chain`/`first`/`loop`.
- The `tools` table records calls, failures, and cumulative time, so a tool's
  worth is answerable, not rhetorical.
- Failure is a string: `Tool error: [kind] message`. The `first`/fallback
  combinator reads that prefix to move on.

Build a tool when the unit is a single action. If you find a tool growing a
procedure inside it — steps, retries, model calls — that procedure wants to be
a skill with components.

## Skills

A skill is `{ description, instructions, tools, provides, before, run, finally,
verify, components }`. Instructions are the prose the model follows; `tools` is
its grant; `provides` are callable tools it carries; the lifecycle fields are
the code path (docs/callables.md).

- `define_skill` writes one; `import_skill` compiles a markdown SKILL.md (YAML
  frontmatter) into a skill file — once — after which it is an ordinary skill.
- A skill resolves to a Callable GameObject: `bog.skills.as_callable(name)`.
  Its `before` can answer without the model (`{ done = ... }`); its `finally`
  and `verify` run guaranteed; its `components` attach deterministic slices.
- The three trust patterns: **verify** (name or code the checkable outcome),
  **single source** (rules in one place both prose and checker read), **compose**
  (instructions may be a function pulling in only what it needs).
- `find_skill` and the router surface a skill to the model when the task fits;
  `invocation = "user"` restricts one to explicit grants.

Build a skill when the unit is a way of working. Migrate its steps into code as
they prove deterministic; the skill keeps working through every stage.

## MCP

MCP is how boggart borrows a capability that already runs as an external tool
server. boggart is an MCP *client* (`src/lmcp.c`, `lua/mcphost.lua`): stdio or
Streamable-HTTP, both protocol generations.

- `bog.mcphost.add{ name, command, args }` spawns/connects a server; its tools
  register as `mcp__<server>__<tool>` — ordinary boggart tools from that point,
  granted and gated like any other.
- The fallback chain treats an MCP tool as one tier: a logical name
  (`code_search`) prefers the rich MCP implementation and degrades to a native
  one when the server is down (`register_fallback`). This is `first` at the tool
  layer.
- LLM Station is the reference consumer, and its native ZMQ transport
  (docs/station-zmq.md) is the case where boggart went past MCP to a peer's
  own wire — the same convert-don't-adopt move at a faster boundary.

Reach for MCP when the capability exists as a server and you want it without
reimplementing it. It stays a bridge: the tools are boggart's, the
implementation is the server's.

## A2A (agent to agent)

A2A is another agent as a callable — the work belongs to a different agent, and
you invoke it rather than doing it. Two ranges:

**In-process (shipped).** The swarm: `spawn` a sub-agent with its own skills,
tools, budget, and permission profile; `await` its result; `send`/`publish` to
message it. A spawned reviewer with a schema returns a validated verdict over
the bus. A sub-agent is already a Callable-shaped thing: you invoke it, it
returns, you compose the result.

**Cross-process (designed).** A peer boggart or a foreign agent reached over a
transport. The seams exist: the control plane (`boggart serve`) already takes
prompts and streams the whole event bus (docs/control-surfaces.md); `boggart
connect` (BTEAM) is the client that drives another boggart; the moot protocol
(docs/team.md) is how agents exchange handoffs, reviews, and skills as principals
with their own identity. The interop standard to speak at the editor boundary is
ACP (docs/feature-gaps.md) — one JSON-RPC endpoint, and boggart is drivable by
25+ editors; the cross-agent standard (A2A / agent cards) is the same shape
outward.

The unifying claim: a peer agent, once reachable, is `bog.C`-resolvable like a
skill or a tool. You `chain` a local skill into a remote agent's review; you
`first` a fast local check ahead of an expensive remote one; you `verify` a
peer's output with local code. A2A is not a separate mechanism, it is a Callable
whose run happens to cross a process or a machine.

## How they compose

Because all four are Callables, they mix without adapters:

    -- a review pipeline: local setup (code), a remote reviewer (A2A),
    -- verified with local code, retried if it fails, no model turn for control
    retry{
      node  = chain(
        bog.C("git_diff"),                 -- tool
        pin_and_collect,                    -- skill component (code)
        bog.C("peer:reviewer")             -- A2A: another agent
      ),
      check = function(ctx) return has_findings(ctx.result) end,   -- verifier (code)
      max   = 2,
    }

Every box is the same kind of value; the model is called only inside the boxes
that need it. That is the whole design: capabilities are values in one small
language, the model is `eval`, and boggart gets better as more of the language
is compiled.

## Where to go next

- Authoring templates and the sandbox contract: docs/skills-and-tools.md
- The execution model (lifecycle, combinators, verifiers): docs/callables.md
- Trust tiers and identity for shared capability: docs/team.md
- The station transport and going past MCP: docs/station-zmq.md
- The C/Lua boundary (why a route is C or Lua): docs/control-surfaces.md
