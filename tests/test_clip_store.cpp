#include "clip_store.hpp"

#include <gtest/gtest.h>

#include <string>
#include <vector>

using clipd::ClipStore;
using clipd::Entry;

namespace {

// Helper: collect live entries most-recent-first.
std::vector<std::string> texts(const ClipStore& s) {
  std::vector<std::string> out;
  s.for_each([&](const Entry& e) { out.push_back(e.text); });
  return out;
}

}  // namespace

TEST(ClipStore, StoresAndIteratesMostRecentFirst) {
  ClipStore s(10);
  s.upsert("a", 1);
  s.upsert("b", 2);
  s.upsert("c", 3);
  EXPECT_EQ(texts(s), (std::vector<std::string>{"c", "b", "a"}));
  EXPECT_EQ(s.size(), 3u);
}

TEST(ClipStore, DedupBumpsRecencyWithoutDuplicating) {
  ClipStore s(10);
  s.upsert("a", 1);
  s.upsert("b", 2);
  s.upsert("a", 3);  // re-copy "a"
  EXPECT_EQ(s.size(), 2u);
  EXPECT_EQ(texts(s), (std::vector<std::string>{"a", "b"}));
}

TEST(ClipStore, DedupUpdatesTimestampToMostRecent) {
  ClipStore s(10);
  s.upsert("a", 1);
  s.upsert("a", 99);
  int64_t ts = -1;
  s.for_each([&](const Entry& e) { ts = e.timestamp; });
  EXPECT_EQ(ts, 99);
}

TEST(ClipStore, EvictsLeastRecentWhenOverCapacity) {
  ClipStore s(2);
  s.upsert("a", 1);
  s.upsert("b", 2);
  s.upsert("c", 3);  // should evict "a"
  EXPECT_EQ(s.size(), 2u);
  EXPECT_EQ(texts(s), (std::vector<std::string>{"c", "b"}));
}

TEST(ClipStore, DedupBumpProtectsFromEviction) {
  ClipStore s(2);
  s.upsert("a", 1);
  s.upsert("b", 2);
  s.upsert("a", 3);  // bump "a" to front; "b" is now least-recent
  s.upsert("c", 4);  // evicts "b", not "a"
  EXPECT_EQ(texts(s), (std::vector<std::string>{"c", "a"}));
}

TEST(ClipStore, RepeatedInsertsHoldLiveCountAtCap) {
  ClipStore s(3);
  for (int i = 0; i < 100; ++i) s.upsert("e" + std::to_string(i), i);
  // Eviction fires on every over-cap insert, so the live count never exceeds the
  // cap; only the three most-recent survive, most-recent first.
  EXPECT_EQ(s.size(), 3u);
  EXPECT_EQ(texts(s), (std::vector<std::string>{"e99", "e98", "e97"}));
}

TEST(ClipStore, SnapshotMatchesRecencyOrder) {
  ClipStore s(10);
  s.upsert("a", 1);
  s.upsert("b", 2);
  auto snap = s.snapshot();
  ASSERT_EQ(snap.size(), 2u);
  EXPECT_EQ(snap[0].text, "b");
  EXPECT_EQ(snap[1].text, "a");
}
