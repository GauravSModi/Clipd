#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

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
};

// Coordinator: ties together the in-memory store, the persistent log, and the
// fuzzy matcher. It orchestrates only — dedup lives in ClipStore, scoring in
// fuzzy, durability in Log. Core adds no policy of its own beyond wiring.
class Core {
 public:
  Core(std::filesystem::path log_path, size_t max_entries,
       uint64_t compact_threshold_bytes);

  // Open the log, replay it to rebuild the store (chronological upsert, which
  // reproduces eviction without resurrecting evicted entries), then compact if
  // the log has grown past the threshold.
  void start();

  // Record a new copy: dedup-bump in the store, append to the log.
  void add(std::string text, int64_t timestamp);

  // Top `max_results` entries matching `query`, best-first. `now` (epoch ms)
  // sets the reference point for recency weighting.
  std::vector<ScoredEntry> search(std::string_view query, size_t max_results,
                                  int64_t now) const;

  // Rewrite the log to exactly the live set, discarding superseded/evicted
  // records permanently.
  void compact();

  Stats stats() const;

 private:
  ClipStore store_;
  Log log_;
  uint64_t compact_threshold_bytes_;
};

}  // namespace clipd
