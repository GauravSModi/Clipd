#include "core.hpp"

#include <algorithm>
#include <unordered_set>

#include "fuzzy_matcher.hpp"
#include "identity.hpp"
#include "sha256.hpp"

namespace clipd {
namespace {

// Map an entry's age into a recency factor in (0, 1], 1 == most recent.
// Monotonic in age; the exact half-life only affects how strongly recency tilts
// ranking, not ordering.
constexpr float kRecencyHalfLifeMs = 3600000.0f;  // 1 hour

float recency_factor(int64_t timestamp, int64_t now) {
  float age = static_cast<float>(now - timestamp);
  if (age < 0.0f) age = 0.0f;
  return 1.0f / (1.0f + age / kRecencyHalfLifeMs);
}

std::filesystem::path blob_dir_for(const std::filesystem::path& log_path) {
  std::filesystem::path dir = log_path;
  dir += ".blobs";
  return dir;
}

// The single source for an image's searchable/display label, used by both
// add_image and replay so a regenerated label can never drift. The label is
// derived from metadata, never stored in the log record.
std::string image_label(uint32_t width, uint32_t height, ImageFormat format) {
  const char* fmt = (format == ImageFormat::Tiff) ? "tiff" : "png";
  if (width > 0 && height > 0) {
    return "image " + std::to_string(width) + "x" + std::to_string(height) + " " +
           fmt;
  }
  return std::string("image ") + fmt;
}

}  // namespace

Core::Core(std::filesystem::path log_path, size_t max_entries,
           uint64_t compact_threshold_bytes, uint64_t max_bytes,
           uint64_t max_blob_bytes)
    : store_(max_entries, max_bytes),
      log_(log_path),
      blobs_(blob_dir_for(log_path)),
      compact_threshold_bytes_(compact_threshold_bytes),
      max_blob_bytes_(max_blob_bytes) {}

void Core::start() {
  log_.open();
  blobs_.open();
  const bool legacy = log_.is_legacy();

  // Chronological replay reproduces the live set (including eviction) without
  // resurrecting evicted entries. The log carries kind + on-disk fields; derive
  // id/label here (the single identity/label source). An image whose backing
  // blob is gone is skipped — that one entry only, not a torn-tail truncation.
  log_.replay([this](const Entry& e) {
    Entry entry = e;
    switch (entry.kind) {
      case Kind::Text:
        entry.id = content_id(Kind::Text, entry.text);
        entry.byte_size = entry.text.size();
        break;
      case Kind::File:
        entry.id = content_id(Kind::File, entry.text);
        entry.byte_size = entry.text.size();
        break;
      case Kind::Image:
        if (!blobs_.exists(entry.id)) return;  // missing blob: skip this entry
        entry.text = image_label(entry.width, entry.height, entry.image_format);
        break;
    }
    store_.upsert(std::move(entry));
  },
  // Control records apply in the SAME file order as content records, so the
  // live set is re-derived chronologically (a PIN takes effect before the later
  // adds that would otherwise evict the pinned entry).
  [this](ControlOp op, const std::string& id) {
    switch (op) {
      case ControlOp::Pin:       store_.set_pinned(id, true);  break;
      case ControlOp::Unpin:     store_.set_pinned(id, false); break;
      case ControlOp::Tombstone: store_.remove(id);            break;
      case ControlOp::Clear:     store_.clear_unpinned();      break;
    }
  });

  // A pre-feature (header-less) log is migrated to v1 by rewriting it; otherwise
  // compact only when the log has grown past the threshold.
  if (legacy) {
    compact();
  } else if (log_.size_bytes() > compact_threshold_bytes_) {
    compact();
  }
}

void Core::add(std::string text, int64_t timestamp) {
  Entry e;
  e.kind = Kind::Text;
  e.id = content_id(Kind::Text, text);
  e.byte_size = text.size();
  e.timestamp = timestamp;
  e.text = std::move(text);
  // Durable first: append before mutating the store, so a failed write throws
  // and leaves the store untouched (memory and disk never disagree mid-session).
  log_.append(e);
  store_.upsert(std::move(e));  // dedup policy lives in the store
}

void Core::add_image(const uint8_t* data, size_t len, uint32_t width,
                     uint32_t height, ImageFormat format, int64_t timestamp) {
  // Per-image cap: keep one giant image from dominating the whole byte budget.
  if (max_blob_bytes_ > 0 && len > max_blob_bytes_) return;

  const std::string id = to_hex(content_digest(Kind::Image, data, len));

  // Blob FIRST: a crash between here and the append leaves an orphan blob
  // (reclaimed later), never a record pointing at a missing blob.
  blobs_.put(id, data, len);

  Entry e;
  e.kind = Kind::Image;
  e.id = id;
  e.timestamp = timestamp;
  e.byte_size = len;
  e.width = width;
  e.height = height;
  e.image_format = format;
  e.text = image_label(width, height, format);
  log_.append(e);  // then the referencing record
  store_.upsert(std::move(e));
}

void Core::add_file(std::string path, int64_t timestamp) {
  Entry e;
  e.kind = Kind::File;
  e.id = content_id(Kind::File, path);
  e.byte_size = path.size();
  e.timestamp = timestamp;
  e.text = std::move(path);  // for File, text is the path
  log_.append(e);
  store_.upsert(std::move(e));
}

void Core::set_pinned(const std::string& id, bool pinned) {
  auto state = store_.pinned_state(id);
  if (!state || *state == pinned) return;  // absent or already set: no log noise
  // Durable first: the PIN/UNPIN record before the store mutation.
  log_.append_control(pinned ? ControlOp::Pin : ControlOp::Unpin, id);
  store_.set_pinned(id, pinned);
}

void Core::remove(const std::string& id) {
  if (!store_.pinned_state(id)) return;  // not live: nothing to tombstone
  log_.append_control(ControlOp::Tombstone, id);
  store_.remove(id);
  // An image's blob is intentionally left orphaned here; the next compact()'s
  // GC reclaims it (the existing "GC at compaction, post-rename" rule).
}

void Core::clear() {
  // A durable CLEAR marker first, so a crash before compaction still recovers
  // the cleared (pinned-only) state on replay.
  log_.append_control(ControlOp::Clear);
  store_.clear_unpinned();
  // Then rewrite the log to the pinned-only live set and GC every unreferenced
  // blob (compaction's existing blob GC reclaims the cleared images' blobs).
  compact();
}

std::optional<std::string> Core::read_blob(const std::string& id) const {
  return blobs_.get(id);
}

std::vector<ScoredEntry> Core::search(std::string_view query, size_t max_results,
                                      int64_t now) const {
  std::vector<ScoredEntry> matches;
  store_.for_each([&](const Entry& e) {
    if (auto s = fuzzy::score(query, e.text, recency_factor(e.timestamp, now))) {
      matches.push_back(ScoredEntry{e, *s});
    }
  });

  // Pinned matches first, then best score; stable_sort preserves store order
  // (most-recent-first) on ties. Pinned-first is a coordination/surfacing
  // decision here (FuzzyMatcher stays pure — the score still comes from it), so
  // a pinned entry always survives max_results truncation and the shell can
  // render the pinned prefix as its own section.
  std::stable_sort(matches.begin(), matches.end(),
                   [](const ScoredEntry& a, const ScoredEntry& b) {
                     if (a.entry.pinned != b.entry.pinned) return a.entry.pinned;
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

  // GC orphan blobs ONLY after the new log is durably in place (log_.compact has
  // fsync'd + renamed). Deleting earlier could orphan a blob the still-current
  // log references; doing it after means a crash mid-GC leaves only
  // re-collectable orphans, never a dangling reference.
  std::unordered_set<std::string> live_ids;
  for (const Entry& e : live) {
    if (e.kind == Kind::Image) live_ids.insert(e.id);
  }
  blobs_.gc(live_ids);
}

Stats Core::stats() const {
  return Stats{store_.size(), log_.size_bytes(), store_.total_bytes()};
}

}  // namespace clipd
