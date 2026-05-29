include(FetchContent)
FetchContent_Declare(
  googletest
  GIT_REPOSITORY https://github.com/google/googletest.git
  GIT_TAG v1.15.2
)
# Don't override parent project's compiler/linker settings on Windows (no-op here).
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)

# Test sources are added as each unit is built (TDD, one unit at a time).
add_executable(clipd_tests
  test_crc32.cpp
  test_sha256.cpp
  test_identity.cpp
  test_blob_store.cpp
  test_clip_store.cpp
  test_fuzzy_matcher.cpp
  test_log.cpp
  test_core.cpp
  test_c_api.cpp
  c_smoke.c
)
# clipd_capi PUBLIC-links clipd_core, so linking it alone pulls in the core and
# its include dir for the unit tests that exercise the C++ layer directly.
target_link_libraries(clipd_tests PRIVATE clipd_capi GTest::gtest_main)
clipd_apply_sanitizer(clipd_tests)

include(GoogleTest)
gtest_discover_tests(clipd_tests)
