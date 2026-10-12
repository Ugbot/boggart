# Faster and less crashy: what to borrow, what to move to C

Status: **plan**, 2026-09-29. Sources:
- a survey of `~/ds4` (MIT; mostly antirez's plain C99, no shared util library, so pieces are copied out one at a time);
- a survey of `~/Venus` (C11, "Tiger Style" asserts, MSVC plus clang, sanitizer wiring);
- a measured hotspot survey of boggart itself.

**Rule:** move a Lua function to C only where it was **measured** hot or is a
**crash** hazard. Every C replacement:
- keeps the Lua version as its fallback and its test oracle;
- is checked against the Lua version on the same inputs in the tests;
- is built under ASan/UBSan (T1-5) before it ships.

## What the evidence says

| Finding | Evidence |
|---|---|
| Studio/TUI segfaults | 3 crash reports, all `envelope_encode` (`luaL_Buffer` grown while the stack moved). Fixed and tested (uncommitted). The 23:44 one came from a process still on the old binary. |
| Exit aborts | 2 crash reports, ggml Metal teardown. Fixed 2026-09-25 (voice shutdown at exit). |
| Pure-Lua SHA-256 | **227 ms/MB**. Imports hash every file and then every record; the story mirror hashes the whole book on each sync. |
| Pure-Lua JSON | **41 ms encode / 126 ms decode** for a 2.4 MB transcript. Every turn encodes the session, *decodes it back* for the full-text index, and `api.lua` re-encodes the whole transcript (plus a Lua UTF-8 byte loop) on every model round: quadratic over a session. |
| TUI streaming render | An 80 KB reply takes **30 ms per render** and is re-parsed in full every frame (33 ms budget); the backlog is flattened every paint. |
| Latent crash hazards | `lauth.c` returns static buffers and reloads globals with **no mutex**, while sub-agents make HTTP calls on pool threads. `lhttp.c` keeps a `luaL_Buffer` open across a Lua callback, the same shape as the segfault. Also: a handle leak in `ldb.c` on OOM, and rotating static error buffers in `lmcp.c`. |
| SQLite | WAL and busy_timeout are fine. But there is **no prepared-statement cache**, and the story reindex runs with no transaction. |
| Memory growth | TUI entries and their render caches are never trimmed. `collectgarbage("count")` undercounts strings, so memory growth can't be seen from Lua. |
| Not a problem | SSE line splitting: 7–13 ms for 1.9 MB. It is left alone unless C JSON makes it the bottleneck. |

## The plan

### Tier 1 — crash-proofing

| # | Item | Source | Effort |
|---|---|---|---|
| T1-1 | **`lauth.c` thread-safe.** A mutex around load/save and state; caller-owned (or `_Thread_local`) output buffers instead of `static char hdr[]`/`p[]`. | fresh | S |
| T1-2 | **`lhttp.c` owned body buffer.** The ds4 `buf_*` pattern (overflow-checked, grow, one `lua_pushlstring` at the end), as already done for `lstation.c`. Also free `o.p` on the OOM path there. | ds4 `ds4_server.c:120-175` | S |
| T1-3 | **Always-on boundary asserts.** `BOG_ASSERT` survives release builds, logs file:line, flushes, and traps. Used at the C/Lua boundary: stack depth, userdata type, non-NULL, `lua_checkstack` in loops that push. | Venus `venus_assert.h`, `venus_ds_common.h` | S |
| T1-4 | **Crash handler.** Details below. | fresh (POSIX), Venus `venus_crash.c` (Windows), ds4 `ds4_eval.c` terminal restore | M |
| T1-5 | **Sanitizer builds.** `BOGGART_SANITIZER=address\|undefined\|thread` applied per target, never globally (Venus's `venus_apply_sanitizer`: global flags break build-time tools). Plus a `run_gates.py`-style ctest runner that fails on "0 tests ran". Run ASan+UBSan over the whole suite, and TSan over the worker/pool tests. | Venus `cmake/helpers.cmake`, `tools/run_gates.py` | M |
| T1-6 | **Small leaks and hazards:** the `ldb.c` open-before-userdata leak, `lmcp.c`'s rotating `g_err`, and `lterm.c`'s static line. Plus explicit ordered shutdown for anything on Metal (join submitters → wait for the GPU → free in reverse, on the main thread), per ds4's `ds4_engine_close`. | fresh + ds4 pattern | S |

T1-4 in detail:
- **POSIX:** `sigaction` on SEGV/BUS/ILL/FPE/ABRT with an alternate signal stack. It prints `backtrace_symbols_fd` plus a *Lua* traceback (captured safely) and classifies the fault (near-NULL vs wild pointer).
- **The terminal:** always restored (termios, cursor, alternate screen) before re-raising.
- **Where it goes:** a crash file in `~/.boggart/crashes/` alongside macOS's report.

### Tier 2 — crunchy Lua functions moved to C

| # | Item | Source | Expected win |
|---|---|---|---|
| T2-1 | **`bog.json` in C** over the already-linked **cJSON**: `encode` (with sorted keys, for the canonical JSONL mirrors), `decode`, `json.null` kept, the same error shape. `json.lua` stays as the fallback and the oracle. Plus a **C UTF-8 validator/repair** replacing `util.to_valid_utf8`'s byte loop, and ds4's `utf8_stream_safe_len` for SSE deltas split mid-character. | cJSON (vendored), ds4 `ds4_server.c:1076-1110` | 10–50× on 2.4 MB (estimate; to be measured) |
| T2-2 | **Stop decode-after-encode on save.** Build the FTS text from the in-memory messages, not by decoding the row just written. | fresh (Lua) | removes ~126 ms+/turn |
| T2-3 | **SHA-256 in C:** CommonCrypto on macOS, about 150 lines of portable C elsewhere. It keeps `workflow.hash`'s exact output (the tests compare). | fresh | ~227 ms/MB → ~2 ms/MB |
| T2-4 | **TUI incremental streaming render.** Only the growing tail of the streaming entry is re-rendered; a line index replaces the per-frame flatten. If it's still hot after that, a C markdown→runs renderer. | fresh (the studio already does incremental layout) | 30 ms/frame → about constant |
| T2-5 | **SQLite prepared-statement LRU cache** in `ldb.c`, keyed by SQL text, finalized on eviction and close. Transactions around the story reindex and mirror import. | Venus `stmt_cache.c` + `venus_lru` pattern | fewer prepares; reindex N autocommits → 1 |
| T2-6 | **Story-module scanners in C,** only after measuring on ~/novel. The candidates are the checker's token/pattern counting over a chapter, the baseline fingerprint, and the slop n-gram profile. They would become a small `textscan` C module (word/sentence split, counts, n-grams) behind the same Lua API. | fresh | measure first |
| T2-7 | **SSE line splitter in C,** only if C JSON makes it the bottleneck. | fresh | — |

### Tier 3 — memory

| # | Item | Source | Effort |
|---|---|---|---|
| T3-1 | **Per-subsystem memory accounting:** a tagged allocator with live/peak per tag (HTTP, JSON, SQLite, TUI, Lua) and a Lua allocator (`lua_setallocf`) that counts, surfaced in `/status` with `sys.membytes`. It answers "why is the TUI that's been open for days big?" | Venus `venus_mem_tag` | S |
| T3-2 | **TUI transcript window:** drop the render cache of entries far off-screen, and cap the in-memory backlog (the store keeps everything). Try generational GC in the host. | fresh | S |
| T3-3 | **Studio idle loop and font leaks:** don't redraw a focused idle window at frame rate; free fonts and atlases on dropped `FREE_FONT` in `rencache.c`. | fresh (+ Venus's Clay word-measure cache idea for layout) | M |

### Tier 4 — lazy loading, and the libuv we already link but don't use

**How files are loaded today:**
- The model's `read` tool (`lua/tools.lua:60`) loads the **whole file**,
  splits **every** line into a table, then returns 120 of them. Its 16 MiB
  check runs *after* the full read.
- The studio's `Doc:load` (`studio/data/core/doc/init.lua:69`) builds a Lua
  table of every line, synchronously, on the UI thread.
- Imports read whole transcripts with `read("a")`.

All of this is blocking `io.open` on the loop thread. A 500 MB log freezes the
studio and takes several times its size in RAM.

**What boggart uses from libuv today:** processes, pipes, timers, TCP, async
handles, its own threads and mutexes, and a few file calls (stat, scandir,
chmod). Every one of those file calls passes a `NULL` loop, so it's
**synchronous**.

**What it leaves on the table:**

| libuv feature | Not used today | What it would fix |
|---|---|---|
| `uv_queue_work` (the built-in threadpool) | 0 uses | Runs hashing, JSON decode of big files, indexing and imports off the loop thread, so the UI never stalls. It's free; boggart currently hand-rolls `lworker` threads for this. |
| async `uv_fs_open/read` with offsets | 0 (all `io.open`) | Ranged reads without loading the file; non-blocking reads for big files. |
| `uv_fs_event` / `uv_fs_poll` (file watching) | 0 | Replaces **polling**: the auth file stat on every call, the story mirror hash on every sync, the studio's mtime checks and treeview syscall every frame (P4), and the story index's stat-per-file. A watcher fires once, when something changes. |
| `uv_prepare` / `uv_check` / `uv_idle` | 0 | Proper frame scheduling: paint once after a burst of events, not at a fixed rate. That fixes the studio idle spin (T3-3) and coalesces TUI paints. |
| `uv_metrics_idle_time` / `uv_metrics_info` | 0 | **Loop-lag measurement:** how long the loop was blocked, and by what. That turns "the studio feels janky" into a number, and the tests can assert on it. |
| `uv_signal` | 0 | SIGWINCH/SIGINT/SIGTERM delivered as loop events (clean terminal restore, resize), alongside the crash handler for SEGV (T1-4). |
| `uv_tty` | 0 | Raw mode and window size the same way on macOS, Linux and the Windows console. |
| `uv_fs_opendir/readdir` | 0 | Streaming large directory walks instead of `glob()` building everything at once. |
| `uv_resident_set_memory`, `uv_get_available_memory`, `uv_get_constrained_memory` | 0 | Memory gauges for `/status` and the watchdog (T3-1). |
| `uv_os_setpriority` | 0 | Indexing, imports and the station daemon at background priority. |
| `uv_dlopen` (shared libraries) | 0 | Optional pieces (voice/whisper, ds4, station) loaded at **runtime** when present, instead of a separate build per flag. That's a bigger change; noted, not scheduled. |

**Plan:**

| # | Item | Effort |
|---|---|---|
| T4-1 | **Lazy file views in C** (`src/lfile.c`; details below) | M |
| T4-2 | **The `read` tool on views:** stat first and refuse/cap before reading; return the requested lines without loading the rest; `whole=true` is capped too. Big files get a total like "of ≥N lines (indexing)" until the index finishes. | S |
| T4-3 | **Studio large-file mode.** Above a threshold (8 MB, configurable), `Doc.lines` becomes a proxy over a view: `__index` fetches lines with a small LRU of decoded lines, and `__len` gives the line count. The file is **read-only** with a status-bar note, and syntax highlighting covers only what's visible. Opening is instant, and memory is about the size of the line index. Editing huge files (a piece table) is a later step. | M |
| T4-4 | **`uv_queue_work` bridge for Lua:** `sys.work(kind, args)` runs a C job (sha256, json decode of a file, index build, file read) on the libuv pool. It yields to the scheduler's `io` protocol, so a coroutine sleeps while the main loop keeps painting. | M |
| T4-5 | **Watchers instead of polling:** `sys.watch(path, fn)` on `uv_fs_event`, with `uv_fs_poll` as the fallback for network filesystems. Applied to the auth file, the story mirror and book roots, and the studio's agent-written panels and tree. | S–M |
| T4-6 | **Loop-lag metrics:** `uv_metrics_idle_time` sampled into `/status` and telemetry, with a warning when a callback blocks the loop for more than 50 ms, naming the callback. That is how we find the next thing to move off the loop. | S |
| T4-7 | **Frame scheduling with `uv_prepare`/`uv_check`:** the TUI and studio paint at most once per loop turn, and only when something changed. | M |
| T4-8 | `uv_signal` for SIGWINCH/SIGINT/SIGTERM, `uv_tty` for raw mode, and libuv memory gauges in `/status`. | S |

T4-1 in detail, the view object `sys.view(path)`:
- **Opening:** `mmap` on macOS/Linux, `CreateFileMapping` on Windows, with an `uv_fs_read`-with-offset fallback for files that can't be mapped.
- **The line index** is built **incrementally on the libuv threadpool**: offsets in chunks, using `memchr`.
- **Methods:**
  - `count()` (partial while indexing, with a flag);
  - `line(i)` and `lines(i, j)`;
  - `tail(n)`, which scans back from the end with no index (for logs);
  - `find(needle, from)`, a `memmem` scan with no Lua strings;
  - `size()`, `close()`.
- **Lifetime:** `__gc` unmaps. The view checks for truncation/replacement (same inode, size) and refuses a stale read rather than faulting on a page that no longer exists.
- **Tests** run on a 200 MB generated file. They time opening and reading line 1,000,000, check the memory ceiling, and confirm the loop stays responsive while indexing.

Order: T4-6 (measure first), then T4-1 + T4-2, T4-4, T4-3, T4-5, T4-7,
then T4-8. T4-6 goes in early so every later change shows its effect on loop
lag.

### Not taking, and why

- **ds4's DeepSeek tool-call/`<think>` stream parsers.** They belong to the ds4 embedding work (`docs/ds4-abi.md`), and ds4 should expose them as `ds4_dsml.{c,h}`. Copying them now would drift from ds4.
- **ds4's kvstore.** It's a KV-cache snapshot store for model sessions, not a general cache.
- **Venus's lock-free kit, job system and netcode.** Nothing measured needs them yet. The triple buffer is noted for a future "studio renders the latest transcript snapshot".
- **Replacing ZMQ with ds4's TCP framing.** It has no async I/O, and ZMQ works.

## Running the sanitizer builds (BOG-10)

```
cmake -S . -B build-asan -G Ninja -DBOGGART_SANITIZER=address,undefined -DBOGGART_STATION=ON \
      -DBOGGART_VOICE=OFF -DBOGGART_BUILD_APP=OFF -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build-asan
ASAN_OPTIONS=detect_leaks=0 tools/run_gates.py build-asan -j8            # whole suite

cmake -S . -B build-tsan -G Ninja -DBOGGART_SANITIZER=thread -DBOGGART_STATION=ON \
      -DBOGGART_VOICE=OFF -DBOGGART_BUILD_APP=OFF -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build-tsan --target boggart auth_threads_test
TSAN_OPTIONS=halt_on_error=1 tools/run_gates.py build-tsan -j4 --timeout 300 \
      -R '^(worker|swarm|bus|fabric|http_body|json_c|auth_file|station|looplag|auth_threads)$'
```

**Notes:**
- Sanitizer trees write their binaries into the build directory, never the
  repo root.
- `tools/run_gates.py` fails when no test ran, when a test was "Not Run", and
  on real failures.

**What TSan found (2026-10-02):** races reported in `jwriter.c` and in the
`lworker.c` rings.
- **The cause:** both hand slots between threads through `uv_sem_t`.
  libuv's semaphores are Mach semaphores on macOS, and TSan cannot see them.
- **Real bug, or not?** No. The hand-offs are correct, because
  `post`/`wait` is a happens-before edge, and `jwriter.c` documents that
  design choice.
- **The fix:** mark the edges with `src/bogtsan.h`, which provides
  `bog_sem_post`/`wait`/`trywait` and the `BOG_TSAN_*` annotations. These are
  no-ops outside TSan.
- **One genuine tightening:** `lworker`'s `accepting` flag is now a C11
  release/acquire atomic.

**`proc` is excluded from TSan:** it forks from a multithreaded process, and
TSan hangs on that (a known TSan limitation, not a race).

## Order

Recommended: T1-1, T1-2, T1-3, T1-4, then T1-5 (the sanitizer run will then
check everything that follows), then T2-1 + T2-2, T2-3, T2-4, T2-5, T3-1,
T3-2, T1-6, T2-6 (after measuring), T3-3.

Each item ships with a test and a before/after number where it's about speed.
