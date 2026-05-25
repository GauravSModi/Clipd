#include "clip_store.hpp"

#include <utility>

namespace clipd {

ClipStore::ClipStore(size_t max_entries) : max_entries_(max_entries) {}

void ClipStore::upsert(std::string text, int64_t timestamp) {
  if (auto it = index_.find(text); it != index_.end()) {
    // Existing entry: update timestamp and move to most-recent (front).
    it->second->timestamp = timestamp;
    entries_.splice(entries_.begin(), entries_, it->second);
    return;
  }

  // New entry at the front.
  entries_.push_front(Entry{std::move(text), timestamp});
  index_.emplace(entries_.front().text, entries_.begin());

  // Evict least-recent (back) while over capacity.
  while (max_entries_ > 0 && entries_.size() > max_entries_) {
    index_.erase(entries_.back().text);
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
