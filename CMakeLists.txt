cmake_minimum_required(VERSION 3.20)
project(clipd LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Emit compile_commands.json so clangd sees real flags (C++20, includes, deps).
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

# --- Sanitizers -------------------------------------------------------------
# Configure with -DCLIPD_SANITIZE=address or -DCLIPD_SANITIZE=undefined.
# No threading in Phase 1, so TSan is deferred.
set(CLIPD_SANITIZE "" CACHE STRING "Sanitizer to enable: address | undefined")
set(CLIPD_SANITIZE_FLAGS "")
if(CLIPD_SANITIZE)
  set(CLIPD_SANITIZE_FLAGS -fsanitize=${CLIPD_SANITIZE} -fno-omit-frame-pointer -g)
  message(STATUS "Sanitizer enabled: ${CLIPD_SANITIZE}")
endif()

function(clipd_apply_sanitizer target)
  if(CLIPD_SANITIZE)
    target_compile_options(${target} PRIVATE ${CLIPD_SANITIZE_FLAGS})
    target_link_options(${target} PRIVATE ${CLIPD_SANITIZE_FLAGS})
  endif()
endfunction()

# --- Core library -----------------------------------------------------------
# Sources are added as each unit is built (TDD, one unit at a time).
add_library(clipd_core
  src/crc32.cpp
  src/clip_store.cpp
  src/fuzzy_matcher.cpp
  src/log.cpp
  src/core.cpp
)
target_include_directories(clipd_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/src)
target_compile_options(clipd_core PRIVATE -Wall -Wextra -Wpedantic)
clipd_apply_sanitizer(clipd_core)

# --- C API library ----------------------------------------------------------
# Flat extern "C" boundary (clipd.h) for the Swift shell. A thin adapter over
# clipd_core; PUBLIC-links it so consumers (tests, Swift) get the core and its
# src/ include dir transitively.
add_library(clipd_capi src/c_api.cpp)
target_link_libraries(clipd_capi PUBLIC clipd_core)
target_compile_options(clipd_capi PRIVATE -Wall -Wextra -Wpedantic)
clipd_apply_sanitizer(clipd_capi)

# --- CLI harness ------------------------------------------------------------
add_executable(clipd-cli cli/main.cpp)
target_link_libraries(clipd-cli PRIVATE clipd_core)
clipd_apply_sanitizer(clipd-cli)

# --- Benchmark --------------------------------------------------------------
add_executable(clipd_bench bench/bench_search.cpp)
target_link_libraries(clipd_bench PRIVATE clipd_core)

# --- Tests ------------------------------------------------------------------
enable_testing()
add_subdirectory(tests)
