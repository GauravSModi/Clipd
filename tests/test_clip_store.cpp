#include "clip_store.hpp"

#include <gtest/gtest.h>

#include <string>
#include <vector>

#include "entry.hpp"

using clipd::ClipStore;
using clipd::Entry;

namespace {

// Build an entry whose id mirrors its text, for readable recency assertions.
Entry mk(std::string id, int64_t ts, uint64_t bytes = 0) {
  Entry e;
  e.id = id;
  e.text = id;
  e.timestamp = ts;
  e.byte_size = bytes;
  return e;
}

// Build an entry with an explicit, distinct id and text.
Entry mk_id(std::string id, std::string text, int64_t ts, uint64_t bytes = 0) {
  Entry e;
  e.id = std::move(id);
  e.text = std::move(text);
  e.timestamp = ts;
  e.byte_size = bytes;
  return e;
}

std::vector<std::string> texts(const ClipStore& s) {
  std::vector<std::string> out;
  s.for_each([&](const Entry& e) { out.push_back(e.text); });
  return out;
}

}  // namespace

TEST(ClipStore, StoresAndIteratesMostRecentFirst) {
  ClipStore s(10);
  s.upsert(mk("a", 1));
  s.upsert(mk("b", 2));
  s.upsert(mk("c", 3));
  EXPECT_EQ(texts(s), (std::vector<std::string>{"c", "b", "a"}));
  EXPECT_EQ(s.size(), 3u);
}

TEST(ClipStore, DedupByIdBumpsRecencyWithoutDuplicating) {
  ClipStore s(10);
  s.upsert(mk("a", 1));
  s.upsert(mk("b", 2));
  s.upsert(mk("a", 3));  // re-copy "a"
  EXPECT_EQ(s.size(), 2u);
  EXPECT_EQ(texts(s), (std::vector<std::string>{"a", "b"}));
}

TEST(ClipStore, DedupUpdatesTimestampToMostRecent) {
  ClipStore s(10);
  s.upsert(mk("a", 1));
  s.upsert(mk("a", 99));
  int64_t ts = -1;
  s.for_each([&](const Entry& e) { ts = e.timestamp; });
  EXPECT_EQ(ts, 99);
}

// Identity is the id, not the text: a text entry and a file entry that happen to
// carry the same display string must be two distinct live entries.
TEST(ClipStore, DistinctIdsWithSameTextAreSeparateEntries) {
  ClipStore s(10);
  s.upsert(mk_id("text-id", "/Users/me/a.png", 1));
  s.upsert(mk_id("file-id", "/Users/me/a.png", 2));
  EXPECT_EQ(s.size(), 2u);
}

TEST(ClipStore, EvictsLeastRecentWhenOverCountCap) {
  ClipStore s(2);
  s.upsert(mk("a", 1));
  s.upsert(mk("b", 2));
  s.upsert(mk("c", 3));  // evicts "a"
  EXPECT_EQ(s.size(), 2u);
  EXPECT_EQ(texts(s), (std::vector<std::string>{"c", "b"}));
}

TEST(ClipStore, DedupBumpProtectsFromEviction) {
  ClipStore s(2);
  s.upsert(mk("a", 1));
  s.upsert(mk("b", 2));
  s.upsert(mk("a", 3));  // bump "a"; "b" now least-recent
  s.upsert(mk("c", 4));  // evicts "b", not "a"
  EXPECT_EQ(texts(s), (std::vector<std::string>{"c", "a"}));
}

TEST(ClipStore, RepeatedInsertsHoldLiveCountAtCap) {
  ClipStore s(3);
  for (int i = 0; i < 100; ++i) s.upsert(mk("e" + std::to_string(i), i));
  EXPECT_EQ(s.size(), 3u);
  EXPECT_EQ(texts(s), (std::vector<std::string>{"e99", "e98", "e97"}));
}

TEST(ClipStore, SnapshotMatchesRecencyOrder) {
  ClipStore s(10);
  s.upsert(mk("a", 1));
  s.upsert(mk("b", 2));
  auto snap = s.snapshot();
  ASSERT_EQ(snap.size(), 2u);
  EXPECT_EQ(snap[0].text, "b");
  EXPECT_EQ(snap[1].text, "a");
}

// --- Byte-budget eviction (new) --------------------------------------------

TEST(ClipStore, ByteBudgetEvictsLeastRecentUntilUnderLimit) {
  ClipStore s(/*max_entries=*/0, /*max_bytes=*/100);  // no count cap, 100-byte cap
  s.upsert(mk("a", 1, 40));
  s.upsert(mk("b", 2, 40));   // total 80
  s.upsert(mk("c", 3, 40));   // total would be 120 > 100 -> evict "a"
  EXPECT_EQ(texts(s), (std::vector<std::string>{"c", "b"}));
  EXPECT_EQ(s.total_bytes(), 80u);
}

TEST(ClipStore, CountAndByteCapsAreBothEnforced) {
  ClipStore s(/*max_entries=*/5, /*max_bytes=*/100);
  s.upsert(mk("a", 1, 60));
  s.upsert(mk("b", 2, 60));   // 120 > 100 -> evict "a" (count is fine at 2)
  EXPECT_EQ(texts(s), (std::vector<std::string>{"b"}));
  EXPECT_EQ(s.total_bytes(), 60u);
}

TEST(ClipStore, TotalBytesTracksInsertEvictAndDedup) {
  ClipStore s(/*max_entries=*/0, /*max_bytes=*/0);  // unbounded
  s.upsert(mk("a", 1, 10));
  s.upsert(mk("b", 2, 20));
  EXPECT_EQ(s.total_bytes(), 30u);
  s.upsert(mk("a", 3, 10));  // dedup-bump: no double count
  EXPECT_EQ(s.total_bytes(), 30u);
  EXPECT_EQ(s.size(), 2u);
}

TEST(ClipStore, SingleOversizeEntryIsKeptNotEvictedToEmpty) {
  ClipStore s(/*max_entries=*/0, /*max_bytes=*/50);
  s.upsert(mk("big", 1, 1000));  // larger than the whole budget
  EXPECT_EQ(s.size(), 1u);       // the most-recent entry is never evicted away
  EXPECT_EQ(s.total_bytes(), 1000u);
}

TEST(ClipStore, ZeroByteBudgetMeansUnbounded) {
  ClipStore s(/*max_entries=*/0, /*max_bytes=*/0);
  s.upsert(mk("a", 1, 1000000));
  s.upsert(mk("b", 2, 1000000));
  EXPECT_EQ(s.size(), 2u);
  EXPECT_EQ(s.total_bytes(), 2000000u);
}

TEST(ClipStore, DefaultConstructionHasNoByteCap) {
  ClipStore s(10);  // single-arg ctor: count cap only
  EXPECT_EQ(s.max_bytes(), 0u);
}
