#include "clip_store.hpp"

#include <utility>

namespace clipd {

ClipStore::ClipStore(size_t max_entries, uint64_t max_bytes)
    : max_entries_(max_entries), max_bytes_(max_bytes) {}

void ClipStore::upsert(Entry e) {
  if (auto it = index_.find(e.id); it != index_.end()) {
    // Existing entry (same id == same content): bump timestamp and move to most-
    // recent. Size is unchanged, so total_bytes_ stays correct.
    it->second->timestamp = e.timestamp;
    entries_.splice(entries_.begin(), entries_, it->second);
    return;
  }

  // New entry at the front.
  total_bytes_ += e.byte_size;
  entries_.push_front(std::move(e));
  index_.emplace(entries_.front().id, entries_.begin());

  // Evict least-recent (back) while either cap is exceeded. The byte cap never
  // evicts the last remaining entry: the most-recent insert is always kept, so a
  // single over-budget entry survives (per-entry size limiting is upstream).
  while ((max_entries_ > 0 && entries_.size() > max_entries_) ||
         (max_bytes_ > 0 && total_bytes_ > max_bytes_ && entries_.size() > 1)) {
    total_bytes_ -= entries_.back().byte_size;
    index_.erase(entries_.back().id);
    entries_.pop_back();
  }
}

void ClipStore::for_each(const std::function<void(const Entry&)>& fn) const {
  for (const Entry& e : entries_) {
    fn(e);
  }
}

std::vector<Entry> ClipStore::snapshot() const {
  return std::vector<Entry>(entries_.begin(), entries_.end());
}

size_t ClipStore::size() const { return entries_.size(); }

}  // namespace clipd
