cmake_minimum_required(VERSION 3.22)
if(POLICY CMP0135)
  cmake_policy(SET CMP0135 NEW)
endif()
project(soundq_opus_decoder VERSION 0.1.0 LANGUAGES C)
include(FetchContent)

# All dependencies are source-built for CMAKE_SYSTEM_NAME; never find host libs.
set(SQ_OPUS_ARCHIVE_DIR "" CACHE PATH "Optional directory of SHA-256-pinned upstream tar.gz archives")
option(SQ_OPUS_BUILD_SMOKE "Build the standalone native fixture smoke executable" OFF)
option(SQ_OPUS_BUILD_SHARED "Build the optional standalone decoder shared library" ON)
option(SQ_OPUS_SANITIZE "Instrument decoder and upstream dependencies with ASan/UBSan" OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_VISIBILITY_PRESET hidden)
if(SQ_OPUS_SANITIZE)
  add_compile_options(-fsanitize=address,undefined -fno-omit-frame-pointer)
  add_link_options(-fsanitize=address,undefined)
  # Apple's ASan compiler predefines _FORTIFY_SOURCE=0; don't redefine via Opus.
  set(OPUS_FORTIFY_SOURCE OFF CACHE BOOL "" FORCE)
endif()
# Directory-local overrides: never rewrite the embedding project's cache.
set(BUILD_SHARED_LIBS OFF)
set(BUILD_TESTING OFF)
# libogg declares CMake 3.6 and resets policies; make its option() respect the
# directory-local override even when the embedding cache says shared=ON.
set(CMAKE_POLICY_DEFAULT_CMP0077 NEW)
set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_DRED OFF CACHE BOOL "" FORCE)
set(OPUS_OSCE OFF CACHE BOOL "" FORCE)
# Portable baseline: upstream 1.6.1 CMake's ARM NEON presume-only path fails
# to declare celt_inner_prod_neon; MAY_HAVE emits unsupported Apple RTCD error.
# Use upstream's supported scalar build rather than patch pinned sources.
set(OPUS_DISABLE_INTRINSICS ON CACHE BOOL "" FORCE)
set(INSTALL_DOCS OFF CACHE BOOL "" FORCE)
set(INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(INSTALL_CMAKE_PACKAGE_MODULE OFF CACHE BOOL "" FORCE)

function(sq_pinned_source name archive category digest)
  if(SQ_OPUS_ARCHIVE_DIR)
    set(url "${SQ_OPUS_ARCHIVE_DIR}/${archive}")
  else()
    set(url "https://downloads.xiph.org/releases/${category}/${archive}"
            "https://ftp.osuosl.org/pub/xiph/releases/${category}/${archive}")
  endif()
  FetchContent_Declare(${name} URL ${url} URL_HASH SHA256=${digest})
endfunction()
sq_pinned_source(sq_ogg libogg-1.3.6.tar.gz ogg 83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638)
sq_pinned_source(sq_opus opus-1.6.1.tar.gz opus 6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1)
sq_pinned_source(sq_opusfile opusfile-0.12.tar.gz opus 118d8601c12dd6a44f52423e68ca9083cc9f2bfe72da7a8c1acb22a80ae3550b)
FetchContent_MakeAvailable(sq_ogg sq_opus sq_opusfile)

# opusfile 0.12 has no CMake build: this exact list is Makefile.am:11-15.
# Deliberately omit libopusurl, http.c, TLS, examples, and network support.
add_library(sq_opusfile STATIC
  ${sq_opusfile_SOURCE_DIR}/src/info.c
  ${sq_opusfile_SOURCE_DIR}/src/internal.c
  ${sq_opusfile_SOURCE_DIR}/src/opusfile.c
  ${sq_opusfile_SOURCE_DIR}/src/stream.c)
target_include_directories(sq_opusfile PUBLIC ${sq_opusfile_SOURCE_DIR}/include)
# Upstream 0.12 short-forward-seek optimization sets cur_discard_count but
# buffered op_read_native returns before applying it. The shipped small-footprint
# mode disables that optimization (and no public API); use full upstream seeks.
target_compile_definitions(sq_opusfile PRIVATE OP_SMALL_FOOTPRINT)
target_link_libraries(sq_opusfile PUBLIC opus ogg m)

add_library(sq_opus_decoder STATIC src/sq_opus_decoder.c)
target_include_directories(sq_opus_decoder PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(sq_opus_decoder PRIVATE sq_opusfile)
target_compile_features(sq_opus_decoder PRIVATE c_std_11)
target_compile_options(sq_opus_decoder PRIVATE -Wall -Wextra -Wpedantic -Werror)
# Standalone artifact for tests and optional direct loading; static target is for
# the parent's existing host library (no separate playback/renderer owner).
if(SQ_OPUS_BUILD_SHARED)
add_library(sq_opus_decoder_shared SHARED src/sq_opus_decoder.c)
set_target_properties(sq_opus_decoder_shared PROPERTIES OUTPUT_NAME sq_opus_decoder)
target_include_directories(sq_opus_decoder_shared PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(sq_opus_decoder_shared PRIVATE sq_opusfile)
target_compile_features(sq_opus_decoder_shared PRIVATE c_std_11)
target_compile_options(sq_opus_decoder_shared PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()
if(SQ_OPUS_BUILD_SMOKE)
  add_executable(sq_opus_smoke tests/smoke.c)
  target_link_libraries(sq_opus_smoke PRIVATE sq_opus_decoder)
  target_compile_options(sq_opus_smoke PRIVATE -UNDEBUG)
  add_executable(sq_opus_bounded tests/bounded.c)
  target_link_libraries(sq_opus_bounded PRIVATE sq_opus_decoder)
  target_compile_options(sq_opus_bounded PRIVATE -UNDEBUG)
endif()
