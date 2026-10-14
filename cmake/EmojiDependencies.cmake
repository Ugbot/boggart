# PNG-backed sbix/CBDT emoji strikes. Keep both decoders static and pinned;
# never fall through to a machine's package-manager libraries.
set(SKIP_INSTALL_ALL ON CACHE BOOL "" FORCE)
set(ZLIB_BUILD_SHARED OFF CACHE BOOL "" FORCE)
set(ZLIB_BUILD_STATIC ON CACHE BOOL "" FORCE)
set(ZLIB_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(ZLIB_INSTALL OFF CACHE BOOL "" FORCE)
FetchContent_Declare(zlib
  URL https://zlib.net/zlib-1.3.2.tar.gz
  URL_HASH SHA256=bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(zlib)
add_library(ZLIB::ZLIB ALIAS zlibstatic)
set(ZLIB_LIBRARY zlibstatic)
set(ZLIB_LIBRARY_RELEASE zlibstatic)
set(ZLIB_INCLUDE_DIR ${zlib_SOURCE_DIR})

set(PNG_SHARED OFF CACHE BOOL "" FORCE)
set(PNG_FRAMEWORK OFF CACHE BOOL "" FORCE)
set(PNG_STATIC ON CACHE BOOL "" FORCE)
set(PNG_TESTS OFF CACHE BOOL "" FORCE)
set(PNG_TOOLS OFF CACHE BOOL "" FORCE)
set(PNG_INSTALL OFF CACHE BOOL "" FORCE)
FetchContent_Declare(libpng
  URL https://download.sourceforge.net/libpng/libpng-1.6.59.tar.xz
  URL_HASH SHA256=d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(libpng)
add_library(PNG::PNG ALIAS png_static)
set(PNG_LIBRARY png_static)
set(PNG_PNG_INCLUDE_DIR ${libpng_SOURCE_DIR})
set(FT_DISABLE_PNG OFF CACHE BOOL "" FORCE)
set(FT_REQUIRE_PNG ON CACHE BOOL "" FORCE)
set(FT_DISABLE_ZLIB OFF CACHE BOOL "" FORCE)
set(FT_REQUIRE_ZLIB ON CACHE BOOL "" FORCE)
