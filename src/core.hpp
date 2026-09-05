#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "blob_store.hpp"
#include "clip_store.hpp"
#include "entry.hpp"
#include "log.hpp"

namespace clipd {

struct ScoredEntry {
  Entry entry;
  float score;
};

struct Stats {
  size_t entry_count;
  uint64_t log_bytes;
  uint64_t store_bytes;  // summed Entry::byte_size of the live set (eviction usage)
};

// Coordinator: ties together the in-memory store, the persistent log, the blob
// store, and the fuzzy matcher. It orchestrates only — dedup lives in ClipStore,
// scoring in fuzzy, durability in Log/BlobStore. Core owns identity derivation
// and the blob-vs-record crash ordering, but adds no other policy of its own.
class Core {
 public:
  // `max_entries` caps the live count; `max_bytes` caps the summed byte_size of
  // the live set (0 = unbounded); `max_blob_bytes` rejects a single image larger
  // than the cap (0 = no per-image limit); `compact_threshold_bytes` is the log
  // size above which start() compacts.
  Core(std::filesystem::path log_path, size_t max_entries,
       uint64_t compact_threshold_bytes, uint64_t max_bytes = 0,
       uint64_t max_blob_bytes = 0);

  // Open the log and blob store, replay to rebuild the store (skipping any image
  // whose blob is missing), then migrate a legacy log or compact past threshold.
  void start();

  // Record a new text copy: dedup-bump in the store, append to the log.
  void add(std::string text, int64_t timestamp);

  // Record an image copy. Writes the blob first (content-addressed, durable),
  // then the referencing log record, then the store entry. A no-op if the image
  // exceeds max_blob_bytes.
  void add_image(const uint8_t* data, size_t len, uint32_t width, uint32_t height,
                 ImageFormat format, int64_t timestamp);

  // Record a file copy by reference (its path), never by copying contents.
  void add_file(std::string path, int64_t timestamp);

  // Pin/unpin the live entry with `id` (a 64-char hex id from a search match).
  // Idempotent: a no-op (no log record) if absent or already in that state.
  // Persisted via a PIN/UNPIN record applied in replay order.
  void set_pinned(const std::string& id, bool pinned);

  // Delete the live entry with `id`. Persisted via a TOMBSTONE record; replay
  // drops it; compaction discards both the tombstone and the dead record. An
  // image's blob is left orphaned and reclaimed by the next compaction's GC.
  void remove(const std::string& id);

  // Clear history, keeping pinned entries: append a CLEAR record (durable for
  // the crash window), drop the unpinned live set, then compact to a pinned-only
  // log and GC every now-unreferenced blob.
  void clear();

  // Delete every live entry stamped strictly BEFORE `cutoff_ms`, keeping pinned
  // entries — the same exemption clear() and eviction use. Returns how many were
  // removed. Each victim gets a TOMBSTONE record appended before it leaves the
  // store (remove()'s ordering), so a crash mid-sweep leaves a consistent log
  // either way; when anything was removed the log is then compacted, so expired
  // records leave the file instead of waiting on compact_threshold_bytes_.
  //
  // This is a removal path, not an eviction path: ClipStore is untouched and
  // gains no timestamp-aware operation, so upsert and set_limits remain its only
  // two eviction triggers.
  size_t delete_older_than(int64_t cutoff_ms);

  // Replace the live caps and evict down to them at once. `max_entries` 0 = no
  // count cap, `max_bytes` 0 = unbounded. Eviction authority stays in ClipStore;
  // this only forwards. The log is untouched — evicted records are dropped by
  // the next compaction, not here. `max_blob_bytes` is deliberately NOT settable:
  // it is an ingest-side reject rule, so lowering it could not retroactively
  // remove an image already stored.
  void set_limits(size_t max_entries, uint64_t max_bytes);

  // The bytes of the blob with id `id`, or nullopt if absent.
  std::optional<std::string> read_blob(const std::string& id) const;

  // Top `max_results` entries matching `query`, best-first. `now` (epoch ms) sets
  // the reference point for recency weighting.
  std::vector<ScoredEntry> search(std::string_view query, size_t max_results,
                                  int64_t now) const;

  // Rewrite the log to exactly the live set, then GC blobs no longer referenced.
  void compact();

  Stats stats() const;

 private:
  ClipStore store_;
  Log log_;
  BlobStore blobs_;
  uint64_t compact_threshold_bytes_;
  uint64_t max_blob_bytes_;
};

}  // namespace clipd
