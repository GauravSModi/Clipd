#pragma once

#include <cstddef>
#include <functional>
#include <list>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "entry.hpp"

namespace clipd {

// In-memory store of clipboard entries with recency ordering, deduplication,
// and bounded size with LRU eviction.
//
// This is the sole authority on what is "live". The backing store (a recency
// ordered list + a lookup map) lives entirely behind this narrow interface, so
// it can be swapped for a contiguous layout later without touching callers.
//
// Not thread-safe: all access is serialized by the caller (Phase 1 is
// single-threaded; the Swift shell will serialize on one dispatch queue).
class ClipStore {
 public:
  explicit ClipStore(size_t max_entries);

  // Insert a new entry, or dedup-bump an existing one with identical text
  // (updating its timestamp and moving it to most-recent). Eviction of the
  // least-recent entry occurs when size would exceed max_entries.
  void upsert(std::string text, int64_t timestamp);

  // Visit live entries most-recent-first.
  void for_each(const std::function<void(const Entry&)>& fn) const;

  // Snapshot of live entries in recency order (most-recent-first), for
  // compaction.
  std::vector<Entry> snapshot() const;

  size_t size() const;
  size_t max_entries() const { return max_entries_; }

 private:
  size_t max_entries_;
  std::list<Entry> entries_;  // front = most recent
  std::unordered_map<std::string, std::list<Entry>::iterator> index_;
};

}  // namespace clipd
