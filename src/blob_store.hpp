#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <unordered_set>

namespace clipd {

// Content-addressed store for blob payloads (image bytes), one file per blob
// named by its hex id. Identity is the id supplied by the caller (sha256-hex);
// the store never hashes — it only addresses by that id.
//
// Durability mirrors the log's compaction: a blob is written to a temp file,
// force-synced to stable storage, then atomically renamed into place, and the
// directory is fsync'd. Writes are content-addressed and write-once: putting an
// id that already exists is a no-op, which makes re-copying an identical image
// free.
//
// Crash ordering (enforced by Core, not here): Core writes the blob BEFORE
// appending the referencing log record, so a crash in between leaves an orphan
// blob (reclaimed by a later gc()) rather than a log record pointing at a
// missing blob. gc() runs only after a compacted log is durably in place.
//
// Not thread-safe: access is serialized by the caller.
class BlobStore {
 public:
  explicit BlobStore(std::filesystem::path dir);

  // Create the blob directory if missing.
  void open();

  // Store `len` bytes under `id`. No-op if `id` already exists (write-once).
  // Throws on an invalid id or an I/O failure.
  void put(const std::string& id, const uint8_t* data, size_t len);

  // True iff a blob for `id` exists. False for a malformed id.
  bool exists(const std::string& id) const;

  // The blob bytes for `id`, or nullopt if absent or `id` is malformed.
  std::optional<std::string> get(const std::string& id) const;

  // Delete every blob whose id is not in `live_ids` (and any stray temp files).
  void gc(const std::unordered_set<std::string>& live_ids);

 private:
  std::filesystem::path dir_;
};

}  // namespace clipd
