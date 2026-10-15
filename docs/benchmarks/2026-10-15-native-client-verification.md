# Native attachment client verification — 2026-10-15

BMUX-72 implements the [Lua/libuv client](../bmux-terminal-client.md) for
BMUX-32 at commit `a5ff9f0`. No new runtime, subprocess HTTP transport or upstream
Ito code is used. Studio/cTUI attached views remain BMUX-34/35. **At this
checkpoint the <50ms gate was not met.** The later BMUX-73
[latency investigation and eight-sample gate](2026-10-15-reconnect-latency.md)
resolves the small-socket-buffer bottleneck; historical numbers below remain
the pre-fix evidence.

## Correctness scope

- Bounded incremental HTTP/SSE framing: byte-fragmented headers and Unicode,
  multiline SSE, duplicate/conflicting lengths, unsupported encodings,
  malformed content types, oversized headers/data, extra/truncated bodies,
  deadlines, cancellation and native handle closure.
- Independent atomic replica: native Unicode clusters, widths, flags, styles,
  OSC 8 links, wrapping, history indices and metadata. Wrong generation/reader,
  gaps, bad geometry/indices/styles/UTF-8 and malformed late rows leave the
  published view/cursor unchanged. Lua fallback decoding gets a nesting guard.
- A separate actual `boggart serve` process owns an 80×24 PTY with 128 retained
  history rows. The fixture emits 64 styled Unicode lines and retains a full
  32-row attachment tail. Two native clients converge to independently attached
  native screen/history across input, resize/reflow and exit status 7/EOF.
- An independent client process attaches, writes its validated image, stays
  alive on the stream, and is killed with SIGKILL. A new native client recovers
  the same PID, exact per-cell screen and nonempty history window. Comparison
  uses deterministic JSON of complete screen/scrollback objects, not plain text.
- Controller takeover rejects the old writer. An accepted input whose response
  is discarded retries identical encoded bytes with one effect. Malformed 200
  acknowledgements and a simulated 500 after an accepted effect remain pending
  until retry. New writes cannot supersede uncertain commands.
- Request admission includes live SSE slots. Exhaustion completes synchronously
  without wedging a session operation. Cancellation before readiness suppresses
  its callback; consumer exceptions close streams. Stale retained cursors require
  explicit reattach, and detach does not destroy the native grid.

The transport parser unit initially could not load before embedding the new
modules; builds resolved that setup failure. The daemon readiness fixture was
corrected to wait for final private socket permissions rather than only inode
existence. A quota fixture initially requested 64 *additional* operations while
an SSE already occupied one of 64 slots; it now fills the actual available
capacity. Those failures were not treated as passing results.

## Measurements

macOS arm64, existing normal and ASan/UBSan builds. These are functional-test
observations on a shared host, not a controlled latency distribution. Normal
and sanitizer regression sets ran concurrently. Repeated observations vary;
no best-case sample is used to pass the parent gate.

At the 28-suite checkpoint:

| Metric | Normal | ASan/UBSan |
| --- | ---: | ---: |
| Fresh attach through validated first stream replay | 113.362ms | 167.363ms |
| Kill old client through ready new attachment | 118.168ms | 176.756ms |
| New process spawn through ready image file | 219.487ms | 237.820ms |
| Protocol inside the independent new process (excludes bootstrap/file write) | 58.936ms | 113.031ms |
| Fresh snapshot request to complete HTTP body | 101.706ms | 131.973ms |
| Client JSON decode, snapshot + replay | 3.501ms | 15.976ms |
| Client frame validation/application | 4.405ms | 14.548ms |

Logs: ignored `build/native-client-tests-verified.log` and
`build-asan/native-client-tests-verified.log`. Earlier normal observations were
132.965ms before optimization and 104.896–131.318ms after it. This variation does
not establish an end-to-end speedup.

The isolated phase fixture
[`terminal_client_profile.lua`](../../tests/fixtures/terminal_client_profile.lua)
uses a 488189-byte native image, the same 80×24 geometry and 32-row tail. The
initial redundant Lua nesting scan cost 30.425–35.627ms per checked decode, while
native decoding alone cost 2.906–3.384ms. The client now uses the existing bounded
C JSON decoder directly and retains the scan only for the Lua fallback.
Reproducible post-change samples (`build/native-client-profile.log`):

| Phase | Three observations |
| --- | --- |
| Native snapshot capture/encode | 8.372, 7.448, 7.584ms |
| Checked native decode | 3.160, 2.804, 3.012ms |
| Native codec alone | 2.983, 2.923, 3.023ms |
| Replica validation/application | 5.251, 5.754, 4.484ms |

The normal full-path result still spends most of its time before the snapshot
body arrives. That interval includes server policy/capture/encoding, scheduling,
socket delivery and client framing/GC; this evidence does not isolate their
individual contributions. Continue measurement on that actual path before
changing scheduler policy or claiming the 50ms target.

## Verification commands and scope

Both builds completed with `CCACHE_DIR=/private/tmp/boggart-bmux-ccache`
and `CCACHE_TEMPDIR=/private/tmp` using `cmake --build <build> -j8`.

The 28-suite checkpoint passed **28/28 normal, 25.54s** and **28/28 ASan/UBSan,
36.26s**, covering native transport/process/shutdown/registry/server/attachments/
watch/push/client, generic SSE, control/UDS, terminal environment, agent control,
Fleet/workers, Studio Bmux/Fleet/provider hooks/keyboard, and native
grapheme/color-emoji rendering. After the final streamed-cursor diagnostic fix,
the three directly affected client suites passed **3/3 normal, 4.08s** and
**3/3 ASan/UBSan, 6.92s**. Final logs are `build/native-client-final.log` and
`build-asan/native-client-final.log`. Final reconnect was 102.581ms normal
(105.849ms including kill/reap) and 207.619ms sanitized (219.009ms including
kill/reap). The final isolated new client observed 27.247ms protocol time in the
normal build; its 175.394ms complete process/file path and the slower primary
rejoin mean this one fast sample does not satisfy the gate.

```sh
ctest --test-dir build -R '^terminal_(transport|replica|client)$' -V
ctest --test-dir build-asan -R '^terminal_(transport|replica|client)$' -V
./boggart --eval tests/fixtures/terminal_client_profile.lua
python3 tools/check_ghostty_port.py
git diff --check
```

Attribution verifier: pinned Ghostty `05dcf887ef51ea27821f20979493306ec3a19149`,
44 modules/34 ported files. Only the existing development verifier uses Python;
the product changes are Lua over existing native C bindings. No C source or
upstream license boundary was changed.
