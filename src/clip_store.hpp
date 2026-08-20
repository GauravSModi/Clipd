#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <list>
#include <optional>
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

  // Set the pinned flag of the entry with `id` (no-op if absent). Idempotent;
  // does not bump recency. A pinned entry is exempt from eviction. Eviction is
  // never triggered here — only upsert and set_limits evict — so replay, which
  // calls neither set_pinned's evict nor set_limits, stays faithful.
  void set_pinned(const std::string& id, bool pinned);

  // Replace both caps and evict down to them AT ONCE, rather than waiting for
  // the next upsert: a cap the user just lowered must take effect now. Same
  // zero semantics as the constructor (`max_entries` 0 = no count cap,
  // `max_bytes` 0 = no byte cap), and the same exemptions — pinned entries and
  // the most-recent entry are never evicted, so a cap can be held above its
  // limit here exactly as it can after an upsert.
  //
  // This is the second eviction trigger. Replay stays faithful because replay
  // never calls it: recovery constructs the store with the already-current caps
  // and drives every record through upsert().
  void set_limits(size_t max_entries, uint64_t max_bytes);

  // The pinned flag of the entry with `id`, or nullopt if there is no such
  // entry. Lets the caller skip redundant writes for an idempotent set.
  std::optional<bool> pinned_state(const std::string& id) const;

  // Remove the entry with `id` (no-op if absent). Frees its byte cost; never
  // touches blobs (blob reclamation is the Core's job at compaction).
  void remove(const std::string& id);

  // Remove every unpinned entry, keeping pinned ones (clear-history semantics).
  void clear_unpinned();

  // Visit live entries most-recent-first.
  void for_each(const std::function<void(const Entry&)>& fn) const;

  // Snapshot of live entries in recency order (most-recent-first), for compaction.
  std::vector<Entry> snapshot() const;

  size_t size() const;
  size_t max_entries() const { return max_entries_; }
  uint64_t max_bytes() const { return max_bytes_; }
  uint64_t total_bytes() const { return total_bytes_; }

 private:
  // Evict least-recent unpinned entries until both caps hold or nothing is
  // evictable. Called from upsert and from set_limits — and from nowhere else,
  // so replay (which only upserts) reproduces eviction exactly.
  void evict();
  // The least-recent (back-most) unpinned entry that is not the most-recent
  // (front) one, or end() if none — pinned entries and the most-recent insert
  // are never evicted.
  std::list<Entry>::iterator least_recent_evictable();

  size_t max_entries_;
  uint64_t max_bytes_;
  uint64_t total_bytes_ = 0;
  std::list<Entry> entries_;  // front = most recent
  std::unordered_map<std::string, std::list<Entry>::iterator> index_;  // by id
};

}  // namespace clipd
