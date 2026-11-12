# Handoff: Boggart Story

Date: 2026-10-17
Branch: `feature/bmux-termbench`

## Goal

Continue product/design work to bring Boggart up to the bar for serious story
writing, while keeping Story Engine (SE3) alive as a full creative application
and upgrading it. Preserve the creative experience and feature set; its current
codebase is useful reference and migration material, not an architectural
constraint.

## Agreed direction

- Boggart is a first-class story-writing workspace built around its swarm:
  ideation/interview, worldbuilding, outlines, drafting, editing, continuity,
  branching, review and author-controlled canon.
- Story Engine retains and upgrades its full creative feature set, including
  authoring, worldbuilding, visual novels, live scenes, branching, letters and
  campaigns. It is not reduced to a viewer/player.
- Boggart and Story Engine should create and experience the same stories,
  sharing story identity, capability contracts and exchange formats. Avoid
  divergent canon implementations.
- Gestalt is an optional external memory engine/API. Boggart's SQLite and
  Markdown baseline remains fully useful when Gestalt is absent. Advanced
  graph/evidence/semantic retrieval, richer context assembly and change-impact
  analysis can require connected Gestalt capabilities.
- The Boggart-facing plugin integration should support native Lua modules and
  external services over ZeroMQ, with capability discovery. Gestalt would be
  exposed as a service in the style of LLM Station; Boggart does not bind
  directly to MarbleDB.
- Markdown remains the author-owned manuscript format. Pick one authority per
  collection; do not silently maintain competing canon copies. A disconnected
  Gestalt leaves manuscript editing available and reports dependent features'
  availability/freshness honestly.
- Experimental play owns its session state and changes. Return transcripts,
  discovered facts and world changes as proposals for author review; never
  mutate canon directly from play.

## Promising SE3 capabilities

Reviewed local source in `/Users/bengamble/Story-engine-3` (read-only; no tests
were run). Strong ideas worth preserving:

- Live scene play: author chooses a viewpoint character; AI plays the rest;
  session can render as text/MUD or VN and can be promoted into a story branch.
- VN playback: dialogue stepping, sprites, backgrounds, audio, transitions,
  choice navigation and conversion of prose scenes for play.
- Safe what-if branches and explicit promotion to canon.
- Epistolary writing with recipient, delivery and per-character awareness.
- Interview ledger with locked decisions and intentional unknowns.
- Plots/arcs/beats and continuity/context based on the story's structure.
- Ren'Py and Ink exports as an escape hatch.
- Campaign play can feed story material, although the inspected
  `SessionToStoryService` conversion is basic and should not be mistaken for a
  polished narrative workflow.

Do not trust the old `docs/AUDIT_2026_04.md` as current status. The VN player is
more complete now; `VNGameStateService` persists sessions. Source inspection
found live play can directly change item ownership/location (`takeItem` /
`dropItem`), which is a warning for canon isolation. Check present behavior,
tests and edge cases before claiming any feature is complete or migrating it.

## Boggart source to inspect

- `docs/story-model.md`: story model proposal/history and local implementation
  map. Its M1 claims tables, aliases, events/deltas, time-indexed state,
  facts/knowledge and JSONL mirror; verify current code before expanding claims.
- `lua/story/` and `tests/story*.lua`: existing local story foundation.
- `docs/skills.md`: existing Lua skill/tool extension contract.
- `docs/station-zmq.md`: Station-specific ZeroMQ client design; do not assume
  this is already a general-purpose plugin protocol.

Useful SE3 starting points:

- `story-engine-frontend/src/features/vn/VNPlayerPage.tsx`
- `story-engine-quarkus/src/main/java/com/ugbot/storyengine/service/livescene/LiveSceneService.java`
- `story-engine-quarkus/src/main/java/com/ugbot/storyengine/service/ai/VNConversionService.java`
- `story-engine-quarkus/src/main/java/com/ugbot/storyengine/service/story/StoryBranchingService.java`
- `story-engine-quarkus/src/main/java/com/ugbot/storyengine/service/VNGameStateService.java`
- `story-engine-quarkus/src/main/java/com/ugbot/storyengine/service/ttrpg/SessionToStoryService.java`

## Suggested first vertical

Design and then prototype “Play this scene”: open a manuscript scene, choose a
viewpoint character, let the swarm portray the remaining cast, render the same
session in text or VN mode, save/resume it, then review the transcript and
proposed story/world changes for incorporation. It exercises the writing UX,
swarm, capability-based plugin boundary, optional Gestalt memory and safe
canon handling without attempting all of SE3 at once.

## Open questions for the next agent

1. What concrete workflows/features are necessary for Boggart to meet the
   user's story-writing bar? Interview the user against actual workflows;
   do not assume software-first priorities demote fiction writing.
2. Define a portable story identity/exchange boundary between Boggart, SE3 and
   Gestalt, including document ownership, canon authority and offline behavior.
3. Audit the SE3 feature inventory against current code/tests and classify each
   as preserve, redesign, defer or retire. Treat VN/live play as serious
   candidates, not decorative extras.
4. Specify the general Lua/ZeroMQ plugin contract: discovery, declared
   capabilities, invocation, streaming/progress, errors, lifecycle and
   permissions. Reuse Station transport lessons without inheriting its
   Station-specific daemon protocol by accident.
5. Decide the first delivery boundary and acceptance criteria before opening
   implementation tickets. Existing swarm planning does not yet define this
   Story track.

## Repository and privacy notes

At handoff creation the Boggart checkout was clean on
`feature/bmux-termbench`, at `cdaf8d6`, tracking `origin/feature/bmux-termbench`.
Keep unpublished infrastructure plans and repository details out of public
Boggart docs.

## Suggested skills

- `brainstorming` and `interview-me` to lock story-writing goals and workflows.
- `domain-modeling` and `api-and-interface-design` for shared story identity,
  canon and plugin/service contracts.
- `planning-and-task-breakdown` or `to-tickets` after the design is stable.
- `gestalt2-workspaces` before opening, moving or selecting any Gestalt2
  checkout; its workspace register has strict ownership/preservation rules.
- `git-workflow-and-versioning` for implementation and commits.
