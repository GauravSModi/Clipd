/*
 * Pure-C client of the clipd C API. Compiled as C (not C++) and linked into the
 * C++ test binary, this proves two things the C++ tests can't on their own:
 * that clipd.h is valid C, and that the boundary is actually callable from a C
 * translation unit. The C++ suite invokes clipd_c_smoke() and asserts the
 * result, so this code also runs under ASan/UBSan.
 */

#include "clipd.h"

/*
 * Drive the whole API from C. Returns the number of matches for a known query,
 * or -1 on any failure.
 */
int clipd_c_smoke(const char* log_path) {
  ClipdCore* core;
  ClipdResults* results;
  int count;

  core = clipd_create(log_path, 100, (uint64_t)1 << 40, 0, 0);
  if (core == NULL) {
    return -1;
  }

  if (clipd_add(core, "alpha one", 1) != 0 ||
      clipd_add(core, "beta two", 2) != 0 ||
      clipd_add(core, "alpha three", 3) != 0) {
    clipd_destroy(core);
    return -1;
  }

  results = clipd_search(core, "alpha", 10, 100);
  if (results == NULL) {
    clipd_destroy(core);
    return -1;
  }

  count = (int)results->count;
  clipd_free_results(results);
  clipd_destroy(core);
  return count;
}
