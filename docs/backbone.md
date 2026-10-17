# Boggart Backbone

Remote product direction, 2026-10-17: **Boggart Backbone** is developed in the
existing private `Ugbot/llm-station-remote` repository. All remote control-plane,
team routing, remote-worker, and paid remote-service plans live there.

The [Backbone direction and discovery plan](https://github.com/Ugbot/llm-station-remote/blob/feature/boggart-backbone/docs/backbone/README.md)
is the canonical remote design entry point. The initial branch is
`feature/boggart-backbone`; access requires permission to the private repository.

Backbone is a multi-user, team-aware server that relays work and presents shared
state to clients. It is authoritative for routing. Workers own their execution,
processes, local artifacts, and execution records. Browser and local Studio are
peer clients; the browser target is WASM Studio.

Local Boggart remains complete without Backbone or a remote subscription. The
LLM Station daemon is a separate, optional per-machine service for richer
capabilities. Paid remote capacity and managed agents join the same swarm model.
Third-party agents register in Fleet and progress toward delegation/control
parity through adapters.

The swarm remains the product's core, with Lua skills extending it across
knowledge work. Bmux is both a terminal and a swarm workbench. The next phase is
discovery of the existing swarm, live skills, shared planning blackboard, server,
and client/worker boundaries before implementation milestones are fixed.

This supersedes older remote-server placement and rollout proposals in
`team.md`, `runtime-plan.md`, and `ecosystem-brain-roadmap-2026-09-21.md`.
Those documents remain useful context for local capabilities and existing
adapters. This decision does not establish a working Backbone router, change
current peer-server attachment behavior, or select a server implementation
language. Boggart client and runtime work remains in this C/Lua repository.
