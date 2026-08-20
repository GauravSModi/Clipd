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
  evict();
}

std::list<Entry>::iterator ClipStore::least_recent_evictable() {
  // Walk from least-recent (back) toward most-recent, returning the first
  // unpinned entry. Stop before the most-recent (front): the just-inserted entry
  // is never evicted, even when it is the only unpinned candidate among pins.
  for (auto it = entries_.end(); it != entries_.begin();) {
    --it;
    if (it == entries_.begin()) break;
    if (!it->pinned) return it;
  }
  return entries_.end();
}

void ClipStore::set_limits(size_t max_entries, uint64_t max_bytes) {
  max_entries_ = max_entries;
  max_bytes_ = max_bytes;
  evict();  // apply the new caps now, not on the next upsert
}

void ClipStore::evict() {
  // Evict least-recent unpinned entries while either cap is exceeded. Pinned
  // entries and the most-recent insert are exempt, so a budget can be held above
  // the cap by pins / a single over-budget entry (documented, intentional).
  while ((max_entries_ > 0 && entries_.size() > max_entries_) ||
         (max_bytes_ > 0 && total_bytes_ > max_bytes_)) {
    auto victim = least_recent_evictable();
    if (victim == entries_.end()) break;  // nothing evictable
    total_bytes_ -= victim->byte_size;
    index_.erase(victim->id);
    entries_.erase(victim);
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

void ClipStore::set_pinned(const std::string& id, bool pinned) {
  if (auto it = index_.find(id); it != index_.end()) {
    it->second->pinned = pinned;  // no recency bump; eviction is upsert-only
  }
}

std::optional<bool> ClipStore::pinned_state(const std::string& id) const {
  if (auto it = index_.find(id); it != index_.end()) return it->second->pinned;
  return std::nullopt;
}

void ClipStore::remove(const std::string& id) {
  if (auto it = index_.find(id); it != index_.end()) {
    total_bytes_ -= it->second->byte_size;
    entries_.erase(it->second);
    index_.erase(it);
  }
}

void ClipStore::clear_unpinned() {
  for (auto it = entries_.begin(); it != entries_.end();) {
    if (it->pinned) {
      ++it;
      continue;
    }
    total_bytes_ -= it->byte_size;
    index_.erase(it->id);
    it = entries_.erase(it);
  }
}

}  // namespace clipd
