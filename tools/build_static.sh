#!/bin/sh
# tools/build_static.sh -- build a fully static (musl) boggart CLI in Alpine.
#
#   tools/build_static.sh [--platform linux/amd64|linux/arm64] [--test] [--out DIR]
#
# Run on any machine with Docker: it starts a pinned Alpine container, copies
# the working tree into it (the source is mounted read-only, so the host's own
# ./boggart and build/ are never touched), configures with -DBOGGART_STATIC=ON
# and writes DIR/boggart (default ./dist-static/<arch>/boggart). With --test it
# also runs the ctest suites against the musl build before stripping.
#
# Run inside an Alpine (or other musl) environment with --in-container it does
# the build directly; that is what the Docker step calls. See
# docs/static-build.md for what the binary can and cannot do.
#
#   JOBS   parallel build jobs (default: the CPU count)
#   IMAGE  the build image (default: the pinned Alpine below)
set -eu

# alpine:3.22, pinned by digest so a rebuild uses the same compiler and musl.
IMAGE=${IMAGE:-alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f}

platform="" out="" test=0 inside=0
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) platform=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --test) test=1; shift ;;
    --in-container) inside=1; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "build_static.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done

if [ "$inside" = 0 ]; then
  root=$(cd "$(dirname "$0")/.." && pwd)
  if [ -z "$platform" ]; then
    case "$(uname -m)" in arm64|aarch64) platform=linux/arm64 ;; *) platform=linux/amd64 ;; esac
  fi
  arch=${platform#linux/}
  out=${out:-$root/dist-static/$arch}
  mkdir -p "$out"
  out=$(cd "$out" && pwd)
  t=""; [ "$test" = 1 ] && t=--test
  exec docker run --rm --platform "$platform" \
    -e JOBS="${JOBS:-}" \
    -v "$root":/src:ro -v "$out":/dist \
    "$IMAGE" sh /src/tools/build_static.sh --in-container $t --out /dist
fi

# ---- inside the musl environment --------------------------------------------
out=${out:-/dist}
if command -v apk >/dev/null 2>&1; then
  # linux-headers for libuv; perl for ncurses' configure; python3, git and bash
  # for the test suites (--test), which drive real tools.
  apk add --no-cache build-base cmake ninja linux-headers perl python3 git bash file >/dev/null
fi

work=/tmp/boggart-static
rm -rf "$work"; mkdir -p "$work"
# A copy of the tree without any host build output: a host build/ holds a
# CMakeCache for another compiler, and ./boggart is the host's own binary.
( cd /src && tar -cf - --exclude=./.git --exclude='./build*' --exclude=./dist-static \
    --exclude=./boggart --exclude=./boggart-studio . ) | tar -xf - -C "$work"

cmake -S "$work" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBOGGART_STATIC=ON
jobs=${JOBS:-$(nproc)}
if [ "$test" = 1 ]; then
  cmake --build "$work/build" -j "$jobs"
  ctest --test-dir "$work/build" --output-on-failure -j "$jobs"
else
  cmake --build "$work/build" -j "$jobs" --target boggart
fi

bin=$work/boggart
# A dynamic executable has a PT_INTERP (the loader path); a static one has none.
if readelf -l "$bin" | grep -q 'Requesting program interpreter'; then
  echo "build_static.sh: $bin is dynamically linked" >&2; exit 1
fi
mkdir -p "$out"
install -m 0755 "$bin" "$out/boggart"
strip "$out/boggart"
"$out/boggart" --version
command -v file >/dev/null 2>&1 && file "$out/boggart"
echo "built $out/boggart"
