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
  src/jwriter.c
  src/lauth.c
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

# ---- tests -----------------------------------------------------------------
# Each suite runs against a throwaway HOME so it never touches ~/.boggart.
# Windows spells that %USERPROFILE%, so set both -- sysproc.h's sysfs_home()
# reads USERPROFILE there and HOME everywhere else.
enable_testing()
foreach(suite test integration swarm mcp ltui sysfs bus jwriter proc sandbox scopes errors)
  set(_home ${CMAKE_CURRENT_BINARY_DIR}/testhome/${suite})
  if(WIN32)
    set(_home_env HOME=${_home} USERPROFILE=${_home})
  else()
    set(_home_env HOME=${_home})
  endif()
  add_test(NAME ${suite}
    COMMAND ${CMAKE_COMMAND} -E env ${_home_env}
      $<TARGET_FILE:boggart> --eval tests/${suite}.lua
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
endforeach()
