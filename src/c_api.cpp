#include "clipd.h"

#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "core.hpp"

// Opaque to C: a thin wrapper holding the C++ coordinator by value. Defined in
// this translation unit only, so the handle stays opaque across the ABI.
struct ClipdCore {
  clipd::Core core;
};

// Lifecycle ------------------------------------------------------------------

ClipdCore* clipd_create(const char* log_path, size_t max_entries,
                        uint64_t compact_threshold_bytes) {
  if (!log_path) return nullptr;
  try {
    std::unique_ptr<ClipdCore> handle(new ClipdCore{
        clipd::Core(log_path, max_entries, compact_threshold_bytes)});
    handle->core.start();  // may throw on I/O failure; unique_ptr cleans up
    return handle.release();
  } catch (...) {
    return nullptr;  // no exception crosses the extern "C" boundary
  }
}

void clipd_destroy(ClipdCore* core) { delete core; }  // delete nullptr is safe

// Ingest ---------------------------------------------------------------------

int clipd_add(ClipdCore* core, const char* text, int64_t timestamp_ms) {
  if (!core || !text) return -1;
  try {
    core->core.add(text, timestamp_ms);
    return 0;
  } catch (...) {
    return -1;
  }
}

// Search ---------------------------------------------------------------------

ClipdResults* clipd_search(ClipdCore* core, const char* query,
                           size_t max_results, int64_t now_ms) {
  if (!core || !query) return nullptr;
  try {
    const std::vector<clipd::ScoredEntry> hits =
        core->core.search(query, max_results, now_ms);

    // One contiguous block holds the header, the match array, and every string
    // byte, so the whole result set frees in a single free() — impossible to
    // leak half of it. Offsets come from sizeof(), keeping the ClipdMatch array
    // 8-aligned; only the trailing string bytes are sub-aligned, and they are
    // written and read as bytes.
    size_t bytes = sizeof(ClipdResults) + hits.size() * sizeof(ClipdMatch);
    for (const clipd::ScoredEntry& h : hits) bytes += h.entry.text.size() + 1;

    void* block = std::malloc(bytes);
    if (!block) return nullptr;

    auto* results = static_cast<ClipdResults*>(block);
    results->count = hits.size();
    results->matches = reinterpret_cast<ClipdMatch*>(static_cast<char*>(block) +
                                                     sizeof(ClipdResults));

    char* str = reinterpret_cast<char*>(results->matches) +
                hits.size() * sizeof(ClipdMatch);
    for (size_t i = 0; i < hits.size(); ++i) {
      const std::string& text = hits[i].entry.text;
      std::memcpy(str, text.data(), text.size());
      str[text.size()] = '\0';
      results->matches[i].text = str;
      results->matches[i].timestamp = hits[i].entry.timestamp;
      results->matches[i].score = hits[i].score;
      str += text.size() + 1;
    }
    return results;
  } catch (...) {
    return nullptr;
  }
}

void clipd_free_results(ClipdResults* results) {
  std::free(results);  // single free of the whole block; free(NULL) is safe
}

// Maintenance ----------------------------------------------------------------

int clipd_compact(ClipdCore* core) {
  if (!core) return -1;
  try {
    core->core.compact();
    return 0;
  } catch (...) {
    return -1;
  }
}

int clipd_stats(ClipdCore* core, ClipdStats* out) {
  if (!core || !out) return -1;
  try {
    const clipd::Stats s = core->core.stats();
    out->entry_count = s.entry_count;
    out->log_bytes = s.log_bytes;
    return 0;
  } catch (...) {
    return -1;
  }
}
