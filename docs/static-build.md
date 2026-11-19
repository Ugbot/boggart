# Fully static Linux build

The normal Linux build links every third-party library statically but leaves
glibc dynamic, so the binary runs only where glibc is at least as new as the
build machine's (Ubuntu 22.04 for the release archives). A fully static build
links libc too and runs on any Linux kernel of the same architecture: old
distributions, Alpine, minimal containers with no libc at all.

It is the `boggart` CLI only. The studio needs the machine's X11, Wayland and
GL libraries, which cannot be linked in, so `BOGGART_STATIC=ON` turns
`BOGGART_BUILD_APP` off.

## Build it

With Docker, from the repository root:

```sh
tools/build_static.sh                          # -> dist-static/<host arch>/boggart
tools/build_static.sh --platform linux/amd64   # another architecture (emulated: slow)
tools/build_static.sh --test                   # also run ctest against the musl build
```

The script starts a pinned Alpine image, copies the tree into it (the source is
mounted read-only, so your own `./boggart` and `build/` are untouched), builds,
checks the result has no program interpreter, strips it and runs `--version`.
`JOBS=8` limits parallelism.

On an Alpine machine (or any musl toolchain) the option is enough:

```sh
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBOGGART_STATIC=ON
cmake --build build --target boggart
file boggart        # ... statically linked
```

Build against musl, not glibc. A static glibc binary links, with warnings, but
user and host lookups (`getpwnam`, `getaddrinfo`) still load NSS modules from
the machine at run time; configure prints a warning when it detects glibc.

Tagged releases publish `boggart-<tag>-linux-x86_64-static.tar.gz` and
`boggart-<tag>-linux-arm64-static.tar.gz`, each with a `.sha256` beside it.

## What is different

- **No C stack in crash reports.** musl has no `backtrace()`, so a crash report
  says the C stack is unavailable. The signal, fault address and Lua stack are
  still written to stderr and to the crash file (`src/bogcrash.c`).
- **No Lua C modules.** A static binary cannot `dlopen`, so `require` of a
  compiled `.so` module fails. Pure-Lua modules and everything built in work.
- **CA certificates.** HTTPS uses the CA bundle path found at configure time;
  in the Alpine build that is `/etc/ssl/certs/ca-certificates.crt`, which
  Debian, Ubuntu and Alpine all use. Distributions that keep certificates
  elsewhere (Fedora, RHEL) need that path to exist.

mbedTLS builds itself with `-Werror`. GCC 12 and later report a false
`-Warray-bounds` in its `mbedtls_xor`, so with GCC (this build, and any newer
Linux distribution) mbedTLS's warnings are left as warnings
(`MBEDTLS_FATAL_WARNINGS=OFF`); with clang nothing changes. It is vendored
code we do not patch. See the comment in `CMakeLists.txt`.
