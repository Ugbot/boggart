# Linux runtime qualification — 21 September 2026

Source snapshot: committed `38d39bd` (includes historical imports `7b1ee37`).
This check excludes the working tree's uncommitted retention work and unrelated
user changes. It qualifies the CLI/runtime at this revision, not the final
process-learning product, Studio, native extensions or Windows.

## Results

A fresh Release build of `boggart` succeeded on Linux ARM64 with Clang 19.1.7,
CMake 3.25.1 and Ninja. The Docker image was `chukonu-clang:19`, image ID
`sha256:076fb161a493fe0cd392818b6e0405514ff81f8c33d1a3353a86039e41adbe9f`.
The container had no network and mounted only a disposable source/build snapshot.
Dependencies came from the existing pinned curl 8.20.0, mbedTLS 3.6.4 and ncurses
6.5 archives. GUI, voice and Station optional native backends were disabled.

The initial CTest run passed 61 of 64 registered tests. Three test-environment
failures were diagnosed and corrected:

- `scopes` expects a Git revision; `git archive` omits `.git`. A local empty
  fixture commit supplied revision metadata without changing archived source.
- `control` requires the curl executable for its real loopback HTTP tests. The
  minimal image had none. An HTTP-only test client was built from the cached
  pinned curl source and added to this test container's PATH. This does not
  change Boggart's TLS-enabled linked library.
- `termctl` requires its separate `termctl_smoke` target; the initial build
  requested only `boggart`. The missing target was built.

A focused rerun of all three failed tests passed. Thus every registered test
passed in the combined run; this is not a claim of one uninterrupted 64/64 run.
The initial run already passed imports, evidence, workflow, context, capability,
quota and durable recovery. Imports ran without `/private/tmp` or source overlays.
No product-code changes were required for these environment failures.

The build emitted one unused-function warning in `src/lvoice.c:85`
(`file_readable`, voice disabled). This remains a whole-branch review item.
Windows, Studio window interaction and final end-to-end qualification remain
open programme work. Changes after this revision require their own validation.

## Reproduction

Create a disposable `git archive 38d39bd` source directory, retain its source
revision in the run manifest, and provide local Git metadata for tests that
inspect the checkout. Extract the pinned dependency archives into `deps`.
The paths below are inside a container whose scratch mount is `/work`:

```sh
CC=clang CXX=clang++ cmake -S /work/source -B /work/build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++ -DBOGGART_BUILD_APP=OFF \
  -DFETCHCONTENT_SOURCE_DIR_MBEDTLS=/work/deps/mbedtls/mbedtls-3.6.4 \
  -DFETCHCONTENT_SOURCE_DIR_CURL=/work/deps/curl/curl-8.20.0
CC=clang CXX=clang++ cmake --build /work/build \
  --target boggart termctl_smoke -j 4
# Provide a curl executable on PATH for the loopback control fixture.
ctest --test-dir /work/build --output-on-failure -j 1
```

Seed the cached ncurses archive at
`/work/build/ncurses_ep-prefix/src/ncurses-6.5.tar.gz` for offline builds.
Run from `/work/source`; do not mount a real user profile. Existing test recipes
supply isolated per-suite profiles. This run used scratch directory
`.superpowers/linux-38d39bd`; raw logs are in `.superpowers/sdd` (ignored).

## Recorded log hashes

- `linux-38d39bd-build.log`: `0e9818791ec895ae4a5ce167c4623aacf6b7654f605263ccee029d68ba0c2658`
- `linux-38d39bd-tests.log`: `f6ba3dfd0dacce454dcbe1074eabe46ecff4b2baa76001e7b8f193bd50e00d22`
- `linux-38d39bd-prereqs.log`: `e8870a4e65546b35ed42ffe99243a5545fef0420d11197180c73105c598b871d`
- `linux-38d39bd-rerun.log`: `c3f47d1b1044b84cd4279abee0be39f08156a404afb7b5c8a7b96d8896fe764f`
