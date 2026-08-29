# boggart ↔ ds4: a direct in-process ABI

Status: **design, for review by boggart and ds4 authors — 2026-08-30.** Not built.
This is a cross-repo contract. The build (an `src/lds4.c` module + a new `api.lua`
wire) is downstream of agreement here.

## Why

Every boggart turn against the local ds4 model goes:

```
boggart → curl → HTTP → ds4-server parses Anthropic JSON → engine → serialize JSON → SSE → boggart parses
```

Two JSON round-trips, HTTP framing, and SSE — per turn, on loopback, for data that
never leaves the machine — plus boggart **re-transmits the whole transcript every
turn** even though ds4 already holds its KV. For a *local* engine that is pure
overhead.

The decision (made): a **direct in-process ABI** — boggart links ds4's engine and
holds a **stateful `ds4_session` per conversation**. This removes HTTP/JSON/SSE
*and* the re-transmit: the KV lives in-process, so continuing a conversation is
"append the new turn's tokens and decode," with ds4's own prefix reuse handling
the rest. Accepted costs, spelled out in §7: boggart co-resides ds4's ~81 GiB
model (it becomes the model host — no separate `ds4-server`), a model crash takes
boggart down, and swarm agents on ds4 run serially in v1.

This is also the first real consumer of boggart's worker-thread + bus fabric
(`docs/actors-and-bus.md`): the engine runs on a dedicated thread, tokens stream
back over the rings/bus, and the `lua_sethook` safepoint kill stops a runaway
generation.

## What's established (from exploring ~/ds4)

- **`ds4.h` is already a narrow, deliberate engine boundary** ("Keep this header
  narrow so HTTP/CLI code does not depend on tensor internals"), with **four
  existing non-server consumers** — the CLI, bench, eval, and agent binaries — so
  a fifth consumer is a well-trodden path. `ds4_server.c` is pure HTTP+JSON glue
  on top; no engine code depends on it.
- **No library artifact today.** The engine is the `CORE_OBJS` object group
  (`~/ds4/Makefile:27`, `= ds4.o ds4_distributed.o ds4_tp.o ds4_ssd.o ds4_metal.o
  ds4_layer_pack.o`; CUDA swaps `ds4_metal.o → ds4_cuda.o` + `MMQ_OBJS`). All five
  executables link it (`Makefile:68`). Producing a `libds4.a`/`.dylib` is an
  `ar rcs`/link-flag addition, not a refactor.
- **The executor is serialized.** All model eval is guarded by `inference_mu`
  around each sync/eval (`ds4_server.c:9469,10404,10445,10798`) and a
  `model_mu`/`model_busy` gate coordinates prefill vs decode
  (`ds4_server.c:10387-10415`). Concurrency is *interleaving sessions at token
  granularity through one serialized model*, not parallel `generate` calls.
  **An in-process client must marshal every `ds4_session_*` model call onto one
  dedicated engine thread.**
- **One resident model, loaded once.** `ds4_engine_open` runs at startup
  (`ds4_server.c:13059`); sessions are created against that one engine. The active
  model (`ds4flash.gguf`) is **~81 GiB, mmapped no-copy** into unified/GPU memory,
  plus per-session KV context buffers.
- **The engine speaks raw token ids.** DSML tool-call markup (literal
  `<｜DSML｜tool_calls｜>` / `invoke` / `parameter`, taught by the prompt at
  `ds4_server.c:2078-2090`) and `<think>` reasoning are **ordinary generated
  text**; the *server* parses them (`dsml_decode_*`, `thinking_state_feed`) into
  structured `tool_use` / thinking. That parsing is the one substantial thing an
  ABI client would otherwise have to own — see §4.
- **ds4 already reports cache stats** in the standard fields
  (`cache_read_input_tokens` / `cache_creation_input_tokens`,
  `ds4_server.c:7555-7564`), computed from `common = ds4_session_common_prefix(...)`
  — so the ABI path lights up boggart's existing cache KPI for free.

## The ABI, from `ds4.h` (candidate surface)

Opaque handles `ds4_engine` (loaded model) and `ds4_session` (one KV timeline),
`ds4.h:59-60`.

| Purpose | Function(s) | `ds4.h` |
|---|---|---|
| load / free the model (once) | `ds4_engine_open` / `ds4_engine_close`; `_vocab_size` | 199 / 221 / 223 |
| session lifecycle | `ds4_session_create` / `ds4_session_free` | 330 / 331 |
| prefill with KV reuse | `ds4_session_common_prefix` + `ds4_session_sync` | 365 / 360 |
| decode step | `ds4_session_sample` / `ds4_session_argmax` → `ds4_session_eval` | 370 / 366 / 385 |
| tokenize / render chat | `ds4_tokenize_rendered_chat`, `ds4_encode_chat_prompt`, `ds4_chat_*` | 301 / 303 / 302-311 |
| detokenize / stop | `ds4_token_text`, `ds4_token_eos`, `ds4_token_is_stop` | 313 / 314 / 315 |
| snapshot (for resume) | `ds4_session_save_payload` / `_load_payload` | 461 / 462 |
| (batched, later) | `ds4_sessions_eval_batch` | 395 |

There is a convenience `ds4_engine_generate_argmax(engine, prompt, n_predict, …,
emit, done, …)` (`ds4.h:273`) with a per-token `emit` callback — greedy only,
useful for the phase-2a smoke test but not the real path (no temperature, no stop
strings, no interrupt hook).

---

## 1. The ABI boundary contract

- **ds4 ships a linkable artifact:** `libds4.a` (static, simplest given the mmapped
  weights) built over `CORE_OBJS` (+ the GPU-args object), plus its backend link
  flags surfaced (Metal frameworks on macOS; CUDA + `MMQ_OBJS` on Linux) so a
  consumer can reproduce the link.
- **`ds4.h` is the frozen contract,** carrying an explicit **ABI version**
  (`DS4_ABI_VERSION`, integer, bumped on any breaking signature/struct change).
  boggart checks it at load and refuses a mismatch. Engine internals
  (`ds4.c`/backends) stay free to change behind the header.
- boggart depends on **nothing outside `ds4.h`** (and, per §4, one companion
  parser header). The `ds4_server.c` protocol layer is not linked.

## 2. Responsibility split

| ds4 (engine) | boggart (harness) |
|---|---|
| model load, weights, backends | the turn loop, retries, budgets |
| tokenize / detokenize / chat-template render | assembling `sess.messages` (already Anthropic blocks) |
| sessions, KV reuse, snapshots | one session per conversation; lifecycle policy |
| sampling (temp/top_k/top_p), the serialized executor | driving the decode loop + stop/interrupt decisions |
| **DSML + `<think>` parsing → typed deltas (recommended, §4)** | mapping typed deltas → Anthropic content blocks + `on_text`/`on_think` |
| cache-stat accounting (`common_prefix`) | surfacing `cache_read/creation` in the KPI (already wired) |

## 3. Decision: who parses DSML tool-calls + `<think>`?

**Recommendation: ds4 owns it, exposed as library functions.** The DSML markup and
the `<think>` convention are *defined by ds4's chat template and model*
(`ds4_server.c:2078-2090`); the parser belongs with the producer. Reimplementing
the state machine in boggart invites silent drift — if ds4 changes the markup, a
boggart-side parser mis-slices tool calls with no error. ds4 already has the
tested decoders (`dsml_decode_*`, `thinking_state_feed`); they are simply in the
wrong translation unit.

Concretely: **move `dsml_decode_*` + `thinking_state_feed` out of `ds4_server.c`
into a shared unit** (`ds4_dsml.c` / `ds4_dsml.h`) that both `ds4-server` and
`libds4` consumers use. boggart feeds the detokenized text stream through
`dsml_decode_tracker_update` + `thinking_state_feed` and receives typed spans
(text / thinking / a completed tool_use with parsed args), which it maps to
Anthropic blocks. boggart still owns the *loop* (so it controls stop + safepoint
kill); ds4 owns the *parsing*.

Rejected alternative — reimplement in boggart: buys independence boggart doesn't
actually have (it already links ds4), at the cost of a correctness-critical
duplicate that drifts.

## 4. Threading contract

- **One dedicated engine thread** owns the `ds4_engine` and makes every
  `ds4_session_*` call (the executor is serialized — §"established"). It is a
  specialized worker in boggart's pool (`src/lworker.c` pattern): its own thread,
  a job in-ring, a result/token out-ring.
- **boggart callers never touch the engine directly.** A turn (main-loop or a
  swarm coroutine) posts a *generate job* (session handle + new-turn tokens +
  sampling opts) to the engine thread's in-ring and parks; token/typed deltas come
  back on the out-ring and are pumped to the main state, where they drive
  `on_text`/`on_think` — exactly the cross-thread bus path already built.
- **Safepoint kill** interrupts a generation: the decode loop checks a stop flag
  each token (mirroring the server's per-token stop-string check) and returns
  early; boggart's `worker.kill` / supervisor sets it. This needs a **cooperative
  interrupt hook** from ds4 — either a caller-checked flag the loop already honors,
  or a `ds4_session_request_stop(session)` (an ask, §8).
- **v1 is single-session-at-a-time** (serial). The batched `slot_count>1` path
  (`ds4_sessions_eval_batch`, dispatch by longest-common-prefix,
  `ds4_server.c:12205-12234`) is a later parallelism upgrade so swarm agents can
  interleave.

## 5. Session model

- **One `ds4_session` per boggart session** (an opaque Lua handle). Created on the
  first `ds4` turn of that conversation; freed when the session is dropped/GC'd.
- **KV reuse is automatic and local:** each turn boggart renders the full prompt to
  tokens and calls `ds4_session_common_prefix` + `ds4_session_sync` — ds4 reuses
  the resident KV for the unchanged prefix and prefills only the new suffix.
  Because it's in-process, "sending the full prompt" is passing a token-array
  pointer; there is no transmit cost, so caching is *moot* for ds4 — the win is
  built in.
- **Usage** comes straight from `common_prefix`: `cache_read = reused prefix`,
  `cache_creation = freshly-prefilled suffix`, `input = 0` — the disjoint shape
  boggart's cost/KPI already expects.
- **Resume** (`boggart --resume`): `ds4_session_save_payload` on checkpoint,
  `_load_payload` to restore the KV graph, so a resumed conversation continues
  without re-prefill. (Open question §8: cross-process/version portability of a
  snapshot.)
- **Compaction** (boggart rewrites the transcript at 80%) resets the prefix — the
  session's `common_prefix` drops to the new head; expected, same as today.

## 6. Streaming contract

- boggart posts `{ session, prompt_tokens, sampling = {temperature, top_k, top_p,
  n_predict}, stop_flag }`.
- The engine thread runs `sync` (prefill) then the loop `sample`/`argmax` →
  `eval`, emitting each `token` id; boggart's side calls `ds4_token_text` to
  detokenize, feeds the piece through the ds4 DSML/`<think>` decoders (§3), and
  emits typed deltas: **text** → `on_text`, **thinking** → `on_think`, **tool_use**
  → buffered into a `tool_use` block.
- Terminates on `ds4_token_eos` / `ds4_token_is_stop` / a stop string / n_predict /
  the stop flag.
- The assembled result is the **existing** `{ role="assistant", content=blocks,
  usage=… }` shape boggart's decoders already return — so the rest of `run_on` is
  unchanged; only the transport differs.

## 7. Memory, lifecycle & accepted trade-offs

- **~81 GiB co-residency.** boggart becomes the model host: it mmaps the GGUF into
  its own address space (no-copy Metal buffers / CUDA device memory) and **cannot
  also run `ds4-server`** (the model would be held twice). Load is **lazy** — the
  engine opens on the first `ds4`-wire turn, not at boot — so non-ds4 use of
  boggart is unaffected.
- **Crash blast radius.** A GPU/engine fault now takes boggart down (no process
  isolation). Accepted; mitigated by lazy-load (only ds4 users are exposed) and
  the fact that resume can restore session KV.
- **Serial swarm (v1).** One serialized executor → swarm agents on ds4 run one at a
  time. Batched mode is the upgrade path.
- **Build reality.** boggart's build gains a Metal (macOS) / CUDA (Linux) link and
  a model-path config. This is the heaviest part of the eventual build and is
  gated behind a build option (`BOGGART_DS4=on`) so default builds are unaffected.

## 8. What ds4 must provide (the ask) + open questions

Asks:
1. A **`libds4.a`** (or `.dylib`) build target over `CORE_OBJS`, and documented
   backend link flags.
2. A **versioned `ds4.h`** (`DS4_ABI_VERSION`) as the frozen boundary.
3. **DSML/`<think>` parsers moved into a shared `ds4_dsml.{c,h}`** usable by
   library consumers (§3).
4. A **cooperative stop hook** for mid-generation interrupt (a caller-checked flag
   the decode loop honors, or `ds4_session_request_stop`).

Open questions (co-design):
- Is `ds4_session_save/load_payload` portable across ds4 versions / a boggart
  restart, or KV-format-tied (affecting `--resume`)?
- Thread-affinity/NUMA or Metal command-queue constraints on which thread calls
  the engine (does "one dedicated thread" suffice, or must it be the thread that
  opened the engine)?
- Multi-session batched decode as the concurrency story for swarms — is
  `ds4_sessions_eval_batch` stable enough to target in v2?
- Sampling parameter parity: does the lib expose all the knobs the server uses
  (min_p, repetition, speculative/MTP `ds4_session_eval_speculative_argmax`)?

## 9. Downstream build sketch (informative — not this step)

1. **2a — link + smoke.** `libds4.a`; boggart `src/lds4.c` opens the engine on a
   dedicated thread; `ds4.generate(prompt)→text` over `ds4_engine_generate_argmax`.
   Prove in-process generation with no HTTP.
2. **2b — the wire.** `wire()=="ds4"` in `api.lua`: render prompt, stateful session,
   stream text, assemble text-only blocks. A full turn in-process.
3. **2c — structure.** Wire the ds4 DSML/`<think>` decoders → `tool_use`/thinking
   blocks; temperature sampling; stop handling.
4. **2d — fabric + control.** Engine thread as a pool member; deltas over the bus;
   safepoint kill; session lifecycle + resume snapshots.

Verification then: smoke generation offline; a `wire=ds4` one-shot; a multi-turn
conversation showing KV reuse (`cache_read` climbing, no re-prefill); a tool turn
parsing DSML into a real `tool_use`; a safepoint kill halting a long generation.
