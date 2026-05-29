#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <list>
#include <string>
#include <unordered_map>
#include <vector>

#include "entry.hpp"

namespace clipd {

// In-memory store of clipboard entries with recency ordering, deduplication by
// stable id, and bounded size with LRU eviction under both a count cap and a
// byte budget.
//
// This is the sole authority on what is "live". It stays purely in-memory: it
// holds no concept of blobs or files on disk — evicting an image entry only drops
// it from memory; reclaiming the backing blob is the Core's job at compaction.
// The backing store (a recency-ordered list + an id->iterator map) lives entirely
// behind this narrow interface, so it can be swapped for a contiguous layout
// later without touching callers.
//
// Not thread-safe: all access is serialized by the caller (the Swift shell
// serializes on one dispatch queue).
class ClipStore {
 public:
  // `max_entries` caps the live count (0 = no count cap). `max_bytes` caps the
  // summed Entry::byte_size of the live set (0 = no byte cap). A single entry
  // larger than the whole byte budget is still kept — the most-recent entry is
  // never evicted away (per-image size limiting is an ingest-side concern).
  explicit ClipStore(size_t max_entries, uint64_t max_bytes = 0);

  // Insert `e`, or dedup-bump an existing entry with the same id (updating its
  // timestamp and moving it to most-recent). Then evict least-recent entries
  // until both the count and byte caps hold.
  void upsert(Entry e);

  // Visit live entries most-recent-first.
  void for_each(const std::function<void(const Entry&)>& fn) const;

  // Snapshot of live entries in recency order (most-recent-first), for compaction.
  std::vector<Entry> snapshot() const;

  size_t size() const;
  size_t max_entries() const { return max_entries_; }
  uint64_t max_bytes() const { return max_bytes_; }
  uint64_t total_bytes() const { return total_bytes_; }

 private:
  size_t max_entries_;
  uint64_t max_bytes_;
  uint64_t total_bytes_ = 0;
  std::list<Entry> entries_;  // front = most recent
  std::unordered_map<std::string, std::list<Entry>::iterator> index_;  // by id
};

}  // namespace clipd
