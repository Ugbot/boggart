# Server agents in joined Studio Bmux

On entering Bmux, Studio automatically starts or reconnects to the current
project's persistent server; the same flow is described in
[joining a layout](bmux-studio-layout.md). **+ New agent** launches on that
server. Choose Boggart TUI, resume a Boggart session, Codex, Claude Code or a
custom executable with quoted arguments. Commands use literal argv. These
server agents remain in the common Fleet and keep their live PTYs when Studio
closes and reopens. If the server itself restarts, saved Boggart/shell recovery
follows the journal rules; foreign executables such as Codex return inactive.
**+ Local agent** retains local launching. In Fleet, the toolbar explicitly distinguishes
**New server agent** and **New local agent** while joined.

Server agents appear alongside local entries in the existing Fleet. The server
publishes each provider's actual capabilities: Boggart supports structured
prompt, interrupt, approval and Stop; ordinary foreign processes expose Stop
and process observations. Worker entries retain their parent relationship and
supported Cancel action. Fleet **Focus pane** reveals an existing terminal view
or adds an agent reference to the layout. Workers focus their owning TUI.

Agent views attach to the published native terminal and initially observe
read-only. **Take control** in the terminal header enables ordinary terminal
input. A structured prompt cannot overwrite a human draft. Approval controls
carry the observed request identity, so an old button cannot approve a newer
request. Focus and mode changes preserve the terminal attachment and renderer.

Closing an agent view removes its layout reference. Disconnecting removes the
imported Fleet rows and restores the preserved local layout. Both leave server
processes alive. Rejoin or Fleet Focus attaches to the original runtime.

An ambiguous launch/control acknowledgement keeps the exact request pending.
**New agent → Retry pending agent command** explicitly retries it. Refresh and
reconnect only observe. If launch succeeds but placement fails, Studio reports
the retained agent/terminal; use Fleet Focus rather than launching again.

## Presentation boundary

`core.bmuxagents` owns the joined Fleet client and presentation source.
`bmux.fleetsource` mounts namespaced rows through `fleet:set_source(name, fn,
owner)`. `fleet:get(id)` resolves both local and source-owned rows; generation
and capability checks precede owner dispatch. Execution ownership remains on
the server. Local owners and internal Fleet sources remain in place.

Same-generation remote rows retain object identity; replacement generations
invalidate saved actions. Disconnection disables execution capabilities.
Client-only rows carry `fleet_remote` and are excluded from server publication,
including when a client joins a server in its own process.

The layout pool resolves agent IDs to terminal identity/generation and rebuilds
only when that binding changes. No agent view creates an execution owner.
Closing the source unmounts rows; closing the client releases transport only.

[Terminal-mode Fleet](bmux-ctui.md) uses the same native command policy and
existing-runtime pane lookup. Durable daemon-restart recovery and universal
semantic controls for arbitrary foreign programs remain follow-ups. See
[verification](benchmarks/2026-10-16-studio-server-agents-verification.md).
