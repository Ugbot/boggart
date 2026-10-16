# SQLite Bmux runtime journal

BMUX-96, continuing the approved session-restore design and BMUX-95 codec.
Existing C/Lua, SQLite semantic repository, libuv readiness and native owners.

- [x] Add atomic `kv_compare_set(key, expected, replacement)` to the native
  repository/store adapter, and `terminal:plain_tail(lines, bytes)` for immutable
  bounded grapheme text without per-cell Lua allocation. Verify two SQLite
  connections, byte/line caps, hidden cells, whole clusters and GC safety.
- [x] Add trusted registry lifecycle observers and inactive parser previews.
  Preview input/control fails without starting a process. Track default-shell
  restore eligibility privately; drain cwd OSC metadata only within the owner.
  Native terminal rows and attachments retain existing protocol states.
- [x] Add `bmux.capture` for strict checkpoints and cached history after release;
  `bmux.restore` for one owner per saved resource, safe default-shell/Boggart
  resume recipes, and visible inactive fallbacks. Rehydrate through the existing
  constructor and remap every terminal/agent reference; reset host identity.
- [x] Add `bmux.journal` with a named SQLite checkpoint and atomic owner claim.
  Refuse another live owner, recover a dead owner with CAS, coalesce changes
  with a one-shot 250 ms timer, flush before shutdown and never overwrite
  corrupt/changed data. Store/runtime failures remain observable.
- [x] Wire opt-in `control.start{session=...}`, ordinary private-socket daemon
  defaults, `--bmux-session` and scoped `GET /layout/session` status. Existing
  embedded/test control starts remain ephemeral unless explicitly configured.
- [x] Verify real daemon quit/relaunch and crash recovery with layout, cwd,
  history, alias ownership, inactive foreign commands, real Boggart resume ID,
  no automatic model/tool execution, stale host refusal and competing owners.
  Run normal/ASan gates, document limits, commit/push. BMUX-97 still supplies
  client import/recovery controls and final BMUX-33 acceptance.

The owner claim contains a PID and random token, not saved execution credentials.
An alive/reused PID is conservatively treated as owned; explicit recovery is
separate. Each checkpoint write compares the previous bytes atomically. On
import, recipes must be demoted before reaching this trusted local restart path.
