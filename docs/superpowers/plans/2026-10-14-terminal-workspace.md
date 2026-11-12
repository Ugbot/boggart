# Studio BMUX workspace implementation plan

**Goal:** Add the user-requested BMUX mode beside AGENT/EDIT/FLEET, with
visible terminal tab/split controls and live shells preserved across switches.

**Architecture:** Reuse native C PTYs/grids and the existing Lua Node tab/split
tree. A terminal workspace module owns shell creation and a compact toolbar.
Detach/restore its content subtree when switching modes; keep docks outside it.
Other modes keep their existing switching behavior. No Python or new dependency.

- [x] Register BMUX mode, menu entries and app-owned shortcuts. Entering it
  creates one interactive shell; new terminals open tabs in the focused pane.
- [x] Provide wrapping clickable New terminal/Split right/Split down/Close/Zoom/
  Next pane controls. Split actions create real shells, and focus stays visible.
- [x] Preserve terminal tab identities, split dividers, zoom state and focus
  across mode switches without closing PTYs; shell shutdown still owns cleanup.
- [x] Verify through real Studio dispatch: click controls, type into a real PTY,
  switch modes with running shells, restore split/focus, close tabs/panes, and
  exercise narrow-window controls. Run normal/sanitizer affected gates.
- [x] Document controls, record BMUX-61 evidence, save a verified commit and open
  the updated interactive BMUX mode for the user.

This is the Studio mode increment; BMUX-31's shared server/cTUI layout and the
remaining cmux roadmap stay separate.

Final verification: affected normal **10/10** (7.64s), ASan/UBSan **10/10**
(12.06s), and controlled SDL window checks pass. Zoomed close/split restores the
full tree before structural edits, preserving neighbouring shells. The BMUX
test uses `/bin/sh` and an isolated HOME to avoid personal startup scripts.
The live interactive demo was opened in BMUX with two real project shell panes.
