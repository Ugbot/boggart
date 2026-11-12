# Bmux session transfer implementation plan

Execute inline in the existing feature branch. This implements the transfer
boundary in the approved session-restore design; BMUX-97 also retains client
menus and explicit corrupt-session recovery as subsequent increments.

**Goal:** Export a checkpoint and import it into a new named session without
executing or promoting any imported command, shell or agent resume recipe.

**Architecture:** Reuse the checkpoint codec, SQLite owner CAS and native UDS
transport. Import creates an inactive named checkpoint for explicit daemon
startup, leaving the currently attached server and its processes running.

**Tech stack:** C/Lua, existing SQLite store and native libuv transport.

## Constraints

- The 4 MiB checkpoint and existing layout/history/resource budgets remain.
- Imported terminal/agent recipes are always `saved` before storage.
- Every import takes the journal's exclusive owner guard. Existing sessions,
  corrupt saved bytes and live owners cannot be overwritten by import.
- Export/import never invoke runtime restore. Starting the imported session is
  explicit: `boggart serve --socket PATH --bmux-session NAME`.
- Native clients never replay an uncertain import automatically. Refresh is
  observation only. Import names through HTTP are 1–128 ASCII letters, digits,
  underscores or hyphens; local socket-derived session names remain supported.

## Steps

- [x] Add `bmux.checkpoint.import(raw)` to validate/copy and demote all recipes.
  Extend `tests/bmux_checkpoint.lua` to retain source bytes and resume refs.
- [x] Add `bmux.journal.import(name, raw, store?)` with shared owner acquisition,
  absent-key CAS and conditional owner release. Test occupied/corrupt names,
  live/dead owners, storage failures and no live-owner mutation.
- [x] Add authenticated export/current-session and named import routes in
  `bmux.server`, preserving query rejection and capability boundaries.
- [x] Add `bmux.sessionclient` over `terminal.client`, pin observation to a
  known host and bound all response shapes. Import succeeds only on an exact
  inactive/name acknowledgement; uncertain requests require user observation.
- [x] Add native route/client integration coverage and actual daemon import,
  restart and resave checks, including default-shell/Boggart recipes and marker
  content that must never execute. Register the suite in CMake.
- [x] Build normal and ASan/UBSan targets, run focused transfer/journal/restart
  and layout/Fleet client suites, review the diff, document evidence, commit and
  push. Leave BMUX-97 and BMUX-33 open for their remaining work.
