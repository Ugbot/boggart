# Native bitmap metadata allocator (BMUX-20)

`src/lbitmap.c/h` implements allocation metadata for the pinned SDK's 16-byte
grapheme and 32-byte string chunks. It is intended to accompany the Venus
Swiss map when logical pages gain live reference and allocator accounting.
Only initialization allocates host memory. Allocation, free and reset operate
on preallocated bitmaps; the caller owns payload storage. Capacity rounds up
to complete 64-chunk words, preserving the SDK's extra usable space.

Placement matters for resize compatibility. Requests of at most 64 chunks
stay inside one bitmap word; larger requests can span words. Full-word scan
hints advance after allocation and rewind when an earlier word is freed.
Reallocation reserves the new span before freeing the old one. These rules
reproduce the fragmentation that caused SDK page growth with 80 free bytes
but a largest contiguous span of only 48 bytes.

The [SDK capture](../../tests/fixtures/ghostty-bitmap.json) records 11 workloads
and 1,581 operations: small and rounded capacities, word boundaries, hint
rewinds, multiword spans, full arenas and repeated grapheme reallocations.
Every native result matches the independently executed SDK for success/failure,
offset, complete bitmap, capacity, used bytes and search hint. The final
fragmentation allocation fails with 8,112 of 8,192 bytes used, matching the
earlier live-terminal growth diagnostic.

The capture driver and fixture/guard tooling are Lua, running through Boggart.
A small optional probe executes the SDK's own Zig allocator. The archive and
all 5,915 source files are checked before and after capture. Source/probe/input
hashes accompany the records. Normal builds compile the frozen C fixture and
need no SDK compiler or network access.

```sh
BOGGART_HOME=/private/tmp/bmux-bitmap-home ./boggart \
  --eval tools/ghostty/probe_bitmap.lua -- \
  --work-root /private/tmp/bmux-sdk-bitmap \
  --archive /private/tmp/bmux-ghostty-source.tar.gz \
  --global-cache-dir /private/tmp/bmux-zig-global \
  --output tests/fixtures/ghostty-bitmap.json
BOGGART_HOME=/private/tmp/bmux-bitmap-home ./boggart \
  --eval tools/ghostty/bitmap_fixture.lua -- --check
env -u NO_COLOR ctest --test-dir build \
  -R '^(bitmap|ghostty_bitmap|page_layout|ghostty_page_growth)$' \
  --output-on-failure
```

Additional native checks compare 400,000 mixed allocation/free operations to
an independent bit-by-bit placement model. They verify every bitmap bit,
used-chunk count and scan hint without further allocation. Failure checks
cover initialization OOM, empty/unaligned/out-of-range/double frees, partial
free rejection, preserved outputs and bounded exhaustion at the final word.
The large-request exhaustion guard is independently tested in C; it is not
part of the SDK capture's successful multiword vectors.

Normal CLI/Studio builds, strict C11 warnings, Lua syntax and diff checks pass.
The four focused CTest checks pass normally (2.03 s) and under ASan/UBSan
(6.60 s). The allocator is available in the native core but not attached to
live page groups yet. The existing three large resize mismatches remain open;
these results make no runtime performance or full-application parity claim.
