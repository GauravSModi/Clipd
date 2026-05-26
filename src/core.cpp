#include "core.hpp"

#include <algorithm>

#include "fuzzy_matcher.hpp"

namespace clipd {
namespace {

// Map an entry's age into a recency factor in (0, 1], 1 == most recent.
// Monotonic in age; the exact half-life only affects how strongly recency
// tilts ranking, not ordering.
constexpr float kRecencyHalfLifeMs = 3600000.0f;  // 1 hour

float recency_factor(int64_t timestamp, int64_t now) {
  float age = static_cast<float>(now - timestamp);
  if (age < 0.0f) age = 0.0f;
  return 1.0f / (1.0f + age / kRecencyHalfLifeMs);
}

}  // namespace

Core::Core(std::filesystem::path log_path, size_t max_entries,
           uint64_t compact_threshold_bytes)
    : store_(max_entries),
      log_(std::move(log_path)),
      compact_threshold_bytes_(compact_threshold_bytes) {}

void Core::start() {
  log_.open();
  // Chronological replay: re-applying upsert in file order reproduces the live
  // set (including eviction) without resurrecting evicted entries.
  log_.replay([this](const Entry& e) { store_.upsert(e.text, e.timestamp); });
  if (log_.size_bytes() > compact_threshold_bytes_) {
    compact();
  }
}

void Core::add(std::string text, int64_t timestamp) {
  // Durable first: append before mutating the store, so a failed write throws
  // and leaves the store untouched (memory and disk never disagree mid-session).
  log_.append(Entry{text, timestamp});
  store_.upsert(std::move(text), timestamp);  // dedup policy lives in the store
}

std::vector<ScoredEntry> Core::search(std::string_view query, size_t max_results,
                                      int64_t now) const {
  std::vector<ScoredEntry> matches;
  store_.for_each([&](const Entry& e) {
    if (auto s = fuzzy::score(query, e.text, recency_factor(e.timestamp, now))) {
      matches.push_back(ScoredEntry{e, *s});
    }
  });

  // Best-first; stable_sort preserves store order (most-recent-first) on ties.
  std::stable_sort(matches.begin(), matches.end(),
                   [](const ScoredEntry& a, const ScoredEntry& b) {
                     return a.score > b.score;
                   });
  if (matches.size() > max_results) {
    matches.resize(max_results);
  }
  return matches;
}

void Core::compact() {
  // snapshot() is most-recent-first; the log replays in file order, so write it
  // oldest-first to preserve recency on the next replay.
  std::vector<Entry> live = store_.snapshot();
  std::reverse(live.begin(), live.end());
  log_.compact(live);
}

Stats Core::stats() const {
  return Stats{store_.size(), log_.size_bytes()};
}

}  // namespace clipd
