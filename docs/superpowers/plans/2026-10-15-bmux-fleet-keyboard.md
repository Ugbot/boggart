# Fleet keyboard controls implementation plan

**Goal:** make the approved common-Fleet controls reachable without a mouse,
using stable action identity, visible focus and the existing execution owners.

**Architecture:** `lua/actionfocus.lua` holds only opaque action-key selection;
`core/fleetactions.lua` builds the existing capability-filtered actions and
captures their runtime/request identity. SwarmView uses the same rendered actions
for pointer and keyboard. The shell lets scoped action keys precede its leader
shortcut after menus, pending chords and text fields have had priority.

**Constraints:** C11+/Lua/SDL3, no new runtime, no provider protocol changes or
second registry. Continue the already authorized agent-control design and commit
and push verified increments. Ito is a design reference; no upstream code copied.

- [x] Add `lua/actionfocus.lua` with `new`, `current(items)`, `move(items,delta)`
  and `clear`. Reconcile by opaque keys, clear missing controls, never choose a
  replacement automatically on activation. Test stable reorder, replacement,
  disabled controls and cyclic traversal in `tests/actionfocus.lua`.
- [x] Extract action construction from `core/swarmview.lua` to
  `core/fleetactions.lua`. External keys capture record, generation, action and
  exact approval request; callbacks retain input revisions and use Fleet control.
  Internal callbacks capture actor/request objects and reject replacements.
  Global toolbar actions have explicit stable keys.
- [x] Add a shared wrapped layout helper in `core/widgets.lua` so narrow toolbar
  and detail rows retain their controls. SwarmView builds a visible action list
  from rendered hits, draws a focus border, handles Tab/Shift-Tab, Enter/Space,
  roster arrows and Escape. Plain Space keeps its leader meaning on the roster.
  Escape returns to roster; explicit Stop remains available. Scope action keys
  through `shell/modal.lua` without stealing text entry or menus.
- [x] Add `tests/studio_fleet_keyboard.lua` using SDL event injection and a real
  Boggart control fixture. Exercise prompt/steer/interrupt, exact approvals,
  restored focus after command entry, pasted newline without activation, roster
  updates, stale runtime/request actions, narrow layout, internal actor controls,
  foreign observation-only actions and keyboard New agent/Focus/Stop. Keep the
  test in the actual application loop and register it in CMake.
- [x] Run normal/sanitizer affected tests and real SDL, inspect focus rendering,
  update control docs/evidence and BMUX-69 criteria, review changes, signed-off
  commit and push. Leave broader provider and durable-ownership tickets open.
