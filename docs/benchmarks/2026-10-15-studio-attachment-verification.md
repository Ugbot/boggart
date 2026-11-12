# BMUX-76/77 Studio attachment verification

The backend and visible pane reuse the native UDS client, atomic replica image,
row renderer and server-native semantic input. No PTY/parser is instantiated
by the attached pane. Closing its reader leaves the host process alive.

`studio_terminal_remote` runs a real independent daemon in Studio's central
loop. It checks plaintext HTTP 401 identity, passive observation, coalesced
writer-only resize, ordered native key/paste/focus/mouse/raw bytes, >64KiB paste
and UTF-8 boundaries, explicit idle lease renewal, takeover/revocation, actual
accepted input with a lost ACK and exact retry, fresh-reader reconnect after
revocation, atomic 32MiB queue admission/rejection, and same-PID detach. A private
test-only control overlay shortens its host lease to 3 seconds; production
defaults remain unchanged.

`studio_terminal_attached` uses SDL's event queue to submit the socket prompt,
filter/select a server terminal, click controller actions, type committed
Unicode, paste, focus, report mouse and execute reserved Ctrl-Alt shortcuts.
It checks first attachment follows the live screen, exact real-pane body pixels
against an independent reader/native image, nonempty history, passive window
resize, explicit takeover, View only, Reconnect, same-PID close/reopen and a new
server shell. It captures `attached-pane.bmp` under its isolated test home.
The existing narrow-window Bmux test verifies all eight toolbar controls fit.

Testing exposed and fixed chooser matching against table addresses, initial
attachment staying at the history top, and the need to keep the error line's
height stable to prevent resize/error feedback. The input queue accepts new
keystrokes while one command awaits its ACK; an uncertain result discards only
unsent input and preserves the exact pending command. The Unicode paste test
also covers a multibyte scalar crossing the 16KiB split point.

Earlier concurrent runs during heavy host load timed out and are not passes.
The original half-second fixture lease also expired during a large-paste quota
test; the fixture now gives a 3-second scheduling margin while still testing
renewal. The production 10-second lease and ownership checks were not relaxed.
The renewal assertion now waits for the completed acknowledgement rather than
sampling a possibly in-flight renewal at a fixed time. Functional integration
tests have a 60-second overall cap; no performance gate was relaxed.

Final normal checks passed **12/12 in 30.62s**. ASan/UBSan passed the attachment
set **9/9 in 43.78s**, plus the three local agent/Fleet regressions **3/3 in
21.99s**. Logs: `build/attached-verified-final.log`,
`build-asan/attached-verified-final.log`, and
`build-asan/attached-fleet-final.log`. Both RelWithDebInfo builds completed.
The real desktop SDL run (without the dummy driver) also exited **0** after the
same visible chooser/control/input/pixel/rejoin checks. Its log is
`build/attached-real-sdl.log`; screenshot:
`build/testhome/studio_terminal_attached_real/attached-pane.bmp`.
The final explicit IME preedit assertion also passed in normal (**10.40s**) and
ASan/UBSan (**13.12s**) focused runs; logs are `attached-ime-final.log` in each
build directory. The IME-inclusive desktop run also exited 0, recorded in
`build/attached-real-sdl-ime.log`.

Review covered bounded FIFO ordering/admission, input-mode ownership, exact
uncertain retry, renewal cancellation, passive geometry, detach lifetime,
read-only replica publication, credential binding, and local pane compatibility.
The software SDL screenshot was inspected: the controls are visible, with
native Unicode/color emoji and nonempty history in the terminal body.

BMUX-76 and BMUX-77 deliver the backend and visible attachment flow. BMUX-34
retains its declared BMUX-24 (remaining instancing contract) and BMUX-31 (shared
layout model) dependencies and stays in progress; this checkpoint does not
claim those requirements or the broader cmux roadmap are complete.

```sh
ctest --test-dir build \
  -R '^(terminal_transport|terminal_client|terminal_input|terminal_input_events|studio_terminal_remote|studio_terminal_attached|studio_terminal_native|studio_terminal_image|studio_bmux)$' \
  --output-on-failure
# Repeat with --test-dir build-asan.
```
