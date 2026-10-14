# boggart -- single embedded exe: C core + embedded Lua 5.4 harness + libcurl.
#
# Configure with Ninja:
#   cmake -B build -G Ninja && cmake --build build && ctest --test-dir build
#
# The binary is written to the source root (./boggart) so the documented
# invocations keep working. Everything else stays in the build dir.
#
# Every third-party library is built from source and linked statically.
# Native Windows (MSVC / clang-cl -- never MinGW) uses Schannel + PDCurses;
# macOS/Linux use mbedTLS + a pinned ncurses. libc and OS frameworks stay
# dynamic because they are the platform. See the curl / curses blocks.
cmake_minimum_required(VERSION 3.20)
project(boggart C)

set(CMAKE_C_STANDARD 11)
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

# ---- sanitizers (BOG-10) --------------------------------------------------------
# BOGGART_SANITIZER=none|address|undefined|address,undefined|thread, applied PER
# TARGET by boggart_apply_sanitizer() -- never as a global flag (after Venus's
# venus_apply_sanitizer: a global -fsanitize also instruments build-time tools,
# which then crash mid-build). Use a separate build tree per sanitizer.
set(BOGGART_SANITIZER "none" CACHE STRING "none, address, undefined, address,undefined or thread")
set(BOG_SAN_FLAGS "")
if(NOT BOGGART_SANITIZER STREQUAL "none")
  if(MSVC)
    if(NOT BOGGART_SANITIZER STREQUAL "address")
      message(FATAL_ERROR "MSVC supports only BOGGART_SANITIZER=address")
    endif()
    set(BOG_SAN_FLAGS /fsanitize=address)
  else()
    if(NOT BOGGART_SANITIZER MATCHES "^(address|undefined|address,undefined|thread)$")
      message(FATAL_ERROR "unknown BOGGART_SANITIZER '${BOGGART_SANITIZER}'")
    endif()
    if(BOGGART_SANITIZER MATCHES "thread" AND BOGGART_SANITIZER MATCHES "address")
      message(FATAL_ERROR "thread and address sanitizers cannot be combined")
    endif()
    set(BOG_SAN_FLAGS -fsanitize=${BOGGART_SANITIZER} -fno-omit-frame-pointer -g)
    if(BOGGART_SANITIZER MATCHES "undefined")
      list(APPEND BOG_SAN_FLAGS -fno-sanitize-recover=undefined)   # UB fails the test, not a log line
    endif()
  endif()
  message(STATUS "boggart: sanitizer ${BOGGART_SANITIZER} on boggart's own targets")
endif()
function(boggart_apply_sanitizer)
  if(BOG_SAN_FLAGS)
    foreach(t ${ARGN})
      if(TARGET ${t})
        target_compile_options(${t} PRIVATE ${BOG_SAN_FLAGS})
        if(NOT MSVC)
          target_link_options(${t} PRIVATE ${BOG_SAN_FLAGS})
        endif()
      endif()
    endforeach()
  endif()
endfunction()
target_compile_options(boggart_quiet INTERFACE
  $<$<C_COMPILER_ID:MSVC>:/w>
  $<$<NOT:$<C_COMPILER_ID:MSVC>>:-w>)

# ---- libcurl ---------------------------------------------------------------
# Built from source and linked statically on every platform, so neither
# binary dlopens a Cellar or distro libcurl. Same FetchContent pin as SDL.
#
# TLS is the OS store where the OS has one that speaks TLS 1.3 (Schannel on
# Windows). Apple's Secure Transport does not, so macOS and Linux use a
# pinned mbedTLS -- small, CMake-native, no OpenSSL/Perl/NASM. Optional
# curl features stay off so the fetch has no other transitive dependencies.
#
# curl's own lib/CMakeLists.txt defines the CURL::libcurl alias in-tree and
# puts CURL_STATICLIB in the static target's INTERFACE_COMPILE_DEFINITIONS, so
# the link line below is identical on all three platforms.
set(BOGGART_CURL_VERSION 8.20.0)
set(BOGGART_CURL_SHA256 63fe2dc148ba0ceae89922ef838f7e5c946272c2e78b7c59fab4b79d3ce2b896)

set(BUILD_CURL_EXE     OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS  OFF CACHE BOOL "" FORCE)
set(BUILD_STATIC_LIBS  ON  CACHE BOOL "" FORCE)
set(BUILD_TESTING      OFF CACHE BOOL "" FORCE)
set(BUILD_LIBCURL_DOCS OFF CACHE BOOL "" FORCE)
set(ENABLE_CURL_MANUAL OFF CACHE BOOL "" FORCE)
set(CURL_USE_LIBPSL    OFF CACHE BOOL "" FORCE)
set(USE_LIBIDN2        OFF CACHE BOOL "" FORCE)
set(USE_NGHTTP2        OFF CACHE BOOL "" FORCE)
set(CURL_DISABLE_LDAP  ON  CACHE BOOL "" FORCE)
set(CURL_DISABLE_LDAPS ON  CACHE BOOL "" FORCE)
set(HTTP_ONLY          ON  CACHE BOOL "" FORCE)
set(CURL_USE_PKGCONFIG OFF CACHE BOOL "" FORCE)
set(CURL_USE_CMAKECONFIG OFF CACHE BOOL "" FORCE)
set(CURL_ZLIB          OFF CACHE STRING "" FORCE)
set(CURL_BROTLI        OFF CACHE STRING "" FORCE)
set(CURL_ZSTD          OFF CACHE STRING "" FORCE)

include(FetchContent)
if(WIN32)
  set(CURL_USE_SCHANNEL ON  CACHE BOOL "" FORCE)
  set(CURL_USE_OPENSSL  OFF CACHE BOOL "" FORCE)
  set(CURL_USE_MBEDTLS  OFF CACHE BOOL "" FORCE)
  set(CURL_CA_BUNDLE    "none" CACHE STRING "" FORCE)
else()
  # Official release tarball (not GitHub's auto source.zip): that one ships
  # the generated files, so the fetch does not need Python.
  set(BOGGART_MBEDTLS_VERSION 3.6.4)
  set(BOGGART_MBEDTLS_SHA256 ec35b18a6c593cf98c3e30db8b98ff93e8940a8c4e690e66b41dfc011d678110)
  set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
  set(ENABLE_TESTING  OFF CACHE BOOL "" FORCE)
  set(GEN_FILES       OFF CACHE BOOL "" FORCE)
  set(USE_STATIC_MBEDTLS_LIBRARY ON  CACHE BOOL "" FORCE)
  set(USE_SHARED_MBEDTLS_LIBRARY OFF CACHE BOOL "" FORCE)
  set(DISABLE_PACKAGE_CONFIG_AND_INSTALL ON CACHE BOOL "" FORCE)
  FetchContent_Declare(mbedtls
    URL https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-${BOGGART_MBEDTLS_VERSION}/mbedtls-${BOGGART_MBEDTLS_VERSION}.tar.bz2
    URL_HASH SHA256=${BOGGART_MBEDTLS_SHA256}
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
  FetchContent_MakeAvailable(mbedtls)
  # Point curl's FindMbedTLS at the in-tree targets before it configures.
  # The .a files do not exist yet; the target names resolve at link time.
  FetchContent_GetProperties(mbedtls SOURCE_DIR mbedtls_SOURCE_DIR)
  set(MBEDTLS_INCLUDE_DIR "${mbedtls_SOURCE_DIR}/include" CACHE PATH "" FORCE)
  set(MBEDTLS_LIBRARY     mbedtls   CACHE FILEPATH "" FORCE)
  set(MBEDX509_LIBRARY    mbedx509  CACHE FILEPATH "" FORCE)
  set(MBEDCRYPTO_LIBRARY  mbedcrypto CACHE FILEPATH "" FORCE)
  set(CURL_USE_MBEDTLS ON  CACHE BOOL "" FORCE)
  set(CURL_USE_OPENSSL OFF CACHE BOOL "" FORCE)
  set(CURL_USE_SCHANNEL OFF CACHE BOOL "" FORCE)
  # Bake the platform CA path if cmake finds one; HTTPS still works when
  # copied to another Unix box that keeps certs in the usual places.
endif()

string(REPLACE "." "_" _curl_tag "curl-${BOGGART_CURL_VERSION}")
FetchContent_Declare(curl
  URL https://github.com/curl/curl/releases/download/${_curl_tag}/curl-${BOGGART_CURL_VERSION}.tar.xz
  URL_HASH SHA256=${BOGGART_CURL_SHA256}
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(curl)

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

# ---- vendored SQLite (FTS5, R*Tree + Geopoly, single-threaded, no loadable extensions) --------
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
  SQLITE_ENABLE_FTS5 SQLITE_ENABLE_RTREE SQLITE_ENABLE_GEOPOLY
  SQLITE_THREADSAFE=2 SQLITE_OMIT_LOAD_EXTENSION)
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
# Backend: bundled PDCurses on Windows (no system curses there), ncurses 6.5
# fetched and linked statically elsewhere -- same "one file" rule as curl.
# curses.c defines LUA_COMPAT_5_1/5_3/ALL itself before including luaconf.h,
# so the luaL_checkint family resolves without a build flag; the one genuine
# 5.4 incompatibility (lua_strlen) is patched in place.
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
  # Autotools, not CMake: ncurses has no official CMake build. ExternalProject
  # configures a static wide library into the build dir; ninja waits on the
  # archives via BUILD_BYPRODUCTS. --without-shared is the whole point.
  set(BOGGART_NCURSES_VERSION 6.5)
  set(BOGGART_NCURSES_SHA256 136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6)
  set(NCURSES_PREFIX ${CMAKE_CURRENT_BINARY_DIR}/ncurses)
  file(MAKE_DIRECTORY ${NCURSES_PREFIX}/include ${NCURSES_PREFIX}/include/ncursesw)
  include(ExternalProject)
  ExternalProject_Add(ncurses_ep
    URL https://ftp.gnu.org/gnu/ncurses/ncurses-${BOGGART_NCURSES_VERSION}.tar.gz
    URL_HASH SHA256=${BOGGART_NCURSES_SHA256}
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    CONFIGURE_COMMAND <SOURCE_DIR>/configure
      --prefix=${NCURSES_PREFIX}
      --without-shared --with-normal --enable-widec
      --with-termlib --enable-ext-colors
      --without-ada --without-tests --without-progs
      --without-cxx --without-cxx-binding --without-manpages
      --disable-db-install
    BUILD_COMMAND make -j
    INSTALL_COMMAND make install
    BUILD_BYPRODUCTS
      ${NCURSES_PREFIX}/lib/libncursesw.a
      ${NCURSES_PREFIX}/lib/libtinfow.a)
  add_library(curses_backend STATIC IMPORTED GLOBAL)
  add_dependencies(curses_backend ncurses_ep)
  set_target_properties(curses_backend PROPERTIES
    IMPORTED_LOCATION ${NCURSES_PREFIX}/lib/libncursesw.a
    INTERFACE_LINK_LIBRARIES ${NCURSES_PREFIX}/lib/libtinfow.a
    INTERFACE_COMPILE_DEFINITIONS _XOPEN_SOURCE_EXTENDED)
  set_property(TARGET curses_backend PROPERTY INTERFACE_INCLUDE_DIRECTORIES
    ${NCURSES_PREFIX}/include
    ${NCURSES_PREFIX}/include/ncursesw)
endif()

add_library(ltui_curses STATIC ${VENDOR}/ltui/curses.c)
# Headers only from Lua: this is a static lib, so the Lua symbols resolve at
# the executable link. Linking lua_vendor here just makes ld warn about a
# duplicate archive.
target_include_directories(ltui_curses PRIVATE ${LUA_SRC})
target_link_libraries(ltui_curses PRIVATE curses_backend boggart_quiet)
if(TARGET ncurses_ep)
  add_dependencies(ltui_curses ncurses_ep)
endif()
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

# ---- voice input: whisper.cpp + miniaudio (opt-in) -------------------------
# Native speech-to-text ("speak and/or type"). The whole stack -- whisper.cpp,
# GGML, and the miniaudio capture header -- is heavy (a multi-minute cold build
# and a GGML backend per platform), so it is opt-in behind BOGGART_VOICE and OFF
# by default: a normal build and CI never fetch it. src/lvoice.c is compiled into
# both binaries regardless; without the option it degrades to voice.built()==false
# and the front ends hide the affordance. See src/lvoice.c.
#
# When ON: whisper.cpp is FetchContent'd and linked statically (same mechanism as
# SDL3/curl), and miniaudio is vendored as one implementation TU (like sqlite).
# The model weights are NOT bundled -- voice.model_path() resolves them at run
# time from $BOGGART_WHISPER_MODEL or ~/.boggart/models/ggml-base.en.bin.
option(BOGGART_VOICE "Build native voice input (whisper.cpp + miniaudio)" OFF)

set(VOICE_LIBS "")
set(VOICE_DEFS "")
if(BOGGART_VOICE)
  # whisper.cpp / GGML are C++. The project is declared C-only (project(boggart C)),
  # so turn CXX on for this configuration; it also means the executables that link
  # whisper must be linked with the C++ driver (LINKER_LANGUAGE CXX below) to pull
  # in libc++/libstdc++.
  enable_language(CXX)
  # GGML's Metal backend is Objective-C (.m). GGML enables OBJC itself, but the
  # top-level project must own the compile rules before the studio (SDL) build is
  # generated alongside it, or the generate step fails on a missing
  # CMAKE_OBJC_COMPILE_OBJECT. Enabling it here is harmless off Apple's Metal path.
  if(APPLE)
    enable_language(OBJC)
  endif()
  set(BOGGART_WHISPER_VERSION 1.9.3)
  set(BOGGART_WHISPER_SHA256 1650f884effba487025143bd8facd2f9fb40a83b3737a732803c67a8d659d9c0)

  # Library only: no CLI examples, no server, no tests. GGML picks its backend
  # per platform (Metal on Apple, CUDA where present, CPU otherwise). Embedding
  # the Metal library keeps boggart-studio genuinely one file -- no .metallib to
  # ship beside it.
  set(WHISPER_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
  set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
  set(WHISPER_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
  if(APPLE)
    set(GGML_METAL_EMBED_LIBRARY ON CACHE BOOL "" FORCE)
  endif()

  include(FetchContent)
  FetchContent_Declare(whisper
    URL https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v${BOGGART_WHISPER_VERSION}.tar.gz
    URL_HASH SHA256=${BOGGART_WHISPER_SHA256}
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
  FetchContent_MakeAvailable(whisper)

  # miniaudio: single-header capture library, compiled once as its own static
  # lib (pattern of sqlite_vendor). Capture-only build flags live in the .c.
  add_library(miniaudio_vendor STATIC ${VENDOR}/miniaudio/miniaudio.c)
  target_include_directories(miniaudio_vendor PUBLIC ${VENDOR}/miniaudio)
  target_link_libraries(miniaudio_vendor PRIVATE boggart_quiet)
  if(APPLE)
    target_link_libraries(miniaudio_vendor PUBLIC
      "-framework CoreAudio" "-framework CoreFoundation" "-framework AudioToolbox")
  elseif(UNIX)
    target_link_libraries(miniaudio_vendor PUBLIC ${CMAKE_DL_LIBS} m pthread)
  endif()

  set(VOICE_LIBS whisper miniaudio_vendor)
  set(VOICE_DEFS BOGGART_VOICE=1)
endif()

# ---- LLM Station client: libzmq (opt-in) -----------------------------------
# The native DEALER client for LLM Station's ZeroMQ daemon protocol
# (src/lstation.c, docs/station-zmq.md). Opt-in behind BOGGART_STATION and OFF
# by default on the BOGGART_VOICE doctrine: a normal build and CI never fetch
# libzmq, src/lstation.c is compiled into both binaries regardless, and
# without the option it degrades to station.built()==false (discovery and the
# msgpack codec still work -- they need only sqlite/cJSON). libzmq is C++, so
# like voice this turns CXX on and the executables link with the C++ driver.
option(BOGGART_STATION "Build the native LLM Station ZeroMQ client" OFF)

set(STATION_LIBS "")
set(STATION_DEFS "")
if(BOGGART_STATION)
  enable_language(CXX)
  set(BOGGART_ZMQ_VERSION 4.3.5)
  set(BOGGART_ZMQ_SHA256 6653ef5910f17954861fe72332e68b03ca6e4d9c7160eb3a8de5a5a913bfab43)

  # Static library only: no tests, no perf tools, no draft sockets, no docs.
  set(BUILD_TESTS     OFF CACHE BOOL "" FORCE)
  set(ZMQ_BUILD_TESTS OFF CACHE BOOL "" FORCE)
  set(BUILD_SHARED    OFF CACHE BOOL "" FORCE)
  set(BUILD_STATIC    ON  CACHE BOOL "" FORCE)
  set(WITH_PERF_TOOL  OFF CACHE BOOL "" FORCE)
  set(WITH_DOCS       OFF CACHE BOOL "" FORCE)
  set(ENABLE_DRAFTS   OFF CACHE BOOL "" FORCE)
  set(WITH_LIBSODIUM  OFF CACHE BOOL "" FORCE)

  include(FetchContent)
  FetchContent_Declare(libzmq
    URL https://github.com/zeromq/libzmq/releases/download/v${BOGGART_ZMQ_VERSION}/zeromq-${BOGGART_ZMQ_VERSION}.tar.gz
    URL_HASH SHA256=${BOGGART_ZMQ_SHA256}
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
  # The 4.3.5 release predates CMake's current minimum-version floor; scope
  # the compatibility knob to this fetch so nothing else inherits it.
  set(CMAKE_POLICY_VERSION_MINIMUM 3.5)
  FetchContent_MakeAvailable(libzmq)
  unset(CMAKE_POLICY_VERSION_MINIMUM)

  set(STATION_LIBS libzmq-static)
  set(STATION_DEFS BOGGART_STATION=1)
endif()

# ---- generated embedded Lua ------------------------------------------------
# Bakes lua/**/*.lua AND lua/**/*.json into a C lookup table. Regenerated
# whenever any embedded source changes; written to the build dir to keep the
# source tree clean. The .json files (models.json) must be in DEPENDS too, or
# editing the catalog seed silently does not re-bake.
file(GLOB_RECURSE LUA_MODULES CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/lua/*.lua)
file(GLOB_RECURSE EMBED_DATA CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/lua/*.json)
set(EMBEDDED_C ${CMAKE_CURRENT_BINARY_DIR}/embedded.c)

add_custom_command(
  OUTPUT ${EMBEDDED_C}
  COMMAND ${CMAKE_COMMAND}
          -DLUA_DIR=${CMAKE_CURRENT_SOURCE_DIR}/lua
          -DOUT=${EMBEDDED_C}
          -P ${CMAKE_CURRENT_SOURCE_DIR}/tools/bake_embedded.cmake
  DEPENDS ${LUA_MODULES} ${EMBED_DATA} ${CMAKE_CURRENT_SOURCE_DIR}/tools/bake_embedded.cmake
  COMMENT "Baking lua/ into embedded.c"
  VERBATIM)

# Pinned syntax parsers for process mining. Lua owns indexing and normalization.
add_library(mining_parser_vendor STATIC
  ${VENDOR}/tree-sitter/lib/src/lib.c
  ${VENDOR}/tree-sitter-lua/src/parser.c
  ${VENDOR}/tree-sitter-lua/src/scanner.c)
target_include_directories(mining_parser_vendor PUBLIC
  ${VENDOR}/tree-sitter/lib/include)
target_include_directories(mining_parser_vendor PRIVATE
  ${VENDOR}/tree-sitter/lib/src
  ${VENDOR}/tree-sitter-lua/src)
target_link_libraries(mining_parser_vendor PRIVATE boggart_quiet)

# ---- the executable --------------------------------------------------------
# (An earlier plan had a hand-written src/sysproc_{posix,win32}.c platform
# shim, wired in here by a glob. Vendoring libuv + luv replaced it: uv_spawn
# and uv_pipe_t already provide spawn, non-blocking pipe reads and the Win32
# overlapped-I/O handling, so the shim and its glob are gone.)
add_executable(boggart
  src/boggart.c
  src/bogcrash.c
  src/ljson.c
  src/lhash.c
  src/lview.c
  src/lterminal.c
  src/lhttp.c
  src/lsys.c
  src/ldb.c
  src/lrepo.c
  src/lmining_parser.c
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
  src/lbus.c
  src/lserve.c
  src/lvoice.c
  src/lstation.c
  src/ltypesafe.c
  ${EMBEDDED_C})

target_include_directories(boggart PRIVATE src)
target_link_libraries(boggart PRIVATE
  boggart_warnings
  lua_vendor mining_parser_vendor sqlite_vendor cjson_vendor ltui_curses luv_lua uv_a
  isocline_vendor CURL::libcurl ${VOICE_LIBS} ${STATION_LIBS})
target_compile_definitions(boggart PRIVATE ${VOICE_DEFS} ${STATION_DEFS})
if(BOGGART_VOICE OR BOGGART_STATION)
  # C executable, C++ static deps (whisper/ggml, libzmq): link with the C++
  # driver so libc++/libstdc++ comes along.
  set_target_properties(boggart PROPERTIES LINKER_LANGUAGE CXX)
endif()
if(NOT WIN32)
  target_link_libraries(boggart PRIVATE mbedtls mbedx509 mbedcrypto)
endif()

# Keep ./boggart at the repo root, as the README documents. The per-config
# properties matter only for multi-config generators (Visual Studio, Xcode),
# which would otherwise append a Debug/ or Release/ subdirectory. A SANITIZER
# build writes into its own build tree instead: an instrumented binary must
# never replace the one people run.
if(BOGGART_SANITIZER STREQUAL "none")
  set(BOGGART_OUT_DIR ${CMAKE_CURRENT_SOURCE_DIR})
else()
  set(BOGGART_OUT_DIR ${CMAKE_CURRENT_BINARY_DIR})
endif()
set_target_properties(boggart PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY                ${BOGGART_OUT_DIR}
  RUNTIME_OUTPUT_DIRECTORY_DEBUG          ${BOGGART_OUT_DIR}
  RUNTIME_OUTPUT_DIRECTORY_RELEASE        ${BOGGART_OUT_DIR}
  RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO ${BOGGART_OUT_DIR}
  RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL     ${BOGGART_OUT_DIR})

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

# ---- SDL3 -------------------------------------------------------------------
# Built from source and linked statically, so boggart-studio is genuinely one
# file. Same reasoning and the same mechanism as the Windows libcurl above:
# FetchContent, pinned by release tarball + SHA256, everything optional off.
#
# The system package cannot do this job on macOS, and not for a packaging
# reason. Homebrew's `sdl2` is `sdl2-compat`, a shim whose libSDL2 dlopens
# SDL3 from an absolute Cellar path -- verified with DYLD_PRINT_LIBRARIES. So a
# binary linked against it reaches into /opt/homebrew at run time even after
# install_name_tool has been pointed at a bundled copy, and it is not SDL2 that
# ends up running either. Building the real SDL3 and linking it statically is
# the only way to know what is in the binary.
#
# Cost: two or three minutes on a cold build, cached afterwards, and a version
# pin someone has to bump. In exchange, the studio has no runtime dependency on
# SDL at all -- no `brew install sdl3`, no SDL3.dll beside the exe, no
# libsdl3-0 package -- on any platform.
#
# -DBOGGART_SDL_FROM_SOURCE=OFF falls back to whatever SDL3 the system has,
# which is the right choice for a distribution package: a distro wants to own
# and patch its own SDL, and it is not shipping our binary anyway.
option(BOGGART_SDL_FROM_SOURCE
  "Build SDL3 from source and link it statically (self-contained binary)" ON)

if(BOGGART_BUILD_APP AND BOGGART_SDL_FROM_SOURCE)
  set(BOGGART_SDL_VERSION 3.4.14)
  set(BOGGART_SDL_SHA256 30d4aa2b3037718142b32dffd4e72f917ebb6cc5227150e7bb9c45efb2153aeb)

  set(SDL_SHARED        OFF CACHE BOOL "" FORCE)
  set(SDL_STATIC        ON  CACHE BOOL "" FORCE)
  set(SDL_TEST_LIBRARY  OFF CACHE BOOL "" FORCE)
  set(SDL_TESTS         OFF CACHE BOOL "" FORCE)
  set(SDL_EXAMPLES      OFF CACHE BOOL "" FORCE)
  set(SDL_INSTALL       OFF CACHE BOOL "" FORCE)
  # The studio draws into a window and reads keyboard, mouse and window
  # events. It has never opened an audio device, a joystick, a camera or a
  # sensor, so those subsystems are dead weight in the binary and dead code
  # paths in a threat model. Video and the 2D renderer stay on: they are the
  # GPU backend. The low-level SDL_GPU API is left at SDL's default so the
  # renderer can use it as one of its backends.
  set(SDL_AUDIO         OFF CACHE BOOL "" FORCE)
  set(SDL_CAMERA        OFF CACHE BOOL "" FORCE)
  set(SDL_HAPTIC        OFF CACHE BOOL "" FORCE)
  set(SDL_JOYSTICK      OFF CACHE BOOL "" FORCE)
  set(SDL_HIDAPI        OFF CACHE BOOL "" FORCE)
  set(SDL_SENSOR        OFF CACHE BOOL "" FORCE)
  set(SDL_POWER         OFF CACHE BOOL "" FORCE)
  set(SDL_DIALOG        OFF CACHE BOOL "" FORCE)
  set(SDL_TRAY          OFF CACHE BOOL "" FORCE)

  include(FetchContent)
  FetchContent_Declare(sdl3
    URL https://github.com/libsdl-org/SDL/releases/download/release-${BOGGART_SDL_VERSION}/SDL3-${BOGGART_SDL_VERSION}.tar.gz
    URL_HASH SHA256=${BOGGART_SDL_SHA256})
  FetchContent_MakeAvailable(sdl3)

  # SDL3::SDL3-static carries its own interface include dirs and the platform
  # libraries a static build needs (the macOS frameworks, dl/pthread/m on
  # Linux, the Win32 import libraries), so nothing below has to know them.
  set(SDL3_FOUND TRUE)
  set(BOGGART_SDL_TARGET SDL3::SDL3-static)
elseif(BOGGART_BUILD_APP)
  find_package(SDL3 QUIET CONFIG COMPONENTS SDL3)
  if(NOT SDL3_FOUND)
    find_package(PkgConfig QUIET)
    if(PkgConfig_FOUND)
      pkg_check_modules(SDL3 QUIET sdl3)
    endif()
  endif()
endif()

# ---- FreeType ---------------------------------------------------------------
# The text rasteriser. Same mechanism and the same reasoning as the SDL3 block
# above: FetchContent, pinned by release tarball + SHA256, every optional
# dependency switched off, linked statically, so `otool -L boggart-studio`
# still lists nothing but system libraries.
#
# It replaces stb_truetype, which was a single vendored header and cost
# nothing. What that header cannot do is hint: it scales the outline and
# rasterises wherever it lands, so small text is uniformly soft. That is the
# whole legibility gap, and it is not closable downstream of the rasteriser.
# See the comment at the top of studio/src/fontglyph.c.
#
# Cost, measured on an M-series mac: 680 KB of binary (5.14 MB -> 5.82 MB) and
# five seconds of single-threaded compile, cached after -- next to SDL3's two
# to three minutes it is not the expensive fetch here.
#
# Everything optional is off -- no zlib, bzip2, libpng, HarfBuzz or Brotli --
# which means no transitive fetches and no system packages. It costs us:
# compressed WOFF2 fonts (Brotli), PNG-backed colour-emoji strikes (libpng),
# and HarfBuzz-assisted autohinting of Indic scripts. None of those are things
# this renderer draws -- fontfallback.c refuses colour fonts on separate
# grounds. The separate OpenType shaper below supplies positioned glyph IDs;
# FreeType does not link HarfBuzz back for autohinting.
#
# Guarded on SDL3_FOUND as well as BOGGART_BUILD_APP so that a machine without
# SDL3, which builds the CLI and skips the studio, does not download a
# rasteriser it will not link.
if(BOGGART_BUILD_APP AND SDL3_FOUND)
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
    URL_HASH SHA256=${BOGGART_FREETYPE_SHA256}
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
  FetchContent_MakeAvailable(freetype)
endif()

if(BOGGART_BUILD_APP AND SDL3_FOUND)
  # Upstream's supported amalgamation, static OpenType backend only. This avoids
  # its CMake auto-enabling FreeType interop when our freetype target exists.
  # Our C calls shape owned bytes; the existing FreeType alone rasterizes IDs.
  include(FetchContent)
  FetchContent_Declare(harfbuzz
    URL https://github.com/harfbuzz/harfbuzz/releases/download/14.4.0/harfbuzz-14.4.0.tar.xz
    URL_HASH SHA256=2357ed966c6ced7bfa720b0640c0231065af01158fbea215093ffa15aed44371
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    SOURCE_SUBDIR boggart-amalgamation-only)
  FetchContent_MakeAvailable(harfbuzz)
  add_library(boggart_harfbuzz STATIC ${harfbuzz_SOURCE_DIR}/src/harfbuzz.cc)
  target_compile_features(boggart_harfbuzz PRIVATE cxx_std_11)
  target_include_directories(boggart_harfbuzz PUBLIC ${harfbuzz_SOURCE_DIR}/src)
  target_compile_definitions(boggart_harfbuzz PRIVATE
    HB_NO_GETENV HB_NO_BUFFER_SERIALIZE HB_NO_BUFFER_VERIFY HB_NO_DRAW HB_NO_PAINT
    HB_NO_COLOR HB_NO_OT_FONT_GLYPH_NAMES HB_NO_SUBSET_DEPEND
    HB_BUFFER_MAX_LEN_FACTOR=4 HB_BUFFER_MAX_LEN_MIN=256
    HB_BUFFER_MAX_OPS_FACTOR=1024 HB_BUFFER_MAX_OPS_MIN=65536)
  target_link_libraries(boggart_harfbuzz PRIVATE boggart_quiet)
endif()

if(BOGGART_BUILD_APP AND SDL3_FOUND)
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
    src/bogcrash.c
    src/ljson.c
    src/lhash.c
    src/lview.c
    src/lterminal.c
    ${STUDIO_ASSETS_C}
    src/lhttp.c
    src/lsys.c
    src/ldb.c
    src/lrepo.c
    src/lmining_parser.c
    src/lswarm.c
    src/lmcp.c
    src/lgit.c
    src/jwriter.c
    src/lauth.c
    src/lworker.c
    src/bogembed.c
  src/lmem.c
  src/lbus.c
  src/lserve.c
  src/lvoice.c
  src/lstation.c
  src/ltypesafe.c
    ${EMBEDDED_C})

  target_include_directories(boggart-studio PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/studio/src
    ${VENDOR}/stb
    ${SDL3_INCLUDE_DIRS})
  target_compile_definitions(boggart-studio PRIVATE BOGGART_STUDIO=1 ${VOICE_DEFS} ${STATION_DEFS})
  target_link_libraries(boggart-studio PRIVATE
    boggart_warnings
    lua_vendor mining_parser_vendor sqlite_vendor cjson_vendor luv_lua uv_a isocline_vendor
    CURL::libcurl freetype boggart_harfbuzz ${VOICE_LIBS} ${STATION_LIBS})
  if(BOGGART_VOICE OR BOGGART_STATION)
    set_target_properties(boggart-studio PROPERTIES LINKER_LANGUAGE CXX)
  endif()
  if(NOT WIN32)
    target_link_libraries(boggart-studio PRIVATE mbedtls mbedx509 mbedcrypto)
  endif()
  # forkpty/openpty for the embedded terminal (studio/src/api/pty.c) live in
  # libutil on Linux (glibc < 2.34); on macOS they are in libSystem already.
  if(UNIX AND NOT APPLE)
    target_link_libraries(boggart-studio PRIVATE util)
  endif()
  # Three spellings, because SDL3 arrives three ways: our own static build sets
  # BOGGART_SDL_TARGET, a system SDL3Config.cmake gives the SDL3::SDL3 target,
  # and pkg-config gives bare library names and directories. Installed SDL3
  # CMake files no longer set SDL3_INCLUDE_DIRS; the imported target carries
  # them.
  if(BOGGART_SDL_TARGET)
    target_link_libraries(boggart-studio PRIVATE ${BOGGART_SDL_TARGET})
  elseif(SDL3_LIBRARIES)
    target_link_libraries(boggart-studio PRIVATE ${SDL3_LIBRARIES})
    target_link_directories(boggart-studio PRIVATE ${SDL3_LIBRARY_DIRS})
  else()
    target_link_libraries(boggart-studio PRIVATE SDL3::SDL3)
  endif()
  # SDL3 removed the SDLmain library. Windows still rewrites main() to
  # SDL_main via SDL_main.h, which studio/src/main.c includes; the rewrite
  # is header-only now, so there is nothing extra to link.
  # The editor core came from rxi's lite and still warns; ours build clean.
  set_source_files_properties(${APP_SOURCES} PROPERTIES COMPILE_OPTIONS "-w")
  set_target_properties(boggart-studio PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${BOGGART_OUT_DIR})
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
      BOGGART_STUDIO_LEGACY=1
      BOGGART_STUDIO_SCRIPT=${CMAKE_CURRENT_SOURCE_DIR}/tools/uishot.lua
      BOGGART_STUDIO_SHOT=${CMAKE_CURRENT_BINARY_DIR}/studio-shot.bmp
      $<TARGET_FILE:boggart-studio> ${CMAKE_CURRENT_SOURCE_DIR}
    DEPENDS boggart-studio
    COMMENT "Rendering the legacy studio composition and checking the agent panel"
    USES_TERMINAL)

  # `ninja ui-tracker` renders the tracker tab (list, selection, board) to
  # studio-tracker-*.bmp. Needs tracker data in the store (`/tracker import`).
  add_custom_target(ui-tracker
    COMMAND ${CMAKE_COMMAND} -E env
      BOGGART_STUDIO_SCRIPT=${CMAKE_CURRENT_SOURCE_DIR}/tools/uitracker.lua
      BOGGART_STUDIO_SHOT=${CMAKE_CURRENT_BINARY_DIR}/studio-tracker.bmp
      $<TARGET_FILE:boggart-studio> ${CMAKE_CURRENT_SOURCE_DIR}
    DEPENDS boggart-studio
    COMMENT "Rendering the tracker tab"
    USES_TERMINAL)

  # `ninja ui-overlay` guards the dirty-rect/overlay invariant: a menu dropdown
  # must survive a frame in which only the content *under* it was damaged. The
  # empty-clip-is-not-no-clip bug (renderer.c) made an unrelated view paint over
  # the whole target on exactly those frames, which is what "the menus flicker"
  # was. Needs the shell composition (the menu bar), so not ui-check's legacy one.
  add_custom_target(ui-overlay
    COMMAND ${CMAKE_COMMAND} -E env
      BOGGART_STUDIO_SCRIPT=${CMAKE_CURRENT_SOURCE_DIR}/tools/uioverlay.lua
      BOGGART_STUDIO_SHOT=${CMAKE_CURRENT_BINARY_DIR}/studio-overlay.bmp
      $<TARGET_FILE:boggart-studio> ${CMAKE_CURRENT_SOURCE_DIR}
    DEPENDS boggart-studio
    COMMENT "Checking an overlay survives a partially damaged frame"
    USES_TERMINAL)

  # `ninja ui-discover` guards findability: no menu row pointing at a command
  # that does not exist, and no product-surface command without a menu home.
  # Written after a measurement -- 248 commands, 76 in menus -- because "some
  # features are too hard to find" is a bug with a number attached.
  add_custom_target(ui-discover
    COMMAND ${CMAKE_COMMAND} -E env
      BOGGART_STUDIO_SCRIPT=${CMAKE_CURRENT_SOURCE_DIR}/tools/uidiscover.lua
      $<TARGET_FILE:boggart-studio> ${CMAKE_CURRENT_SOURCE_DIR}
    DEPENDS boggart-studio
    COMMENT "Checking every studio feature can be found from a menu"
    USES_TERMINAL)

  add_custom_target(studio-start
    COMMAND ${CMAKE_COMMAND} -E env
      BOGGART_STUDIO_SCRIPT=${CMAKE_CURRENT_SOURCE_DIR}/tools/uistart.lua
      $<TARGET_FILE:boggart-studio> ${CMAKE_CURRENT_SOURCE_DIR}
    DEPENDS boggart-studio
    COMMENT "Starting boggart-studio and checking the first paint"
    USES_TERMINAL)
elseif(BOGGART_BUILD_APP)
  message(STATUS "SDL3 not found -- skipping boggart-studio (the CLI still builds)")
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
add_test(NAME cell_partition COMMAND ${CMAKE_COMMAND} -E env BOGGART_HOME=${CMAKE_CURRENT_BINARY_DIR}/testhome/cell_partition $<TARGET_FILE:boggart> --eval ${CMAKE_CURRENT_SOURCE_DIR}/tests/cell_partition.lua)
set_tests_properties(cell_partition PROPERTIES WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
add_library(boggart_unicode STATIC src/bunicode.c)
target_include_directories(boggart_unicode PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/src)
add_executable(unicode_test tests/c/unicode.c)
target_link_libraries(unicode_test PRIVATE boggart_unicode)
add_test(NAME unicode COMMAND unicode_test
  ${CMAKE_CURRENT_SOURCE_DIR}/THIRD_PARTY/unicode/16.0.0/auxiliary/GraphemeBreakTest.txt)
# Embed the sources actually compiled into this terminal backend. Benchmarks
# reject a stale executable instead of attributing it to current disk contents.
set(BMUX_TERMINAL_SOURCE_FILES src/bpty.c src/bpty.h src/lvt.c src/vt_table.h src/lstyle.c src/llink.c src/lpage.c src/lpage_resize.c src/lpage_layout.c src/lpage_layout.h src/lidmap.c src/lidmap.h src/lbitmap.c src/lbitmap.h
  src/bterm.c src/bterm_dispatch.c src/bterm_sgr.c src/bosc.c src/bmouse.c src/bkey.c src/bpaste.c src/bterm_osc.c src/lterminal.c src/lterminal.h
  src/lvt.h src/lstyle.h src/llink.h src/lpage.h src/lpage_internal.h src/bosc.h src/bmouse.h src/bkey.h src/bpaste.h src/bterm.h src/bterm_internal.h
  src/bunicode.c src/bunicode.h src/bunicode_data.h src/btunicode.c src/btunicode.h src/btunicode_data.h src/lgrapheme.c src/lgrapheme.h)
set(_terminal_source_header "/* Generated build identity; do not edit. */\nstatic const struct { const char *path, *sha256; } terminal_source_files[] = {\n")
foreach(_source IN LISTS BMUX_TERMINAL_SOURCE_FILES)
  file(SHA256 "${CMAKE_CURRENT_SOURCE_DIR}/${_source}" _sha)
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/${_source}")
  string(APPEND _terminal_source_header "  {\"${_source}\", \"${_sha}\"},\n")
endforeach()
string(APPEND _terminal_source_header "};\n")
file(CONFIGURE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/terminal-source.h" CONTENT "${_terminal_source_header}" @ONLY)
target_include_directories(boggart PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
if(TARGET boggart-studio)
  target_include_directories(boggart-studio PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
  set(_renderer_source_header "/* Generated renderer build identity. */\nstatic const struct { const char *path, *sha256; } terminalrender_source_files[] = {\n")
  foreach(_source CMakeLists.txt studio/src/renderer.c studio/src/renderer.h studio/src/fontglyph.c studio/src/fontglyph.h
      studio/src/gridtext.c studio/src/clusterdraw.c studio/src/fontshape.c studio/src/fontshape.h studio/src/fontcluster.c studio/src/fontcluster.h studio/src/glyphcache.c studio/src/glyphcache.h studio/src/rencache.c studio/src/rencache.h
      studio/src/termgrid.c studio/src/termgrid.h studio/src/termrender.c studio/src/termrender.h studio/src/fontatlas.c studio/src/fontatlas.h
      studio/src/api/renderer.c studio/src/api/renderer_font.c studio/src/api/terminalrender.c)
    file(SHA256 "${CMAKE_CURRENT_SOURCE_DIR}/${_source}" _sha)
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/${_source}")
    string(APPEND _renderer_source_header "  {\"${_source}\", \"${_sha}\"},\n")
  endforeach()
  string(APPEND _renderer_source_header "};\n")
  file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/terminalrender_source.h "${_renderer_source_header}")
endif()
add_library(boggart_vt STATIC src/lvt.c src/lstyle.c src/llink.c src/lpage.c src/lpage_resize.c src/lpage_layout.c src/lidmap.c src/lbitmap.c src/lgrapheme.c src/btunicode.c
  src/bterm.c src/bterm_dispatch.c src/bterm_sgr.c src/bosc.c src/bmouse.c src/bkey.c src/bpaste.c src/bterm_osc.c)
target_include_directories(boggart_vt PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/src)
target_link_libraries(boggart_vt PUBLIC boggart_unicode)
add_library(boggart_pty STATIC src/bpty.c)
target_include_directories(boggart_pty PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/src)
target_link_libraries(boggart_pty PUBLIC boggart_vt uv_a)
if(UNIX AND NOT APPLE)
  target_link_libraries(boggart_pty PUBLIC util)
endif()
target_link_libraries(boggart PRIVATE boggart_pty)
if(TARGET boggart-studio)
  target_link_libraries(boggart-studio PRIVATE boggart_pty)
endif()
if(UNIX)
  add_executable(pty_transport_test tests/c/pty_transport.c)
  target_link_libraries(pty_transport_test PRIVATE boggart_pty)
  add_test(NAME pty_transport COMMAND pty_transport_test)
  set_tests_properties(pty_transport PROPERTIES TIMEOUT 30)
endif()
if(TARGET boggart-studio AND UNIX)
  add_executable(studio_uvbridge_test tests/c/studio_uvbridge.c studio/src/uvbridge.c)
  target_include_directories(studio_uvbridge_test PRIVATE studio/src ${SDL3_INCLUDE_DIRS})
  target_link_libraries(studio_uvbridge_test PRIVATE uv_a)
  if(BOGGART_SDL_TARGET)
    target_link_libraries(studio_uvbridge_test PRIVATE ${BOGGART_SDL_TARGET})
  elseif(TARGET SDL3::SDL3)
    target_link_libraries(studio_uvbridge_test PRIVATE SDL3::SDL3)
  else()
    target_link_libraries(studio_uvbridge_test PRIVATE ${SDL3_LIBRARIES})
    target_link_directories(studio_uvbridge_test PRIVATE ${SDL3_LIBRARY_DIRS})
  endif()
  add_test(NAME studio_uvbridge COMMAND studio_uvbridge_test)
  set_tests_properties(studio_uvbridge PROPERTIES TIMEOUT 10)
endif()
target_link_libraries(boggart PRIVATE boggart_vt)
if(TARGET boggart-studio)
  target_link_libraries(boggart-studio PRIVATE boggart_vt)
endif()
add_executable(vt_parser_test tests/c/vt_parser.c)
target_link_libraries(vt_parser_test PRIVATE boggart_vt)
add_test(NAME vt_parser COMMAND vt_parser_test)
add_executable(page_storage_test tests/c/page.c)
target_link_libraries(page_storage_test PRIVATE boggart_vt)
add_test(NAME page_storage COMMAND page_storage_test)
add_executable(page_resize_test tests/c/page_resize.c)
target_link_libraries(page_resize_test PRIVATE boggart_vt)
add_test(NAME page_resize COMMAND page_resize_test)
add_executable(termgrid_test tests/c/termgrid.c)
target_include_directories(termgrid_test PRIVATE studio/src)
target_link_libraries(termgrid_test PRIVATE boggart_vt)
add_test(NAME termgrid COMMAND termgrid_test)
add_executable(terminal_text_width_test tests/c/terminal_text_width.c)
target_link_libraries(terminal_text_width_test PRIVATE boggart_vt)
add_test(NAME terminal_text_width COMMAND terminal_text_width_test)
if(TARGET boggart-studio)
  add_executable(termcache_test tests/c/termcache.c studio/src/termgrid.c)
  target_include_directories(termcache_test PRIVATE studio/src ${SDL3_INCLUDE_DIRS})
  target_link_libraries(termcache_test PRIVATE boggart_vt)
  if(BOGGART_SDL_TARGET)
    target_link_libraries(termcache_test PRIVATE ${BOGGART_SDL_TARGET})
  elseif(TARGET SDL3::SDL3)
    target_link_libraries(termcache_test PRIVATE SDL3::SDL3)
  else()
    target_link_libraries(termcache_test PRIVATE ${SDL3_LIBRARIES})
    target_link_directories(termcache_test PRIVATE ${SDL3_LIBRARY_DIRS})
  endif()
  add_test(NAME termcache COMMAND termcache_test)
  add_executable(renderer_fonts_test tests/c/renderer_fonts.c studio/src/gridtext.c studio/src/clusterdraw.c studio/src/fontshape.c studio/src/fontcluster.c studio/src/glyphcache.c studio/src/fontfallback.c studio/src/fontatlas.c studio/src/termgrid.c studio/src/termrender.c)
  target_include_directories(renderer_fonts_test PRIVATE studio/src ${SDL3_INCLUDE_DIRS})
  target_link_libraries(renderer_fonts_test PRIVATE boggart_vt freetype boggart_harfbuzz uv_a)
  if(UNIX)
    target_link_libraries(renderer_fonts_test PRIVATE m)
  endif()
  if(BOGGART_SDL_TARGET)
    target_link_libraries(renderer_fonts_test PRIVATE ${BOGGART_SDL_TARGET})
  elseif(TARGET SDL3::SDL3)
    target_link_libraries(renderer_fonts_test PRIVATE SDL3::SDL3)
  else()
    target_link_libraries(renderer_fonts_test PRIVATE ${SDL3_LIBRARIES})
    target_link_directories(renderer_fonts_test PRIVATE ${SDL3_LIBRARY_DIRS})
  endif()
  if(APPLE)
    target_link_libraries(renderer_fonts_test PRIVATE "-framework CoreText" "-framework CoreFoundation")
  endif()
  add_test(NAME renderer_fonts COMMAND renderer_fonts_test ${CMAKE_CURRENT_SOURCE_DIR}/studio/data/fonts/monospace.ttf)
  add_executable(renderer_clusters_test tests/c/renderer_clusters.c studio/src/gridtext.c studio/src/clusterdraw.c studio/src/fontshape.c studio/src/fontcluster.c studio/src/glyphcache.c studio/src/fontfallback.c studio/src/fontatlas.c studio/src/termgrid.c studio/src/termrender.c)
  target_include_directories(renderer_clusters_test PRIVATE studio/src ${SDL3_INCLUDE_DIRS})
  target_link_libraries(renderer_clusters_test PRIVATE boggart_vt freetype boggart_harfbuzz uv_a)
  if(UNIX)
    target_link_libraries(renderer_clusters_test PRIVATE m)
  endif()
  if(BOGGART_SDL_TARGET)
    target_link_libraries(renderer_clusters_test PRIVATE ${BOGGART_SDL_TARGET})
  elseif(TARGET SDL3::SDL3)
    target_link_libraries(renderer_clusters_test PRIVATE SDL3::SDL3)
  else()
    target_link_libraries(renderer_clusters_test PRIVATE ${SDL3_LIBRARIES})
    target_link_directories(renderer_clusters_test PRIVATE ${SDL3_LIBRARY_DIRS})
  endif()
  if(APPLE)
    target_link_libraries(renderer_clusters_test PRIVATE "-framework CoreText" "-framework CoreFoundation")
  endif()
  add_test(NAME renderer_clusters COMMAND ${CMAKE_COMMAND} -E env SDL_VIDEODRIVER=dummy $<TARGET_FILE:renderer_clusters_test> ${CMAKE_CURRENT_SOURCE_DIR}/studio/data/fonts/monospace.ttf ${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/fonts/NotoSansDevanagari.ttf)
  add_executable(renderer_atlas_test tests/c/renderer_atlas.c studio/src/fontshape.c studio/src/fontcluster.c studio/src/fontfallback.c)
  target_include_directories(renderer_atlas_test PRIVATE studio/src ${SDL3_INCLUDE_DIRS})
  target_link_libraries(renderer_atlas_test PRIVATE boggart_vt freetype boggart_harfbuzz uv_a)
  if(BOGGART_SDL_TARGET)
    target_link_libraries(renderer_atlas_test PRIVATE ${BOGGART_SDL_TARGET})
  elseif(TARGET SDL3::SDL3)
    target_link_libraries(renderer_atlas_test PRIVATE SDL3::SDL3)
  else()
    target_link_libraries(renderer_atlas_test PRIVATE ${SDL3_LIBRARIES})
    target_link_directories(renderer_atlas_test PRIVATE ${SDL3_LIBRARY_DIRS})
  endif()
  if(UNIX)
    target_link_libraries(renderer_atlas_test PRIVATE m)
  endif()
  if(APPLE)
    target_link_libraries(renderer_atlas_test PRIVATE "-framework CoreText" "-framework CoreFoundation")
  endif()
  add_test(NAME renderer_atlas COMMAND ${CMAKE_COMMAND} -E env SDL_VIDEODRIVER=dummy $<TARGET_FILE:renderer_atlas_test> ${CMAKE_CURRENT_SOURCE_DIR}/studio/data/fonts/monospace.ttf)
endif()
add_executable(page_layout_test tests/c/page_layout.c)
target_link_libraries(page_layout_test PRIVATE boggart_vt)
add_test(NAME page_layout COMMAND page_layout_test)
add_executable(bitmap_test tests/c/bitmap.c)
target_include_directories(bitmap_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
add_test(NAME bitmap COMMAND bitmap_test)
add_executable(idmap_test tests/c/idmap.c)
target_include_directories(idmap_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
add_test(NAME idmap COMMAND idmap_test)
add_executable(idmap_scalar_test tests/c/idmap.c)
target_compile_definitions(idmap_scalar_test PRIVATE LIDMAP_FORCE_SCALAR=1)
target_include_directories(idmap_scalar_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
add_test(NAME idmap_scalar COMMAND idmap_scalar_test)
add_executable(resize_failure_test tests/c/resize_failure.c)
target_link_libraries(resize_failure_test PRIVATE boggart_vt)
add_test(NAME resize_failure COMMAND resize_failure_test)
add_executable(wide_cells_test tests/c/wide_cells.c)
target_link_libraries(wide_cells_test PRIVATE boggart_vt)
add_test(NAME wide_cells COMMAND wide_cells_test)
add_executable(grapheme_cells_test tests/c/grapheme_cells.c)
target_link_libraries(grapheme_cells_test PRIVATE boggart_vt)
add_test(NAME grapheme_cells COMMAND grapheme_cells_test)
add_executable(terminal_dispatch_test tests/c/terminal.c)
target_link_libraries(terminal_dispatch_test PRIVATE boggart_vt)
add_test(NAME terminal_dispatch COMMAND terminal_dispatch_test)
add_executable(osc_commands_test tests/c/osc.c)
target_link_libraries(osc_commands_test PRIVATE boggart_vt)
add_test(NAME osc_commands COMMAND osc_commands_test)
add_executable(terminal_events_test tests/c/terminal_events.c)
target_link_libraries(terminal_events_test PRIVATE boggart_vt)
add_test(NAME terminal_events COMMAND terminal_events_test)
add_executable(terminal_links_test tests/c/links.c)
target_link_libraries(terminal_links_test PRIVATE boggart_vt)
add_test(NAME terminal_links COMMAND terminal_links_test)
add_executable(mouse_encode_test tests/c/mouse.c)
target_link_libraries(mouse_encode_test PRIVATE boggart_vt)
add_test(NAME mouse_encode COMMAND mouse_encode_test)
add_executable(terminal_mouse_test tests/c/terminal_mouse.c)
target_link_libraries(terminal_mouse_test PRIVATE boggart_vt)
add_test(NAME terminal_mouse COMMAND terminal_mouse_test)
add_executable(key_encode_test tests/c/key.c)
target_link_libraries(key_encode_test PRIVATE boggart_vt)
add_test(NAME key_encode COMMAND key_encode_test)
add_executable(terminal_key_test tests/c/terminal_key.c)
target_link_libraries(terminal_key_test PRIVATE boggart_vt)
add_test(NAME terminal_key COMMAND terminal_key_test)
add_executable(paste_encode_test tests/c/paste.c)
target_link_libraries(paste_encode_test PRIVATE boggart_vt)
add_test(NAME paste_encode COMMAND paste_encode_test)
add_executable(terminal_input_test tests/c/terminal_input.c)
target_link_libraries(terminal_input_test PRIVATE boggart_vt)
add_test(NAME terminal_input COMMAND terminal_input_test)
add_executable(terminal_unicode_test tests/c/terminal_unicode.c)
target_link_libraries(terminal_unicode_test PRIVATE boggart_vt)
add_test(NAME terminal_unicode COMMAND terminal_unicode_test)

# Headless native parse/grid throughput. Performance budgets are supplied
# explicitly after baseline measurement.
add_custom_target(termbench
  COMMAND ${CMAKE_COMMAND} -E env
    BOGGART_HOME=${CMAKE_CURRENT_BINARY_DIR}/termbench-home
    $<TARGET_FILE:boggart> --eval ${CMAKE_CURRENT_SOURCE_DIR}/tools/termbench.lua
  DEPENDS boggart
  WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
  COMMENT "Measuring terminal parse throughput and stream fragmentation"
  USES_TERMINAL)

# Explicit test-only oracle. Zig/Ghostty are never product dependencies.
set(BOGGART_GHOSTTY_ORACLE_WORK_ROOT "${CMAKE_CURRENT_BINARY_DIR}/ghostty-oracle"
    CACHE PATH "Scratch directory for the optional pinned Ghostty VT oracle")
add_custom_target(ghostty-oracle
  COMMAND python3 "${CMAKE_CURRENT_SOURCE_DIR}/tools/ghostty/build_oracle.py"
    --work-root "${BOGGART_GHOSTTY_ORACLE_WORK_ROOT}"
  COMMAND python3 "${CMAKE_CURRENT_SOURCE_DIR}/tests/ghostty_oracle_cli_test.py"
    --binary "${BOGGART_GHOSTTY_ORACLE_WORK_ROOT}/resize-oracle"
  COMMAND python3 "${CMAKE_CURRENT_SOURCE_DIR}/tools/ghostty/capture_resize.py"
    --binary "${BOGGART_GHOSTTY_ORACLE_WORK_ROOT}/resize-oracle" --check
  WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
  COMMENT "Building the pinned test oracle and verifying resize fixtures"
  USES_TERMINAL)

foreach(suite test integration swarm mcp ltui sysfs bus fabric trace supervisor wire jwriter worker proc sandbox scopes errors studio events lifecycle plan goap plansup claims prompt skills agentmodel skillrouter complete termrender goal loop tui_input tui_agents vim luatool llmstation dispatch gitcmd choose front voice codesearch perm control triggers structured route catalog roles sessions projects station callable typesafe judge ladder toolroute ladder_sites harden policy quota invoke capability context workflow evidence runstore imports evidence_retention aibywire memory mining_ast mining_recognition mining_compile mining_jobs learning_evaluate learning_promote learning_route learning_monitor workflow_slack workflow_novel workflow_triggers searchroute tracker story story_model story_geo story_geosql story_style auth_file looplag http_body json_c store_save hash_c fileview termbench terminal terminal_input_route terminal_process terminal_process_shutdown terminal_graphemes terminal_resize terminal_resize_cached terminal_resize_api terminal_resize_large ghostty_page_growth ghostty_bitmap)
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

if(TARGET boggart-studio)
  set(_process_home ${CMAKE_CURRENT_BINARY_DIR}/testhome/terminal_process_studio)
  add_test(NAME terminal_process_studio
    COMMAND ${CMAKE_COMMAND} -E env HOME=${_process_home} USERPROFILE=${_process_home}
      LOCALAPPDATA=${_process_home}/AppData/Local BOGGART_HOME=${_process_home}/.boggart
      SDL_VIDEODRIVER=dummy BOGGART_STUDIO_SCRIPT=${CMAKE_CURRENT_SOURCE_DIR}/tests/terminal_process_studio.lua
      $<TARGET_FILE:boggart-studio> .
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
  set_tests_properties(terminal_process_studio PROPERTIES TIMEOUT 30)
  set(_pane_suites studio_terminal_native studio_terminal_shutdown studio_terminal_render studio_terminal_clusters studio_grid_text studio_agent_clusters studio_bmux)
  if(UNIX AND EXISTS /usr/bin/vim)
    list(APPEND _pane_suites studio_terminal_vim)
  endif()
  foreach(_pane_suite IN LISTS _pane_suites)
    set(_pane_home ${CMAKE_CURRENT_BINARY_DIR}/testhome/${_pane_suite})
    set(_pane_shell_env)
    if(_pane_suite STREQUAL "studio_bmux")
      # Test interactive input without inheriting a user's shell startup scripts.
      set(_pane_shell_env SHELL=/bin/sh)
    endif()
    add_test(NAME ${_pane_suite}
      COMMAND ${CMAKE_COMMAND} -E env HOME=${_pane_home} USERPROFILE=${_pane_home}
        LOCALAPPDATA=${_pane_home}/AppData/Local BOGGART_HOME=${_pane_home}/.boggart
        ${_pane_shell_env}
        SDL_VIDEODRIVER=dummy BMUX_RENDER_DIR=${_pane_home} BOGGART_STUDIO_SCRIPT=${CMAKE_CURRENT_SOURCE_DIR}/tests/${_pane_suite}.lua
        $<TARGET_FILE:boggart-studio> .
      WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
    set_tests_properties(${_pane_suite} PROPERTIES TIMEOUT 15)
  endforeach()
endif()

# termctl (B0 of the cTUI, docs/cli-plan.md): the dependency-free full-screen
# terminal layer. Compiled standalone and smoke-tested here so it stays
# build-verified and regression-guarded before the cTUI that consumes it exists.
# The smoke test degrades gracefully with no tty, so </dev/null it self-exits 0.
add_executable(termctl_smoke src/termctl.c src/termctl_test.c)
target_include_directories(termctl_smoke PRIVATE src ${VENDOR}/libuv/include)
target_link_libraries(termctl_smoke PRIVATE uv_a boggart_unicode)
add_test(NAME termctl COMMAND sh -c "$<TARGET_FILE:termctl_smoke> </dev/null")

# BOG-6: the credential code under concurrency (8 threads reading headers while
# the file is rewritten). Run under BOGGART_SANITIZER=thread for the race check.
add_executable(auth_threads_test tests/c/auth_threads.c src/lauth.c)
target_include_directories(auth_threads_test PRIVATE src ${VENDOR}/libuv/include ${VENDOR}/sqlite)
target_link_libraries(auth_threads_test PRIVATE uv_a sqlite_vendor lua_vendor)
add_test(NAME auth_threads COMMAND auth_threads_test)

# BOG-8: always-on asserts trap at the call site with condition and file:line.
if(NOT WIN32)
  add_executable(assert_trap_test tests/c/assert_trap.c)
  target_include_directories(assert_trap_test PRIVATE src)
  target_link_libraries(assert_trap_test PRIVATE lua_vendor)
  add_test(NAME assert_trap COMMAND assert_trap_test)

  # BOG-9: a crash writes a report with C and Lua stacks, keeps the default action.
  add_executable(crash_handler_test tests/c/crash_handler.c src/bogcrash.c)
  target_include_directories(crash_handler_test PRIVATE src)
  target_link_libraries(crash_handler_test PRIVATE lua_vendor)
  add_test(NAME crash_handler COMMAND crash_handler_test)
endif()

# Sanitizers on boggart's own code and the C tests (BOG-10); the vendored
# interpreter and JSON lib too, so a misuse inside them is attributed.
boggart_apply_sanitizer(boggart boggart-studio auth_threads_test assert_trap_test crash_handler_test
                        termctl_smoke lua_vendor cjson_vendor luv_lua boggart_vt boggart_pty pty_transport_test studio_uvbridge_test termgrid_test termcache_test renderer_fonts_test renderer_clusters_test renderer_atlas_test vt_parser_test page_storage_test page_resize_test page_layout_test bitmap_test idmap_test idmap_scalar_test resize_failure_test
                        terminal_dispatch_test osc_commands_test terminal_events_test terminal_links_test mouse_encode_test terminal_mouse_test key_encode_test terminal_key_test paste_encode_test terminal_input_test boggart_unicode unicode_test wide_cells_test grapheme_cells_test terminal_unicode_test terminal_text_width_test)
