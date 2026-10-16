# BMUX-10: system measurements

The existing parser/draw benchmarks do not establish interactive latency or
whole-application resource use. Keep BMUX-10 open until all measurements below
have raw samples and reproducible commands; BMUX-11 remains the comparison gate.

1. Add an opt-in, script-only SDL presentation probe. After a successful present,
   timestamp with `uv_hrtime`, then read one pixel from the retained scene
   texture. Record the readback cost separately. Never read the invalidated SDL
   window backbuffer. With the probe disabled, do no timing/readback work.
2. Build a small C raw-PTY fixture: each input byte changes cell 1,1 to a unique
   RGB background. Verify bytes through the native parser and pixels through SDL.
3. Measure synthetic SDL key-to-presentation through the real server, controller
   lease, PTY, parser, attachment stream and Studio view. Require a fresh frame,
   the expected RGB, and a bounded deadline for every sample. Report all samples,
   warmups, quantiles, renderer/configuration and source identities. This is an
   application presentation proxy, not physical display/scanout latency.
4. Add a separate-process coordinator for process startup to ready/presented
   terminal, full-policy socket RTT, and idle CPU/RSS at 1/10/100 resident PTYs.
   Report server/client/children separately and exact visible/hidden topology.
   Sum RSS only as an explicitly non-deduplicated sum. Do not flush OS caches or
   call warmed-filesystem launches cold-cache measurements.
5. Run normal/sanitizer correctness tests before uncontended real SDL timing.
   Preserve raw reports with environment/build identities. Set no invented
   performance pass thresholds before the BMUX-11 same-machine baseline.

SDL contracts: [RenderPresent](https://wiki.libsdl.org/SDL3/SDL_RenderPresent)
invalidates the window backbuffer; [RenderReadPixels](https://wiki.libsdl.org/SDL3/SDL_RenderReadPixels)
reads the selected target and is expensive; [ReadSurfacePixel](https://wiki.libsdl.org/SDL3/SDL_ReadSurfacePixel)
converts the returned surface to sRGB RGBA. Pixel validation follows presentation
and its timestamp, so the readback is excluded from the current latency sample
but its perturbation remains disclosed and measured.
