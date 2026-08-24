# boggart-studio — review & improvement backlog

A full review pass over boggart-studio (SDL/C host + lite-xl-derived Lua UI + the
agent surfaces), grounded in the source. Findings are ranked; each is written to
be actionable. Effort = S/M/L, Impact = High/Med/Low. Tickets are opened for the
starred (★) items; the rest live here as the backlog.

**One correction to prior belief:** the AGENT/EDIT/FLEET workspace shell is *not*
unbuilt — it exists under `studio/data/shell/` (menu bar, workspaces, grouped
command registry, nvim spine, swarm approval gate) but is **opt-in behind
`BOGGART_STUDIO_SHELL=1`** (`core/init.lua:629`). The default is a *third*
composition (rail + `core/workspaces.lua`); legacy is a *fourth* behind
`BOGGART_STUDIO_LEGACY=1`. That reshapes the priorities: finish the shell, don't
design a new one.

---

## Quick wins (S effort, do first)

- ★ **Q1 — `SDL_StartTextInput` is never called (SDL3 text input dead).** `api/system.c:145`
  decodes `SDL_EVENT_TEXT_INPUT` and the Lua layer keys typing off `"textinput"`
  (`core/init.lua:875`), but SDL3 gates text events behind per-window opt-in; without
  `SDL_StartTextInput(window)` after `SDL_CreateWindow` (`main.c:126`) they're never
  delivered (verified against vendored `SDL_keyboard.c:768`). IME won't work either.
  *S / High (correctness).*
- ★ **Q2 — Stack buffer overflow in `key_name()`.** `strcpy(SDL_GetKeyName(...))` into
  `char buf[16]` (`api/system.c:69,81`); SDL3 names like "Keypad MemMultiply" exceed 15
  chars → one exotic keypress smashes the poll stack. `buf[64]` + `snprintf`. *S / High.*
- ★ **Q3 — rencache cell-grid OOB on wide framebuffers.** `update_overlapping_cells`
  (`rencache.c:220-232`) and the `max_x/max_y` loops (`:264-275`) never clamp to
  `CELLS_X/Y` (grid = 7680×4800px); an 8K-wide or 2×-scaled-4K framebuffer writes past
  the static `cells_buf` arrays. Clamp (lite-xl does). *S / High (memory corruption).*
- ★ **Q4 — KPI bar + exit-reason pane hit SQLite + JSON every frame.** `draw_totals` calls
  `telemetry.kpis(run_id)` per draw (`swarmview.lua:691`) → `records_for` + `json.decode`
  per row; `draw_detail` calls `agent_status` per draw (`:589`) → scans `records_recent(500)`.
  `update()` forces redraw while live → ~60 store scans/sec when the store is busiest.
  Cache behind the once-per-second `refresh()` guard (`:200-203`). *(Regression from this
  session's KPI surfacing — content is right, cost is wrong.)* *S / High.*
- ★ **Q5 — `ctrl+return` steals `doc:newline-below` app-wide.** `studio.lua:1619` binds it to
  `agent:toggle-panel` under an always-true predicate; keymap prepends, so
  `doc:newline-below` is unreachable in the editor (`pickerview.lua:283` documents being a
  victim). Predicate it. *S / High.*
- ★ **Q6 — "The tree is on the right." — it docks left.** `sidebarview.lua:310`; the tree
  splits left in every composition. Delete the sentence. *S / High (it's a lie on screen).*
- ★ **Q7 — vim `D`/`C`/`d$`/`c$` join lines.** `$` returns `(l, math.huge, "inc")`
  (`vim.lua:286`) and the inclusive-motion extension steps past EOL into `(l+1,1)`
  (`:404`), deleting the newline. `x` has a `"\n"` guard; `$` needs the same. *S / High
  for vim users.*
- **Q8 — `agent:run-command` freezes the window.** Comments "already non-blocking", then calls
  `bog.tools.run("bash", ...)` synchronously on the frame loop (`studio.lua:1600-1611`). Wrap
  in `core.add_thread`. *S / Med.*
- **Q9 — shell: typing `?` opens the shortcuts overlay everywhere.** `shell/shortcuts.lua:159`
  binds `shift+/` with a nil predicate; "?" can't be typed in the composer. Predicate on
  `not modal.typing()`. *S / Med.*
- **Q10 — `agent:set-endpoint` clear leaves a stale endpoint cache.** `studio.lua:1036` clears
  `base_url` without `bog.api.forget_auth()`. One line. *S / Med.*
- **Q11 — Linux `get_exe_filename` writes `buf[-1]` if readlink fails.** `main.c:72`. Guard the
  `-1`. (macOS: `_NSGetExecutablePath` return ignored → `EXEFILE` can be uninitialized.) *S / Med.*
- **Q12 — `keymap.reverse_map` nondeterministic → displayed hints drift.** Last-writer-wins over
  `pairs` (`keymap.lua:63`); macOS cmd-mirrors snapshotted at load so Cmd+O and Ctrl+O bind
  different dialogs (`:232`). Make add deterministic; regenerate mirrors after startup. *S / Med.*
- **Q13 — `agent:resume-session` duplicates the `session_picker` helper** line-for-line
  (`studio.lua:1087` vs `:853`). Use the helper. *S / Low-Med.*

---

## The new additions (this session — real bugs to fix)

- ★ **N1 — inline Cmd-K (`plugins/inline_edit.lua`): right design, four bugs.** Design is
  correct (scratch session, tool-free, result → buffer edit + change-mark for alt+n/alt+r
  review). Bugs:
  1. **Stale-coordinate apply (data loss).** Async reply applies `doc:remove(l1,c1,l2,c2)` at
     coordinates captured at Cmd-K time (`:41`) with no check the span still holds `selection`.
     Edit above it (or an agent writes the file) mid-flight → wrong text destroyed. Re-validate
     like `marks.revert` (`marks.lua:377`) and abort on mismatch.
  2. **Silently does nothing without the pump.** The coroutine goes to `bog.sched` under a fake
     id (`:47`), but the pump only runs when `studio.swarm_ok`; the `coroutine.resume` fallback
     runs a transport that yields `"io"` with no one to resume it → parks forever, no error.
     Route through `core.add_thread` (pumps `http`), drop the fake id (it also shows up in FLEET
     as an anonymous agent and gets reaped by `AgentView:cancel`).
  3. **`unfence` strips first-line indentation.** `s:gsub("^%s+","")` (`:19`) removes leading
     whitespace → an indented block loses its indent; trailing strip can eat a final newline.
     Strip fences only.
  4. **No in-flight feedback, no cancel, undo may be two steps, no test.** Add a working
     indicator, group the remove+insert undo, add a `tests/` case.
  *M total / High. Reusing marks (yes) and not reusing approval (correct) are both right calls.*
- **N2 — Swarm KPI surfacing.** Content is right (delivered %, false-ok, think:out; the
  "failed: reason" line is excellent); cost is wrong — see Q4.

---

## Big structural items (ranked)

- ★ **S1 — Three parallel window compositions are live; pick the shell, delete the other two.**
  `core/init.lua:613-634` branches legacy / rail+workspaces / shell; every downstream surface
  carries three-way branches sniffing `package.loaded["shell"]` and `studio.legacy`
  (`studio.lua:368,440,1467`; `agentview.lua:1777` keys a toolbar on a tri-state boolean whose
  *nil* means "shell"). `each_content_leaf`/`collapse_content_leaves` are copy-pasted
  (`workspaces.lua:26` vs `shell/init.lua:28`); the shell monkey-patches `studio.agent_view`/
  `SwarmView.open` at attach. **Promote the shell to default, keep legacy one release behind a
  flag, delete `core/workspaces.lua` + `railview.lua` + the `studio.legacy` branches.** Highest
  leverage in the tree (~800 lines gone + a whole bug class). The prior plan was right; it's 70%
  built — finish it. *L / High.*
- ★ **S2 — One settings module.** The same `auth.*` keys are written from welcomeview,
  settingsview, and palette commands with divergent rules: scheme validation only in
  settingsview (`:124`); key-trim only in settingsview/welcomeview (settingsview `:209` documents
  the exact 401 bug the palette path still has); `set-endpoint` clear skips `forget_auth`; the
  "responses" wire is selectable in only one place. **One `core/settings.lua`
  (validate→trim→store→invalidate→emit); all surfaces call it.** *M / High.*
- ★ **S3 — Decompose the `studio.lua` god module (1,642 lines).** Mixes window composition,
  the swarm-engine lifecycle (`:184-329`), monkey-patched observation of `bog.api.run_on`
  (`:237`), status-bar building, session CRUD, MCP persistence, and ~60 command regs. Split the
  swarm engine into `core/engine.lua` (both shell and legacy need it), commands into
  `commands/{agent,studio}.lua`, leave `studio.lua` as composition. Do it after S1. *M-L / High.*
- ★ **S4 — Move approval parking out of the frame pump.** `studio.start_pump` (`:299-329`) peeks
  into `v.pending`/`bog.choice` each frame to `sched.pause` the coordinator because `sched`
  classifies the `"approve"` yield as runnable; the sub-agent gate re-yields at frame rate for
  120s (`shell/agent/approval.lua:135`); swarmview special-cases `state_of` (`:244`). Three
  workarounds for one missing primitive. **Teach `sched` a real blocked state
  (`yield("approve", rec)` parks until `sched.unblock(id)`).** Also unifies the asymmetry
  (coordinator waits forever, sub-agents auto-refuse at 120s). *M / Med-High.* (Ties to the
  engine-first spine in the main roadmap.)
- **S5 — Unify the four "saved prompt" systems.** `automations.lua` claims to merge recipes/
  workflows/schedule but all four still exist and the Run menu shows three side by side
  (`shell/registry.lua:89`). Make automations the store; port `{{param}}` + the scheduler; delete
  the rest. *M / Med-High.*
- **S6 — Unify the three modal-keyboard systems** (`core/vim.lua`, `shell/modal.lua`,
  `AgentView.edit_mode`) — the spine should own "what mode is the focused surface in", vim + the
  composer as clients. Roadmap, after S1. *L / Med.*
- ★ **S7 — Agent↔editor: the next Cursor-grade steps** (what exists — approval-with-diff, marks,
  @-mentions — is genuinely good):
  1. **Sub-agent edits bypass marks entirely** — laid only from the coordinator's `run_tool` hook
     (`agentview.lua:398`); a spawned worker's write produces no mark/reload. In a fleet product
     the fleet's edits are the *least* reviewed. Hook mark-laying at the `file:write`/`file:edit`
     events, not in one view. *M / High.*
  2. **No cross-file review surface** — marks are per-buffer; no "12 hunks in 5 files, accept all /
     walk them" panel. A `ReviewView` fed from the mark stores (marks already carry `group`) is the
     biggest single UX step toward Cursor parity. *L / High.*
  3. `dirty_path` is a single slot (`:413`) → two writes in one slice mark only the last. Queue it.
  4. `reload_dirty` matches by substring (`:646`) → editing `a.c` reloads `data.c`. Compare abs paths.

---

## Remaining backlog (by area)

**Performance / correctness**
- **P1 — Focused-idle app never blocks** — `core.run` calls `wait_event` only when unfocused
  (`init.lua:1033`); focused+idle spins at `config.fps` forever (battery/thermals). Extend the
  block to focused-but-no-redraw-and-no-due-thread with a short cap. *M / Med.*
- **P2 — Streaming re-layout is O(n²)** — each chunk re-tokenizes/wraps the whole entry
  (`agentview.lua:1410,1449`) at frame rate; a 100KB reply chugs. Layout per-block / cache all but
  the tail. *M / Med.*
- **P3** — status bar hits `auth`/pricing every frame (`studio.lua:487`); cache 1s. *S / Low.*
- **P4** — treeview per-frame `absolute_path` syscall + never-pruned cache (`treeview.lua:183,23`);
  pickerview redraw on mouse-move (`:336`). *S / Low.*
- **P5** — rencache `Command` structs unaligned (`rencache.c:189`) → unaligned reads (UB; tolerated
  on x86/ARM64). Round size to `alignof(Command)`. *S / Low.*
- **P6** — `marks.attach` suffix-match adopts wrong store (`foo.c` ← any `*foo.c`, `marks.lua:481`).
  Require a separator boundary. *S / Low.*
- **P7** — welcomeview leaks the HTTP handle if the test body throws mid-stream (`:488`). *S / Low.*
- **Font/atlas leaks & misc C** — FREE_FONT commands dropped on identical frames leak RenFont/
  FT_Faces/textures (`rencache.c:288-342`); per-glyph `SDL_GetTextureSize` in the draw loop
  (`renderer.c:1220`); glyph-atlas texture failure renders invisibly with no log (`:804`);
  `buttonid` read uninitialized if the message box fails (`api/system.c:328`); `px()` truncates
  negative coords (`:57`); `f_exec` is shell-injection-shaped (`:447`, use `uv_spawn`);
  font-size unclamped → int overflow at absurd sizes (`renderer_font.c:64`); `fontfallback.h:19`
  claims thread-safety it doesn't have. *S each / Low (mostly).*

**UX**
- **U1 — Tab strip**: unbounded shrink, middle-click-only close, invisible lone non-doc tabs
  (`rootview.lua:229,260,489`). Min width + overflow chevron + always show named views. *M / Med.*
- **U2 — Five hand-rolled single-line text fields** (CommandView, settingsview, welcomeview, sidebar
  search, pickerview) each reimplement caret/UTF-8 backspace; **none support paste or arrows** — a
  pasted API key with a typo means retyping. Extract `ui.textfield` (+ `ui.elide`, copied 4×). Root
  cause of S2's drift. *M / High.*
- **U3 — Empty states** — fresh install shows a bare "Recents" with nothing (`sidebarview.lua:398`);
  welcomeview deletes greetings by matching English text (`:566`, self-documented fragile). *S / Med.*
- **U4 — vim gaps** — `cw` acts as `c`+`w` not `ce`; linewise yanks skip the system clipboard
  (`vim.lua:83`, `yy` then cross-app paste is stale); `/` literal vs `:s` Lua patterns unlabelled;
  `p` ignores count. Fix the S items, document non-goals. *S each / Med.*
- **U5 — modal `ctrl+w` claimed while typing** (`modal.lua:145`); exact-class `getmetatable == DocView`
  checks break subclasses (logview). *S / Low-Med.*

**Code quality**
- **C1** — `run_slash` counts `core.threads` to detect a stubbed scheduler (`agentview.lua:602`) —
  make the stub honest. **C2** — SwarmView has two singletons (`instance` vs `studio.swarm`) that
  drift (`swarmview.lua:45` vs `workspaces.lua:198`). **C3** — `AgentView:new` installs global
  closures capturing `self` (`:67`) — stale on a second construction. **C4** — `is_font_name` misses
  uppercase `.OTF/.OTC` (`fontfallback.c:182`). **C5** — Fleet menu has two identical rows
  (`registry.lua:100`); duplicate mark-command aliases. *S each / Low.*

---

## What's genuinely good (keep, don't churn)
- **`marks.lua`** — the best module in the tree: extmark semantics, memoized washes, bottom-up hunk
  shifts, refuse-don't-guess revert, and it's tested (`tests/studio.lua:583`).
- **agentview's turn machinery** — coroutine-per-turn, approval as a mid-tool yield with the diff at
  the decision point, choose-menu parking, was-at-bottom follow, cell-based wrapping. Long but sound.
- **The shell layer** (registry-driven menubar with keyboard nav, leader/which-key spine, cheatsheet)
  — clean and the right architecture, which is *why* S1 says finish it.
- **perm centralization** (modes shared with the CLI), the MCP double-start fix, telemetry's
  aggregate-at-boundaries design.
- **C host** — scale-factor derivation, SIGPIPE handling, shutdown ordering, the growable rencache
  buffer; **dirmonitor** (threadless per-monitor uv loop pumped non-blocking — kills lite-xl's races
  by construction); the **glyph-cache redesign** (plane→block→phase, fixes upstream aliasing); font
  metrics discipline; HiDPI ratio measurement; fallback probe-by-table with the honest emoji refusal.

## Suggested order
Q1–Q13 (a day or two) → fix N1's four Cmd-K bugs → S1 (shell default, delete two compositions) →
S2 + U2 together → S3 → S4 → S7.1/S7.2 (event-layer marks + cross-file review) as the next feature
investment.
