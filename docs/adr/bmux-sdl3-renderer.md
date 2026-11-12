# ADR: Keep the Bmux terminal on SDL_Renderer geometry batching

## Status

Accepted for the current Bmux renderer milestone, 2026-10-17.

## Context

The Studio terminal has a native C visible-row cache, dirty-region replay and
shared GPU glyph atlases. Its renderer submits textured triangles through
`SDL_RenderGeometry`. That API takes vertex and index arrays; a geometry batch
is not a hardware-instanced draw. SDL's lower-level GPU API exposes an explicit
instance count through `SDL_DrawGPUPrimitives`, but using it requires owning a
GPU render pass and graphics pipeline.

The project pins SDL 3.4.14. In that version, `SDL_GPURenderStateCreateInfo`
lets the SDL GPU renderer replace the fragment shader and add fragment
resources. It does not expose a vertex shader, vertex/instance layout or draw
instance count for a renderer command. A true instanced terminal path therefore
means taking over GPU submission for Studio or maintaining an SDL renderer
backend change; it cannot be added to the current public geometry call.

## Decision

Keep the current SDL_Renderer path for terminal rows. Describe it as indexed
geometry batching, never hardware instancing. Retain C row caching, damage
replay and shared style atlases. Do not replace Studio's renderer or fork SDL
for instancing until a flood/full-app profile shows terminal rendering is a
material part of the latency or frame-budget failure.

## Alternatives considered

- **Own a complete SDL_GPU renderer for Studio.** This would allow explicit
  instance buffers and draw counts, but requires replacing the renderer
  contract for the entire editor UI and maintaining shaders for supported GPU
  backends. Current draw measurements do not justify that scope.
- **Fork or extend SDL's GPU renderer internally.** This could preserve the
  high-level SDL_Renderer API, but would depend on private backend command
  submission and add a maintained SDL patch across platforms.
- **Keep measured SDL_RenderGeometry batching.** This preserves the current
  Studio renderer, shared atlas behavior and portable geometry path. It is the
  selected option while whole-app/flood evidence is collected.

## Evidence and limits

The four-style Metal corpus reduced 400 glyph batches and 399 texture switches
to 2 batches and 0 switches. Its one-row-dirty CPU median changed from 0.535 ms
to 0.412 ms; presentation-inclusive wall time changed from 8.570 ms to 8.434
ms. These measurements establish the atlas/batching benefit, not instancing or
whole-app latency.

A 200-sample real Metal run at a 120 fps frame cap measured synthetic
key-to-present p50/p95/p99 of 14.651/25.583/28.566 ms. It used one idle
server-owned PTY and did not exercise `yes`, large `cat`, or a cmux/Ghostty
comparison. The 60 fps capture used a different build, so these runs do not
isolate the frame-cap effect. The 120 fps capture is in
[`2026-10-17-studio-key-present-120.json`](../benchmarks/2026-10-17-studio-key-present-120.json);
the benchmark boundary and limitations are documented in
[`termbench.md`](../termbench.md).

The measured key-to-present failure does not establish that glyph rendering is
the bottleneck. BMUX-28's flood and frame-pacing gate remains separate work. If
that work identifies renderer cost as material, reopen this decision with a
small SDL_GPU prototype and a same-machine end-to-end comparison before
replacing the production renderer.

## SDL references

- [`SDL_RenderGeometry`](https://wiki.libsdl.org/SDL3/SDL_RenderGeometry)
  submits triangles from vertices and indices.
- [`SDL_DrawGPUPrimitives`](https://wiki.libsdl.org/SDL3/SDL_DrawGPUPrimitives)
  accepts an explicit `num_instances` argument.
- [`SDL_GPURenderStateCreateInfo` in the pinned SDL 3.4.14 source](https://github.com/libsdl-org/SDL/blob/release-3.4.14/include/SDL3/SDL_render.h)
  exposes a fragment shader and fragment resources, not an instance layout or
  draw count.
