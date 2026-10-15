# Semantic terminal input verification — BMUX-74

BMUX-74 supplies server-native input for the attached Studio view work. It does
not complete BMUX-34: native wire-image rendering, a remote pane adapter and
visible attach/control actions remain. API: [server-native input](../bmux-terminal-input.md).

## Evidence

- `tests/c/terminal_input.c::batches`: exact application-cursor key, bracketed
  Unicode paste, focus and SGR mouse bytes; one sink call; refused-sink focus/
  motion rollback; late invalid kind, encoded overflow and accepted empty output.
  A temporary standalone test linked a batch implementation with rollback
  deliberately removed: **exit 1, line 24**. The unchanged product implementation
  passes in normal and sanitizer builds. Red log:
  `build/semantic-input-rollback-red.log`.
- `tests/terminal_input_events.lua`: a separate real serve daemon owns a raw
  child PTY. A four-event batch is compared with a child-produced hex oracle.
  A lost acknowledgement retries the same request bytes with one accepted
  effect, including after child exit. Late invalid native keys emit no earlier
  focus report and consume no sequence. Unknown/cyclic fields, source bounds
  and mutually exclusive raw/semantic wire forms fail. Two independent replicas
  converge to the same final screen, input state and exit status 7/EOF.
- The same test verifies focus changes with **zero encoded bytes** are accepted
  and pushed, and forces GC to close native PTY owners during argument staging.
  Staged strings stay rooted and native owners are reacquired after validation.
- `tests/terminal_push.lua` verifies a Kitty-mode-only change pushes a new
  coherent frame even without cell damage. Existing key/mouse/paste, local
  Studio SDL/IME/Kitty and native terminal lifetime tests verify compatibility.

The raw-byte oracle initially failed to find an output marker split across
terminal rows; whitespace normalization now precedes marker matching and exact
hex comparison remains. A sanitizer run also caught a fixture readiness race:
private socket creation precedes listen. Fixtures now wait for an actual
read-only health response before mutations; the readiness flag uses a distinct
name from the existing ready-image path. These failures were fixed and not
counted as passes.

## Final checks

Both normal and ASan/UBSan RelWithDebInfo builds completed successfully.
The final affected set passed **27/27 normal in 17.53s** and **27/27 ASan/UBSan
in 23.68s**. Logs: `build/semantic-input-all-final.log` and
`build-asan/semantic-input-all-final.log`. Coverage includes native key/mouse/
paste encoders and negotiation, batch transaction, legacy input controller,
GC/lifetime, actual daemon/client/attachments/push, generic SSE, scoped control,
Studio native terminal/cluster rendering, Bmux, agent control and Fleet keyboard.

The strict normal reconnect regression also passed after the new metadata:
**30.698ms** attach through validated replay and **36.095ms** including killed
client/reap/rejoin. This is one regression observation, not a new latency
distribution; the eight-sample gate remains documented separately. Log:
`build/semantic-input-reconnect-final.log`.

C11 `-Wall -Wextra -Werror -fsyntax-only` passes for `lterminal.c`,
`lterminal_input.c` and `bterm_input_batch.c`. The pinned Ghostty attribution
verifier still passes 44 modules/34 ported files. CLI/Studio build source hashes
include the extracted input binding and new native transaction module. Diff
checks pass. No new runtime, client-side VT parser or upstream code copy.

Reproduce focused checks:

```sh
ctest --test-dir build \
  -R '^(terminal_input|terminal_input_events|terminal_input_route|terminal_push|studio_terminal_native)$' \
  --output-on-failure
ctest --test-dir build-asan \
  -R '^(terminal_input|terminal_input_events|terminal_input_route|terminal_push|studio_terminal_native)$' \
  --output-on-failure
BMUX_RECONNECT_GATE=1 ctest --test-dir build -R '^terminal_client$' -V
```
