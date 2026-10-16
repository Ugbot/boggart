# Shared Fleet client verification (BMUX-91)

Normal and ASAN/UBSAN RelWithDebInfo builds passed on macOS arm64. The strict
Fleet client plus existing server/layout/terminal/cTUI/Studio attachment set
passed **6/6** in each build: 9.93 seconds normal and 21.88 seconds sanitizer.
Logs: `build/bmux-fleet-client-verified.log` and
`build-asan/bmux-fleet-client-verified.log`. Diff checks passed.

`tests/bmux_fleet_client.lua` verifies:

- Copied complete metadata, malformed/duplicate/sparse IDs, UTF-8, capability,
  request/result and terminal-reference guards; no partial publication.
- Native read/stream/launch permission separation, coherent retained images,
  host pinning, old revision refusal and same-generation retarget protection.
- A real independent daemon and Boggart TUI expose the same PID/session to two
  clients. Local stale/override guards allocate no request; consumed runtime
  refusals and internal failures preserve sequence progress.
- The daemon really creates a foreign process; a fixture drops only its HTTP
  acknowledgement. Another mutation stays blocked, refresh and stream reconnect
  issue no replay, and explicit Retry resends byte-identical content and returns
  the cached receipt. Only one foreign process is created.
- A successful-looking Stop acknowledgement without its receipt remains
  uncertain; exact Retry recovers the original outcome and sequence.
- Owner identity/capabilities remain independent of closing a client. Native
  requests are cancelled and closed clients do not publish later state.

Existing native terminal/Studio attachment tests pass with bounded HTTP error
JSON retention. This is the shared client policy slice; joined Fleet/agent view
controls still require the BMUX-90 presentation adapters.
