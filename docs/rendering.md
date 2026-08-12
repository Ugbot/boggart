# Studio rendering — the lite-xl visual/perf borrows, on our libuv loop

boggart-studio grew out of rxi/lite; **lite-xl** is the fork that pushed the same
C+Lua base on the three axes we care about — font quality, HiDPI, and CPU/render
efficiency. This is the plan to take *all* of its visual wins and its perf wins,
the latter routed through the **libuv loop boggart already carries** rather than
lite-xl's own machinery. It is grounded in what the studio actually does today
(`studio/src/renderer.c`, `rencache.c`, `main.c`, `studio/data/core/init.lua`).

## What we already have (so we don't "borrow" it back)

Reading the code first saves rebuilding what exists — boggart-studio already
diverged *ahead* of lite here:

| lite-xl feature | boggart-studio status |
|---|---|
| HiDPI / Retina scaling | **Have, and better** — `main.c:get_scale()` measures window-points vs drawable-pixels (correct on Retina, mixed-DPI, and a window dragged between displays); `SCALE` flows to Lua |
| Dirty-rect damage | **Have** — `rencache.c` hashes per-line draw commands and repaints only what changed |
| Smooth scrolling / animation | **Have** — `View:move_towards` + `core.redraw` (`view.lua`) |
| Redraw-on-demand | **Have** — `core.step` only paints when `core.redraw` is set |
| Font fallback chain | **Have** — `fontfallback.c`, with a diagnostic listing |
| Coroutine, non-blocking agent turn | **Have** — the turn is a `core.threads` coroutine; `api.stream_async` yields, nothing blocks |

So the real borrows are narrower and sharper than "port lite-xl."

## The visual borrows that remain

### 1. A hardware-accelerated retained renderer (the big one)
Today `renderer.c` is the lite **software** path: `SDL_GetWindowSurface` +
`SDL_UpdateWindowSurfaceRects`, glyphs rasterised by stb to grayscale coverage
and blitted on the CPU. lite-xl moved to a GPU renderer. Borrow that shape:

- Create an `SDL_Renderer` (GPU) instead of drawing into the window surface.
- Upload each glyph once into a **texture atlas**; draw text as batched textured
  quads. Rects/lines become GPU primitives.
- **Keep `rencache`** — it still avoids *re-issuing* unchanged commands; the
  backend beneath it becomes GPU-composited.

Why it matters here specifically: the studio's whole surface is a growing chat
transcript, and `ninja ui-bench` already asserts *drawing must not scale with the
transcript*. A GPU backend makes long-transcript compositing near-constant-cost
and makes alpha, smooth scroll, and agent-drawn panels cheap. This is a
`renderer.c`/`rencache.c` rewrite behind the existing `ren_*` API in
`renderer.h`, so `docview`/`agentview` and the widget layer are unchanged.

### 2. Font quality without lite-xl's dependencies (a decision to make)
lite-xl's founding change was subpixel/hinted text via **FreeType + AGG** — which
rxi rejected as "huge dependencies," and which would break boggart's
single-self-contained-binary property (`otool -L` shows nothing but libcurl).
Get most of the perceived win *without* that:

- **Gamma-correct (linear-space) alpha blending** in the glyph blit. The current
  path blends coverage in sRGB, which makes antialiased text look thin/muddy;
  compositing in linear space is a small, contained change with a large
  perceived-quality gain, and **no new dependency**. Do this first (Phase 1).
- **Subpixel (LCD) rendering on stb**: rasterise glyphs at 3× horizontal
  oversampling and run an FIR filter to produce R/G/B coverage — stb supports the
  oversampling; the filter is ours. Optional, behind a setting, still no FreeType.
- **FreeType** stays the explicit fallback *if* crisp hinting becomes a headline
  goal — but as a deliberate binary-size decision, the same call we made against
  libgit2, not a default.

### 3. Subsyntax highlighting — code inside the transcript
The transcript is markdown with fenced code blocks: a **subsyntax** problem, which
is exactly what lite-xl added to its tokenizer. Borrow the subsyntax mechanism
into `studio/data/core/tokenizer.lua` so a ```lua block inside a markdown message
is highlighted as Lua. Pure Lua-layer borrow; high visual payoff for a chat-first
UI.

### 4. Multi-cursor — the editor behind the chat
lite-xl's multi-cursor editing, borrowed into `docview.lua`/`doc/init.lua`.
Lower priority (the studio is chat-first, the editor secondary), but it is the
one editor-feel gap versus a modern editor, and it is self-contained.

## The perf work, on the libuv backbone

This is the "use our libuv" piece, and it is the highest-leverage perf change —
bigger than the renderer for *idle* cost.

**Today** (`core.run`, `init.lua`): a fixed loop — `core.step` polls SDL, runs
thread coroutines within a frame budget, then `system.wait_event(0.25)` (an
`SDL_WaitEventTimeout`) when unfocused and `system.sleep(1/fps)` to cap the rate.
libuv is linked and used for fs, but **it is not the event loop** — the loop is
SDL-timed. Two costs follow: the studio wakes every frame even when nothing is
happening, and while it blocks in `SDL_WaitEventTimeout` the **libuv loop is not
pumped**, so a streaming turn can stall exactly when the window loses focus.

**Borrow lite-xl's redraw-on-demand goal, but realise it through libuv:**

- Make **libuv the loop**. Async I/O — the HTTP token stream, subprocesses, file
  watches, timers — runs natively on `uv`, which boggart's transport was already
  built to yield into.
- Feed **SDL events into** it: an `SDL_AddEventWatch` (or a `uv_poll` on the
  platform event descriptor where one exists; a tiny `uv_timer` pumping
  `SDL_PollEvent` as the portable fallback) so input wakes the same loop.
- Run a `uv_timer` at frame cadence **only while an animation is in flight**
  (`move_towards` in progress or a panel marked live); otherwise the loop
  **blocks in `uv_run` at 0% CPU** until I/O or input arrives.
- Keep the cooperative coroutine agent model, but resume it from **uv
  completions** rather than per-frame polling.

Net effect: streaming tokens repaint live regardless of focus (I/O drives the
wake), idle CPU goes to zero (the lite-xl efficiency goal, via the loop we
already have), and draw cost moves to the GPU (§1). The two invariants
`ui-bench` and `ui-check` guard both hold — drawing stays decoupled from
transcript length, and frames still assert what they show.

## Phasing (value ÷ risk)

1. **Gamma-correct blending** — small, contained, no dependency, immediately
   nicer text. Lands on the current software renderer.
2. **libuv-unified event loop** — the idle-CPU + streaming-responsiveness win;
   no renderer change required, so it can precede the GPU rewrite.
3. **GPU retained renderer + glyph atlas** — the big visual/perf lift behind the
   unchanged `ren_*` API; keep `rencache`, keep `ui-bench` green.
4. **Subpixel oversampling; subsyntax highlighting; multi-cursor** — polish and
   editor-feel, each independent.

## Notes

- **Studio-only.** None of this touches the CLI or the `core-parity` surface —
  the renderer and loop are the studio's, so there is no parity risk; only
  `ui-check`/`ui-bench` gate it.
- **License.** lite-xl is MIT, as is rxi/lite, which boggart already credits.
  Borrowing specific algorithms (the atlas approach, the subpixel filter shape,
  the subsyntax tokenizer) is an attribution line, not a new obligation — code
  ours, as with `sketch.lua` from rough.js.
- **Build caveat.** This plan is not yet implemented: it is C/SDL renderer and
  loop work, and the studio cannot be built in every environment (SDL is fetched
  at configure time). Each phase is independently buildable and testable through
  `ui-check`/`ui-bench` where the studio does build.
