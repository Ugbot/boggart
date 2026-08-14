# boggart -- single embedded exe: C core + embedded Lua 5.4 harness + libcurl.
#
# Configure with Ninja:
#   cmake -B build -G Ninja && cmake --build build && ctest --test-dir build
#
# The binary is written to the source root (./boggart) so the documented
# invocations keep working. Everything else stays in the build dir.
#
# Platforms: macOS and Linux use the system libcurl and system ncurses.
# Native Windows (MSVC / clang-cl -- never MinGW) builds libcurl from source
# with the Schannel backend and uses the vendored PDCurses. See the two blocks
# marked "Windows" below for the whole of the difference.
cmake_minimum_required(VERSION 3.20)
project(boggart C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "" FORCE)
endif()

# ---- MSVC global settings --------------------------------------------------
# Must come before add_subdirectory()/FetchContent so the vendored trees
# inherit them. `MSVC` is also true for clang-cl, which is what we want here:
# both take cl-style flags for these.
#
#   /utf-8  the sources are UTF-8 (lhttp.c and ltui/curses.c have non-ASCII in
#           comments). Without it MSVC decodes them in the system ANSI code
#           page and emits C4819 on every such file.
#   _CRT_*  mute the "use strcpy_s instead" deprecation flood, which would
#           otherwise bury every real warning.
if(MSVC)
  add_compile_options(/utf-8)
  add_compile_definitions(_CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_WARNINGS)
endif()

# ---- warning policy --------------------------------------------------------
# Two levels, applied by linking one of these interface targets:
#
#   boggart_warnings  our own code, built warning-clean
#   boggart_quiet     vendored code, silenced
#
# MSVC spells both differently, hence the generator expressions. Note clang-cl
# reports C_COMPILER_ID=Clang and so takes the GCC-spelled branch -- that is
# correct rather than accidental, as clang-cl accepts -Wall/-Wextra/-w.
#
# CMP0092 is NEW at cmake_minimum_required(3.20), so CMake does *not* put a
# default /W3 in CMAKE_C_FLAGS; there is nothing for /w to fight with.
add_library(boggart_warnings INTERFACE)
target_compile_options(boggart_warnings INTERFACE
  $<$<C_COMPILER_ID:MSVC>:/W3>
  $<$<NOT:$<C_COMPILER_ID:MSVC>>:-Wall>
  $<$<NOT:$<C_COMPILER_ID:MSVC>>:-Wextra>
  $<$<NOT:$<C_COMPILER_ID:MSVC>>:-Wno-unused-parameter>)

add_library(boggart_quiet INTERFACE)
target_compile_options(boggart_quiet INTERFACE
  $<$<C_COMPILER_ID:MSVC>:/w>
  $<$<NOT:$<C_COMPILER_ID:MSVC>>:-w>)

# ---- libcurl ---------------------------------------------------------------
# macOS/Linux: the system libcurl, as before -- it is the only dynamic dep and
# it comes with the platform (macOS SDK, distro -dev package).
#
# Windows: there is no system libcurl, so build one from source with
# FetchContent, pinned by release tarball + SHA256 so CI is reproducible.
# The TLS backend is Schannel: it is part of the OS, so this needs no OpenSSL
# (no second FetchContent, no Perl/NASM in CI) and it validates against the
# Windows certificate store, which is also what corporate MITM proxies install
# into. Everything optional is switched off -- no zlib/brotli/zstd/libpsl/
# libidn2 -- so the fetch has no transitive dependencies at all.
#
# Tradeoff: ~1 extra minute of CI build time and a version pin someone has to
# bump, in exchange for a Windows build that works from a bare checkout with
# no vcpkg, no MSYS, and no prebuilt binary to trust. The alternative (vcpkg
# or a downloaded prebuilt) is faster but adds a package manager or an
# unsigned third-party binary to the trust chain.
#
# curl's own lib/CMakeLists.txt defines the CURL::libcurl alias in-tree and
# puts CURL_STATICLIB in the static target's INTERFACE_COMPILE_DEFINITIONS, so
# the link line below is identical on all three platforms.
if(WIN32)
  set(BOGGART_CURL_VERSION 8.20.0)
  set(BOGGART_CURL_SHA256 63fe2dc148ba0ceae89922ef838f7e5c946272c2e78b7c59fab4b79d3ce2b896)

  set(BUILD_CURL_EXE     OFF CACHE BOOL "" FORCE)
  set(BUILD_SHARED_LIBS  OFF CACHE BOOL "" FORCE)
  set(BUILD_STATIC_LIBS  ON  CACHE BOOL "" FORCE)
  set(BUILD_TESTING      OFF CACHE BOOL "" FORCE)
  set(BUILD_LIBCURL_DOCS OFF CACHE BOOL "" FORCE)
  set(ENABLE_CURL_MANUAL OFF CACHE BOOL "" FORCE)
  set(CURL_USE_SCHANNEL  ON  CACHE BOOL "" FORCE)   # implies CURL_WINDOWS_SSPI
  set(CURL_USE_OPENSSL   OFF CACHE BOOL "" FORCE)
  set(CURL_USE_LIBPSL    OFF CACHE BOOL "" FORCE)   # defaults ON and is fatal if absent
  set(USE_LIBIDN2        OFF CACHE BOOL "" FORCE)
  # These three are tri-state (AUTO/ON/OFF) CACHE STRINGs, not booleans.
  set(CURL_ZLIB          OFF CACHE STRING "" FORCE)
  set(CURL_BROTLI        OFF CACHE STRING "" FORCE)
  set(CURL_ZSTD          OFF CACHE STRING "" FORCE)
  # Schannel uses the Windows cert store; there is no PEM bundle to find.
  set(CURL_CA_BUNDLE     "none" CACHE STRING "" FORCE)

  include(FetchContent)
  string(REPLACE "." "_" _curl_tag "curl-${BOGGART_CURL_VERSION}")
  FetchContent_Declare(curl
    URL https://github.com/curl/curl/releases/download/${_curl_tag}/curl-${BOGGART_CURL_VERSION}.tar.xz
    URL_HASH SHA256=${BOGGART_CURL_SHA256})
  FetchContent_MakeAvailable(curl)
else()
  find_package(CURL REQUIRED)
endif()

set(VENDOR ${CMAKE_CURRENT_SOURCE_DIR}/src/vendor)
set(LUA_SRC ${VENDOR}/lua/src)

# Lua's platform define: dlopen/popen support.
#
# Windows deliberately gets *no* define. luaconf.h already derives
# LUA_USE_WINDOWS from _WIN32 on its own, and the guard it uses is
# `#if !defined(LUA_USE_C89) && defined(_WIN32)` -- so passing LUA_USE_C89
# here (the old else-branch) would suppress it and cost us LUA_DL_DLL,
# popen/pclose and the Windows-specific lua_writeline/`system` paths.
if(APPLE)
  set(LUA_PLAT LUA_USE_MACOSX)
elseif(WIN32)
  set(LUA_PLAT "")
elseif(UNIX)
  set(LUA_PLAT LUA_USE_LINUX)
else()
  set(LUA_PLAT LUA_USE_C89)
endif()

# ---- vendored Lua 5.4 (minus the two files that define main()) --------------
file(GLOB LUA_SOURCES CONFIGURE_DEPENDS ${LUA_SRC}/*.c)
list(FILTER LUA_SOURCES EXCLUDE REGEX "/(lua|luac)\\.c$")

add_library(lua_vendor STATIC ${LUA_SOURCES})
if(LUA_PLAT)
  target_compile_definitions(lua_vendor PUBLIC ${LUA_PLAT})
endif()
target_include_directories(lua_vendor PUBLIC ${LUA_SRC})
target_link_libraries(lua_vendor PRIVATE boggart_warnings)
# LUA_USE_LINUX implies LUA_USE_DLOPEN, and Lua's math library needs libm.
# Both are folded into libc on glibc >= 2.34, but not on musl or older glibc.
# macOS needs neither; Windows needs neither.
if(UNIX AND NOT APPLE)
  target_link_libraries(lua_vendor PUBLIC m ${CMAKE_DL_LIBS})
endif()

# ---- vendored SQLite (FTS5, single-threaded, no loadable extensions) --------
# Upstream code: warnings suppressed, as in the Makefile.
add_library(sqlite_vendor STATIC ${VENDOR}/sqlite/sqlite3.c)
# SQLITE_THREADSAFE=2 ("multi-thread"), not 0.
#
# 0 compiles SQLite with no mutexes whatsoever: correct only while exactly one
# thread ever touches it, and undefined behaviour with no diagnostic the moment
# that stops being true. Since the bus journals a row on every send/publish,
# any second thread makes that a live hazard.
#
# 2 is safe to use from multiple threads provided a single *connection* is not
# used by two threads at once -- which is the discipline we want anyway: the
# Lua thread owns bog.db, and any worker thread that needs the store opens its
# own connection. It costs mutexes only around shared global structures, not
# per-connection, so it is materially cheaper than 1 (fully serialized).
target_compile_definitions(sqlite_vendor PRIVATE
  SQLITE_ENABLE_FTS5 SQLITE_THREADSAFE=2 SQLITE_OMIT_LOAD_EXTENSION)
target_include_directories(sqlite_vendor PUBLIC ${VENDOR}/sqlite)
target_link_libraries(sqlite_vendor PRIVATE boggart_quiet)

# ---- vendored cJSON (for the C MCP client) ---------------------------------
add_library(cjson_vendor STATIC ${VENDOR}/cjson/cJSON.c)
target_include_directories(cjson_vendor PUBLIC ${VENDOR}/cjson)
target_link_libraries(cjson_vendor PRIVATE boggart_quiet)

# ---- isocline: the line editor (MIT, Daan Leijen) ---------------------------
# Replaces linenoise, which was termios/ioctl to the core with no Windows port
# -- so on Windows the REPL previously had no line editor at all. isocline
# carries a console-API backend alongside the POSIX one, and keeps history,
# completion, multi-line editing and UTF-8.
#
# Single translation unit: src/isocline.c #includes the other .c files unless
# IC_SEPARATE_OBJS is set, which we leave off so no internal symbols escape.
add_library(isocline_vendor STATIC ${VENDOR}/isocline/src/isocline.c)
target_include_directories(isocline_vendor PUBLIC ${VENDOR}/isocline/include)
target_link_libraries(isocline_vendor PRIVATE boggart_quiet)

# ---- libuv (MIT) -----------------------------------------------------------
# Vendored for the cross-platform primitives the C stdlib lacks: process spawn
# with piped stdio, non-blocking pipe reads, and the filesystem calls. In C
# (unlike C++ with std::filesystem) it covers all of them, and uv_pipe_t hides
# the overlapped-named-pipe dance that IOCP requires on Windows.
#
# Static only, and EXCLUDE_FROM_ALL so nothing builds unless we link it.
set(LIBUV_BUILD_SHARED OFF CACHE BOOL "" FORCE)
set(LIBUV_BUILD_TESTS  OFF CACHE BOOL "" FORCE)
set(LIBUV_BUILD_BENCH  OFF CACHE BOOL "" FORCE)
add_subdirectory(${VENDOR}/libuv ${CMAKE_CURRENT_BINARY_DIR}/libuv EXCLUDE_FROM_ALL)

# ---- ltui terminal UI (Apache-2.0, tboox) ----------------------------------
# ltui is mostly Lua: its 37 modules live in lua/ltui/ and ride the normal bake
# step, so they are embedded in the binary AND overlay-mutable under
# ~/.boggart/lua/ like every other module -- the agent can rewrite its own
# dashboard. Only the curses binding is C.
#
# Backend: bundled PDCurses on Windows (no system curses there), system ncurses
# elsewhere. curses.c defines LUA_COMPAT_5_1/5_3/ALL itself before including
# luaconf.h, so the luaL_checkint family resolves without a build flag; the one
# genuine 5.4 incompatibility (lua_strlen) is patched in place.
if(WIN32)
  # The vendored PDCurses is 3.4 (2008), which predates the wincon/wingui/vt
  # split -- `win32/` is the only platform backend in the tree and therefore
  # the right one. (It is the Win32 *console* port; the wincon/vt variants only
  # exist from PDCurses 3.9 on.) `pdcurses/` is the platform-independent core
  # and includes panel.c, so no separate panel library is needed.
  #
  # PDC_WIDE matches src/vendor/pdcurses/xmake.lua, which is how ltui itself
  # builds this copy. It is not cosmetic: it switches PDCurses to the
  # WriteConsoleOutputW path so a chtype's character field is a Unicode code
  # point rather than an ANSI-code-page byte, which is what ltui's box-drawing
  # needs. It must be PUBLIC because curses.h changes typedefs and prototypes
  # (cchar_t, the wide entry points) on it -- a mismatch between the library
  # and ltui/curses.c would be an ABI mismatch, not a warning.
  #
  # PDC_FORCE_UTF8 additionally makes PDC_mbstowcs/PDC_wcstombs decode UTF-8
  # directly instead of going through the C locale. boggart hands PDCurses Lua
  # strings, which are UTF-8, and the Windows console's ANSI code page is not;
  # without this every non-ASCII glyph is mojibake. It has no effect unless
  # PDC_WIDE is also set (see pdcurses/util.c).
  #
  # CHTYPE_LONG is *not* passed: curses.h defines it itself (line 37).
  file(GLOB PDCURSES_CORE CONFIGURE_DEPENDS ${VENDOR}/pdcurses/pdcurses/*.c)
  file(GLOB PDCURSES_PLAT CONFIGURE_DEPENDS ${VENDOR}/pdcurses/win32/*.c)
  add_library(curses_backend STATIC ${PDCURSES_CORE} ${PDCURSES_PLAT})
  target_include_directories(curses_backend PUBLIC ${VENDOR}/pdcurses)
  target_compile_definitions(curses_backend PUBLIC PDC_WIDE PDC_FORCE_UTF8)
  target_link_libraries(curses_backend PRIVATE boggart_quiet)
  # pdcclip.c uses the clipboard API; the console/keyboard code needs kernel32.
  # Both are in CMake's MSVC default library list, but say so explicitly so a
  # trimmed CMAKE_C_STANDARD_LIBRARIES does not break the link silently.
  target_link_libraries(curses_backend PUBLIC user32 advapi32)
else()
  set(CURSES_NEED_NCURSES TRUE)
  find_package(Curses REQUIRED)
  add_library(curses_backend INTERFACE)
  target_include_directories(curses_backend INTERFACE ${CURSES_INCLUDE_DIRS})
  target_link_libraries(curses_backend INTERFACE ${CURSES_LIBRARIES})
  # Wide-char entry points (box-drawing glyphs) need XPG4 extended on ncurses.
  target_compile_definitions(curses_backend INTERFACE _XOPEN_SOURCE_EXTENDED)
endif()

add_library(ltui_curses STATIC ${VENDOR}/ltui/curses.c)
# Headers only from Lua: this is a static lib, so the Lua symbols resolve at
# the executable link. Linking lua_vendor here just makes ld warn about a
# duplicate archive.
target_include_directories(ltui_curses PRIVATE ${LUA_SRC})
target_link_libraries(ltui_curses PRIVATE curses_backend boggart_quiet)
set_property(TARGET ltui_curses PROPERTY C_STANDARD 99)

# ---- luv: libuv bindings for Lua (Apache-2.0, luvit) -----------------------
# Rather than hand-writing C bindings for the slice of libuv we happen to need,
# vendor the complete ones. This is the same binding Neovim ships as vim.uv, so
# it is well travelled, and it puts the whole event loop -- spawn, pipes,
# timers, async -- in Lua where the agent can rewrite it. Hand-rolled C
# bindings would have locked the interesting parts away from the model, which
# is precisely backwards for this project.
#
# luv is a single translation unit: src/luv.c #includes the other .c files, so
# only luv.c is compiled here. compat-5.3.h is vendored alongside (it is a
# submodule upstream, hence absent from release tarballs); on Lua 5.4 it is
# very nearly a no-op, but luv.c includes it unconditionally.
add_library(luv_lua STATIC ${VENDOR}/luv/luv.c)
target_include_directories(luv_lua PRIVATE
  ${LUA_SRC}
  ${VENDOR}/luv
  ${VENDOR}/libuv/include)
# PUBLIC on uv_a so CMake orders the static archives correctly at the final
# link -- luv.c is nothing but undefined uv_* references.
target_link_libraries(luv_lua PRIVATE boggart_quiet PUBLIC uv_a)

# ---- generated embedded Lua ------------------------------------------------
# Bakes lua/**/*.lua into a C lookup table. Regenerated whenever any Lua
# source changes; written to the build dir to keep the source tree clean.
file(GLOB_RECURSE LUA_MODULES CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/lua/*.lua)
set(EMBEDDED_C ${CMAKE_CURRENT_BINARY_DIR}/embedded.c)

add_custom_command(
  OUTPUT ${EMBEDDED_C}
  COMMAND ${CMAKE_COMMAND}
          -DLUA_DIR=${CMAKE_CURRENT_SOURCE_DIR}/lua
          -DOUT=${EMBEDDED_C}
          -P ${CMAKE_CURRENT_SOURCE_DIR}/tools/bake_embedded.cmake
  DEPENDS ${LUA_MODULES} ${CMAKE_CURRENT_SOURCE_DIR}/tools/bake_embedded.cmake
  COMMENT "Baking lua/ into embedded.c"
  VERBATIM)

# ---- the executable --------------------------------------------------------
# (An earlier plan had a hand-written src/sysproc_{posix,win32}.c platform
# shim, wired in here by a glob. Vendoring libuv + luv replaced it: uv_spawn
# and uv_pipe_t already provide spawn, non-blocking pipe reads and the Win32
# overlapped-I/O handling, so the shim and its glob are gone.)
add_executable(boggart
  src/boggart.c
  src/lhttp.c
  src/lsys.c
  src/ldb.c
  src/lswarm.c
  src/lmcp.c
  src/lgit.c
  src/jwriter.c
  src/lauth.c
  src/lworker.c
  src/lterm.c
  src/termctl.c
  src/ltermctl.c
  src/bogembed.c
  src/lmem.c
  ${EMBEDDED_C})

target_include_directories(boggart PRIVATE src)
target_link_libraries(boggart PRIVATE
  boggart_warnings
  lua_vendor sqlite_vendor cjson_vendor ltui_curses luv_lua uv_a
  isocline_vendor CURL::libcurl)

# Keep ./boggart at the repo root, as the README documents. The per-config
# properties matter only for multi-config generators (Visual Studio, Xcode),
# which would otherwise append a Debug/ or Release/ subdirectory.
set_target_properties(boggart PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY                ${CMAKE_CURRENT_SOURCE_DIR}
  RUNTIME_OUTPUT_DIRECTORY_DEBUG          ${CMAKE_CURRENT_SOURCE_DIR}
  RUNTIME_OUTPUT_DIRECTORY_RELEASE        ${CMAKE_CURRENT_SOURCE_DIR}
  RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO ${CMAKE_CURRENT_SOURCE_DIR}
  RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL     ${CMAKE_CURRENT_SOURCE_DIR})

# The linker ad-hoc signs, but a stale or invalid signature is what makes macOS
# SIGKILL an arm64 binary at exec time. Re-sign explicitly so it always runs.
if(APPLE)
  add_custom_command(TARGET boggart POST_BUILD
    COMMAND codesign -f -s - $<TARGET_FILE:boggart>
    COMMENT "Ad-hoc signing boggart")
endif()

# ---- boggart-studio: the desktop app ---------------------------------------
# rxi's lite (MIT) as the editor shell, with boggart embedded as the agent
# engine. One process and one lua_State: lite's SDL loop owns the program and
# pumps boggart's scheduler once per frame, which is the same inversion the
# swarm dashboard already uses (lua/dash.lua) and for the same reason -- the
# thing that owns the frame must never be the thing that blocks.
#
# Sharing the interpreter is the point rather than an economy: the agent can
# already rewrite its own harness, and in one state it can rewrite the editor
# too -- add a command, bind a key, write a syntax mode for the file it is
# looking at. That is the capability neither Goose nor Codex can have.
#
# Optional: configure with -DBOGGART_BUILD_APP=OFF to skip.
option(BOGGART_BUILD_APP "Build the boggart-studio desktop app" ON)

# ---- SDL2 -------------------------------------------------------------------
# Built from source and linked statically, so boggart-studio is genuinely one
# file. Same reasoning and the same mechanism as the Windows libcurl above:
# FetchContent, pinned by release tarball + SHA256, everything optional off.
#
# The system package cannot do this job on macOS, and not for a packaging
# reason. Homebrew's `sdl2` is `sdl2-compat`, a shim whose libSDL2 dlopens
# SDL3 from an absolute Cellar path -- verified with DYLD_PRINT_LIBRARIES. So a
# binary linked against it reaches into /opt/homebrew at run time even after
# install_name_tool has been pointed at a bundled copy, and it is not SDL2 that
# ends up running either. Building the real thing is the only way to know what
# is in the binary.
#
# Cost: two or three minutes on a cold build, cached afterwards, and a version
# pin someone has to bump. In exchange, the studio has no runtime dependency on
# SDL at all -- no `brew install sdl2`, no SDL2.dll beside the exe, no
# libsdl2-2.0-0 package -- on any platform.
#
# -DBOGGART_SDL_FROM_SOURCE=OFF falls back to whatever SDL2 the system has,
# which is the right choice for a distribution package: a distro wants to own
# and patch its own SDL, and it is not shipping our binary anyway.
option(BOGGART_SDL_FROM_SOURCE
  "Build SDL2 from source and link it statically (self-contained binary)" ON)

if(BOGGART_BUILD_APP AND BOGGART_SDL_FROM_SOURCE)
  set(BOGGART_SDL_VERSION 2.32.10)
  set(BOGGART_SDL_SHA256 5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165)

  set(SDL_SHARED       OFF CACHE BOOL "" FORCE)
  set(SDL_STATIC       ON  CACHE BOOL "" FORCE)
  set(SDL_TEST         OFF CACHE BOOL "" FORCE)
  set(SDL_TESTS        OFF CACHE BOOL "" FORCE)
  set(SDL2_DISABLE_INSTALL ON CACHE BOOL "" FORCE)
  set(SDL2_DISABLE_UNINSTALL ON CACHE BOOL "" FORCE)
  # The studio draws into a window surface and reads keyboard, mouse and
  # window events. It has never opened an audio device, a joystick or a sensor,
  # so those subsystems are dead weight in the binary and dead code paths in a
  # threat model.
  set(SDL_AUDIO        OFF CACHE BOOL "" FORCE)
  set(SDL_HAPTIC       OFF CACHE BOOL "" FORCE)
  set(SDL_JOYSTICK     OFF CACHE BOOL "" FORCE)
  set(SDL_SENSOR       OFF CACHE BOOL "" FORCE)
  set(SDL_POWER        OFF CACHE BOOL "" FORCE)

  include(FetchContent)
  FetchContent_Declare(sdl2
    URL https://github.com/libsdl-org/SDL/releases/download/release-${BOGGART_SDL_VERSION}/SDL2-${BOGGART_SDL_VERSION}.tar.gz
    URL_HASH SHA256=${BOGGART_SDL_SHA256})
  FetchContent_MakeAvailable(sdl2)

  # SDL2::SDL2-static carries its own interface include dirs and the platform
  # libraries a static build needs (the macOS frameworks, dl/pthread/m on
  # Linux, the Win32 import libraries), so nothing below has to know them.
  set(SDL2_FOUND TRUE)
  set(BOGGART_SDL_TARGET SDL2::SDL2-static)
elseif(BOGGART_BUILD_APP)
  find_package(SDL2 QUIET)
  if(NOT SDL2_FOUND)
    find_package(PkgConfig QUIET)
    if(PkgConfig_FOUND)
      pkg_check_modules(SDL2 QUIET sdl2)
    endif()
  endif()
endif()

# ---- FreeType ---------------------------------------------------------------
# The text rasteriser. Same mechanism and the same reasoning as the SDL2 block
# above: FetchContent, pinned by release tarball + SHA256, every optional
# dependency switched off, linked statically, so `otool -L boggart-studio`
# still lists nothing but system libraries.
#
# It replaces stb_truetype, which was a single vendored header and cost
# nothing. What that header cannot do is hint: it scales the outline and
# rasterises wherever it lands, so small text is uniformly soft. That is the
# whole legibility gap, and it is not closable downstream of the rasteriser.
# See the comment at the top of studio/src/renderer.c.
#
# Cost, measured on an M-series mac: 680 KB of binary (5.14 MB -> 5.82 MB) and
# five seconds of single-threaded compile, cached after -- next to SDL2's two
# to three minutes it is not the expensive fetch here.
#
# Everything optional is off -- no zlib, bzip2, libpng, HarfBuzz or Brotli --
# which means no transitive fetches and no system packages. It costs us:
# compressed WOFF2 fonts (Brotli), PNG-backed colour-emoji strikes (libpng),
# and HarfBuzz-assisted autohinting of Indic scripts. None of those are things
# this renderer draws -- fontfallback.c refuses colour fonts on separate
# grounds, and there is no shaping engine here for HarfBuzz to help.
#
# Guarded on SDL2_FOUND as well as BOGGART_BUILD_APP so that a machine without
# SDL2, which builds the CLI and skips the studio, does not download a
# rasteriser it will not link.
if(BOGGART_BUILD_APP AND SDL2_FOUND)
  set(BOGGART_FREETYPE_VERSION 2.14.3)
  set(BOGGART_FREETYPE_SHA256 e61b31ab26358b946e767ed7eb7f4bb2e507da1cfefeb7a8861ace7fd5c899a1)

  set(BUILD_SHARED_LIBS   OFF  CACHE BOOL "" FORCE)
  set(FT_DISABLE_ZLIB     TRUE CACHE BOOL "" FORCE)
  set(FT_DISABLE_BZIP2    TRUE CACHE BOOL "" FORCE)
  set(FT_DISABLE_PNG      TRUE CACHE BOOL "" FORCE)
  set(FT_DISABLE_HARFBUZZ TRUE CACHE BOOL "" FORCE)
  set(FT_DISABLE_BROTLI   TRUE CACHE BOOL "" FORCE)
  set(SKIP_INSTALL_ALL    TRUE CACHE BOOL "" FORCE)

  include(FetchContent)
  FetchContent_Declare(freetype
    URL https://download.savannah.gnu.org/releases/freetype/freetype-${BOGGART_FREETYPE_VERSION}.tar.gz
    URL_HASH SHA256=${BOGGART_FREETYPE_SHA256})
  FetchContent_MakeAvailable(freetype)
endif()

if(BOGGART_BUILD_APP AND SDL2_FOUND)
  # lite's own C. Deliberately NOT lite's vendored Lua: the studio shares one
  # interpreter with boggart, and that interpreter is the vendored 5.4. lite
  # needs exactly one change for it.
  file(GLOB APP_SOURCES CONFIGURE_DEPENDS
    ${CMAKE_CURRENT_SOURCE_DIR}/studio/src/*.c
    ${CMAKE_CURRENT_SOURCE_DIR}/studio/src/api/*.c)

  # ---- generated embedded studio assets ------------------------------------
  # studio/data -- sixty-odd Lua files and three fonts -- baked into the binary
  # the same way lua/ already is, so boggart-studio is one file rather than a
  # file plus a directory that has to travel with it. studio/src/assets.c reads
  # the table; an on-disk data/ still wins, so a checkout runs its working copy.
  set(STUDIO_ASSETS_C ${CMAKE_CURRENT_BINARY_DIR}/studio_assets.c)
  file(GLOB_RECURSE STUDIO_DATA CONFIGURE_DEPENDS
    ${CMAKE_CURRENT_SOURCE_DIR}/studio/data/*)
  add_custom_command(
    OUTPUT ${STUDIO_ASSETS_C}
    COMMAND ${CMAKE_COMMAND}
            -DDATA_DIR=${CMAKE_CURRENT_SOURCE_DIR}/studio/data
            -DOUT=${STUDIO_ASSETS_C}
            -P ${CMAKE_CURRENT_SOURCE_DIR}/tools/bake_assets.cmake
    DEPENDS ${STUDIO_DATA} ${CMAKE_CURRENT_SOURCE_DIR}/tools/bake_assets.cmake
    COMMENT "Baking studio/data into studio_assets.c")

  add_executable(boggart-studio
    ${APP_SOURCES}
    ${STUDIO_ASSETS_C}
    src/lhttp.c
    src/lsys.c
    src/ldb.c
    src/lswarm.c
    src/lmcp.c
    src/lgit.c
    src/jwriter.c
    src/lauth.c
    src/lworker.c
    src/bogembed.c
  src/lmem.c
    ${EMBEDDED_C})

  target_include_directories(boggart-studio PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/studio/src
    ${SDL2_INCLUDE_DIRS})
  target_compile_definitions(boggart-studio PRIVATE BOGGART_STUDIO=1)
  target_link_libraries(boggart-studio PRIVATE
    boggart_warnings
    lua_vendor sqlite_vendor cjson_vendor luv_lua uv_a isocline_vendor
    CURL::libcurl freetype)
  # Three spellings, because SDL2 arrives three ways: our own static build sets
  # BOGGART_SDL_TARGET, a system sdl2-config.cmake gives the SDL2::SDL2 target,
  # and pkg-config gives bare library names and directories.
  if(BOGGART_SDL_TARGET)
    target_link_libraries(boggart-studio PRIVATE ${BOGGART_SDL_TARGET})
    # SDL2's static target does not declare every framework it uses. Its CMake
    # adds them per subsystem, but SDL_cocoamodes.m (display modes -- not
    # optional) and SDL_hidapi.c both reach into IOKit, and hidapi is compiled
    # even with joystick and sensor off. Undeclared, not unused: the shared
    # build gets away with it because the dylib records its own dependencies.
    if(APPLE)
      target_link_libraries(boggart-studio PRIVATE
        "-framework IOKit" "-framework ForceFeedback" "-framework CoreHaptics"
        "-framework GameController" "-framework AudioToolbox"
        "-framework CoreAudio" "-framework AVFoundation" "-framework CoreMedia"
        "-framework UniformTypeIdentifiers")
    endif()
  elseif(SDL2_LIBRARIES)
    target_link_libraries(boggart-studio PRIVATE ${SDL2_LIBRARIES})
    target_link_directories(boggart-studio PRIVATE ${SDL2_LIBRARY_DIRS})
  else()
    target_link_libraries(boggart-studio PRIVATE SDL2::SDL2)
  endif()
  # Windows needs SDL2main, and needs it whichever way SDL2 arrived.
  #
  # studio/src/main.c includes SDL.h and defines main(). On Windows SDL_main.h
  # answers that with `#define main SDL_main` (SDL_main.h:143, reached via
  # SDL_MAIN_AVAILABLE on __WIN32__), so the entry point the CRT goes looking
  # for is not in our objects at all -- SDL2main is the library that carries
  # the main() and WinMain() that call it. Without this the link fails with an
  # unresolved external, which is why it has never been caught: the studio was
  # only ever built on macOS and Linux, where SDL2main is an empty stub.
  #
  # Linking it only on WIN32 rather than everywhere keeps the Unix link lines
  # exactly as they were.
  if(WIN32 AND TARGET SDL2::SDL2main)
    target_link_libraries(boggart-studio PRIVATE SDL2::SDL2main)
  endif()
  # The editor core came from rxi's lite and still warns; ours build clean.
  set_source_files_properties(${APP_SOURCES} PROPERTIES COMPILE_OPTIONS "-w")
  set_target_properties(boggart-studio PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
  if(APPLE)
    add_custom_command(TARGET boggart-studio POST_BUILD
      COMMAND codesign -f -s - $<TARGET_FILE:boggart-studio>
      COMMENT "Ad-hoc signing boggart-studio")
  endif()
  # `ninja ui-check` renders the studio with representative content, asserts
  # the agent panel is attached and non-zero, and writes a screenshot to look
  # at. Not a ctest: it needs a window server, and CI has none. It exists
  # because the two panel-attachment bugs it catches were invisible to every
  # headless test of the view -- the view was correct in isolation both times.
  # `ninja ui-bench` guards the frame-rate invariants: drawing bounded by the
  # viewport rather than the transcript, the layout cache actually caching, and
  # streaming not re-laying-out settled entries. Also not a ctest -- it needs a
  # window server, and a headless machine cannot measure a frame.
  # `ninja core-parity` proves the terminal agent and the desktop application
  # are one engine: same version, same API surface, same prompt, same limits,
  # same tools bar the window-only ones. See tools/parity.cmake.
  add_custom_target(core-parity
    COMMAND ${CMAKE_COMMAND}
      -DCLI=$<TARGET_FILE:boggart> -DGUI=$<TARGET_FILE:boggart-studio>
      -DFP=${CMAKE_CURRENT_SOURCE_DIR}/tools/fingerprint.lua
      -DFPGUI=${CMAKE_CURRENT_SOURCE_DIR}/tools/fingerprint_studio.lua
      -DCMAKE_CURRENT_BINARY_DIR=${CMAKE_CURRENT_BINARY_DIR}
      -P ${CMAKE_CURRENT_SOURCE_DIR}/tools/parity.cmake
    DEPENDS boggart boggart-studio
    COMMENT "Checking the CLI and the studio share one core"
    USES_TERMINAL)

  add_custom_target(ui-bench
    COMMAND ${CMAKE_COMMAND} -E env
      BOGGART_STUDIO_SCRIPT=${CMAKE_CURRENT_SOURCE_DIR}/tools/uibench.lua
      $<TARGET_FILE:boggart-studio> ${CMAKE_CURRENT_SOURCE_DIR}
    DEPENDS boggart-studio
    COMMENT "Checking boggart-studio's frame-rate invariants"
    USES_TERMINAL)

  add_custom_target(ui-check
    COMMAND ${CMAKE_COMMAND} -E env
      BOGGART_STUDIO_SCRIPT=${CMAKE_CURRENT_SOURCE_DIR}/tools/uishot.lua
      BOGGART_STUDIO_SHOT=${CMAKE_CURRENT_BINARY_DIR}/studio-shot.bmp
      $<TARGET_FILE:boggart-studio> ${CMAKE_CURRENT_SOURCE_DIR}
    DEPENDS boggart-studio
    COMMENT "Rendering boggart-studio and checking the agent panel"
    USES_TERMINAL)
elseif(BOGGART_BUILD_APP)
  message(STATUS "SDL2 not found -- skipping boggart-studio (the CLI still builds)")
endif()

# ---- tests -----------------------------------------------------------------
# Each suite runs against a throwaway HOME so it never touches ~/.boggart.
# Windows spells that %USERPROFILE%, so set both -- sysproc.h's sysfs_home()
# reads USERPROFILE there and HOME everywhere else.
#
# %LOCALAPPDATA% has to move with it. The path policy in src/lsys.c resolves a
# new install to %LOCALAPPDATA%\boggart on Windows, ahead of the home
# directory, so setting HOME and USERPROFILE alone leaves every suite sharing
# one real directory in the runner's (or the developer's) profile: state
# leaking from suite to suite, and a "first run" that is only ever first once.
# Overriding the platform variable rather than BOGGART_HOME keeps the platform
# rule itself under test -- it still resolves %LOCALAPPDATA%, that just now
# points somewhere disposable.
enable_testing()
foreach(suite test integration swarm mcp ltui sysfs bus jwriter worker proc sandbox scopes errors studio events lifecycle plan goap claims prompt skills agentmodel skillrouter complete termrender goal tui_input tui_agents)
  set(_home ${CMAKE_CURRENT_BINARY_DIR}/testhome/${suite})
  if(WIN32)
    set(_home_env HOME=${_home} USERPROFILE=${_home}
                  LOCALAPPDATA=${_home}/AppData/Local)
  else()
    set(_home_env HOME=${_home})
  endif()
  add_test(NAME ${suite}
    COMMAND ${CMAKE_COMMAND} -E env ${_home_env}
      $<TARGET_FILE:boggart> --eval tests/${suite}.lua
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
endforeach()

# termctl (B0 of the cTUI, docs/cli-plan.md): the dependency-free full-screen
# terminal layer. Compiled standalone and smoke-tested here so it stays
# build-verified and regression-guarded before the cTUI that consumes it exists.
# The smoke test degrades gracefully with no tty, so </dev/null it self-exits 0.
add_executable(termctl_smoke src/termctl.c src/termctl_test.c)
target_include_directories(termctl_smoke PRIVATE src)
add_test(NAME termctl COMMAND sh -c "$<TARGET_FILE:termctl_smoke> </dev/null")
