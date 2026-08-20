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

namespace {

ClipdKind to_c_kind(clipd::Kind kind) {
  switch (kind) {
    case clipd::Kind::Image:
      return CLIPD_IMAGE;
    case clipd::Kind::File:
      return CLIPD_FILE;
    case clipd::Kind::Text:
    default:
      return CLIPD_TEXT;
  }
}

}  // namespace

// Lifecycle ------------------------------------------------------------------

ClipdCore* clipd_create(const char* log_path, size_t max_entries,
                        uint64_t compact_threshold_bytes, uint64_t max_bytes,
                        uint64_t max_blob_bytes) {
  if (!log_path) return nullptr;
  try {
    std::unique_ptr<ClipdCore> handle(new ClipdCore{
        clipd::Core(log_path, max_entries, compact_threshold_bytes, max_bytes,
                    max_blob_bytes)});
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

int clipd_add_image(ClipdCore* core, const uint8_t* data, size_t len,
                    uint32_t width, uint32_t height, int image_format,
                    int64_t timestamp_ms) {
  if (!core || !data) return -1;
  try {
    core->core.add_image(data, len, width, height,
                         static_cast<clipd::ImageFormat>(image_format),
                         timestamp_ms);
    return 0;
  } catch (...) {
    return -1;
  }
}

int clipd_add_file(ClipdCore* core, const char* path, int64_t timestamp_ms) {
  if (!core || !path) return -1;
  try {
    core->core.add_file(path, timestamp_ms);
    return 0;
  } catch (...) {
    return -1;
  }
}

int clipd_set_pinned(ClipdCore* core, const char* id, int pinned) {
  if (!core || !id) return -1;
  try {
    core->core.set_pinned(id, pinned != 0);
    return 0;
  } catch (...) {
    return -1;
  }
}

int clipd_delete(ClipdCore* core, const char* id) {
  if (!core || !id) return -1;
  try {
    core->core.remove(id);
    return 0;
  } catch (...) {
    return -1;
  }
}

int clipd_clear(ClipdCore* core) {
  if (!core) return -1;
  try {
    core->core.clear();
    return 0;
  } catch (...) {
    return -1;
  }
}

int clipd_set_limits(ClipdCore* core, size_t max_entries, uint64_t max_bytes) {
  if (!core) return -1;
  try {
    core->core.set_limits(max_entries, max_bytes);
    return 0;
  } catch (...) {
    return -1;
  }
}

const uint8_t* clipd_read_blob(ClipdCore* core, const char* id, size_t* out_len) {
  if (!core || !id || !out_len) return nullptr;
  try {
    std::optional<std::string> bytes = core->core.read_blob(id);
    if (!bytes) return nullptr;
    size_t n = bytes->size();
    void* buf = std::malloc(n ? n : 1);  // malloc(0) is impl-defined; round up
    if (!buf) return nullptr;
    std::memcpy(buf, bytes->data(), n);
    *out_len = n;
    return static_cast<const uint8_t*>(buf);
  } catch (...) {
    return nullptr;
  }
}

void clipd_free_blob(const uint8_t* blob) {
  std::free(const_cast<uint8_t*>(blob));  // free(NULL) is safe
}

// Search ---------------------------------------------------------------------

ClipdResults* clipd_search(ClipdCore* core, const char* query,
                           size_t max_results, int64_t now_ms) {
  if (!core || !query) return nullptr;
  try {
    const std::vector<clipd::ScoredEntry> hits =
        core->core.search(query, max_results, now_ms);

    // One contiguous block holds the header, the match array, and every string
    // byte (each match's `text` and `id`), so the whole result set frees in a
    // single free() — impossible to leak half of it. Offsets come from sizeof(),
    // keeping the ClipdMatch array 8-aligned; only the trailing string bytes are
    // sub-aligned, and they are written and read as bytes.
    size_t bytes = sizeof(ClipdResults) + hits.size() * sizeof(ClipdMatch);
    for (const clipd::ScoredEntry& h : hits)
      bytes += h.entry.text.size() + 1 + h.entry.id.size() + 1;

    void* block = std::malloc(bytes);
    if (!block) return nullptr;

    auto* results = static_cast<ClipdResults*>(block);
    results->count = hits.size();
    results->matches = reinterpret_cast<ClipdMatch*>(static_cast<char*>(block) +
                                                     sizeof(ClipdResults));

    char* str = reinterpret_cast<char*>(results->matches) +
                hits.size() * sizeof(ClipdMatch);
    for (size_t i = 0; i < hits.size(); ++i) {
      const clipd::Entry& e = hits[i].entry;

      std::memcpy(str, e.text.data(), e.text.size());
      str[e.text.size()] = '\0';
      results->matches[i].text = str;
      str += e.text.size() + 1;

      std::memcpy(str, e.id.data(), e.id.size());
      str[e.id.size()] = '\0';
      results->matches[i].id = str;
      str += e.id.size() + 1;

      results->matches[i].timestamp = e.timestamp;
      results->matches[i].byte_size = e.byte_size;
      results->matches[i].score = hits[i].score;
      results->matches[i].kind = to_c_kind(e.kind);
      results->matches[i].width = e.width;
      results->matches[i].height = e.height;
      results->matches[i].pinned = e.pinned ? 1 : 0;
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
    out->store_bytes = s.store_bytes;
    return 0;
  } catch (...) {
    return -1;
  }
}
