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

// --- Pinned: exemption from eviction ---------------------------------------

TEST(ClipStore, PinnedStateReportsValueOrNulloptForMissing) {
  ClipStore s(10);
  s.upsert(mk("a", 1));
  EXPECT_EQ(s.pinned_state("a"), std::optional<bool>(false));
  EXPECT_EQ(s.pinned_state("missing"), std::nullopt);
}

TEST(ClipStore, SetPinnedIsIdempotentAndNoOpOnUnknownId) {
  ClipStore s(10);
  s.upsert(mk("a", 1));
  s.set_pinned("a", true);
  s.set_pinned("a", true);  // idempotent
  EXPECT_EQ(s.pinned_state("a"), std::optional<bool>(true));
  s.set_pinned("ghost", true);  // unknown id: no crash, no entry created
  EXPECT_EQ(s.pinned_state("ghost"), std::nullopt);
  EXPECT_EQ(s.size(), 1u);
}

TEST(ClipStore, SetPinnedDoesNotBumpRecency) {
  ClipStore s(10);
  s.upsert(mk("a", 1));
  s.upsert(mk("b", 2));
  s.set_pinned("a", true);  // flips a flag; must not move "a" to most-recent
  EXPECT_EQ(texts(s), (std::vector<std::string>{"b", "a"}));
}

TEST(ClipStore, PinnedExemptFromCountEviction) {
  ClipStore s(2);  // count cap 2
  s.upsert(mk("a", 1));
  s.upsert(mk("b", 2));
  s.set_pinned("a", true);  // pin the oldest
  s.upsert(mk("c", 3));     // over cap: evict least-recent UNPINNED ("b"), not "a"
  EXPECT_EQ(texts(s), (std::vector<std::string>{"c", "a"}));
}

TEST(ClipStore, PinnedExemptFromByteEviction) {
  ClipStore s(/*max_entries=*/0, /*max_bytes=*/100);
  s.upsert(mk("a", 1, 40));
  s.upsert(mk("b", 2, 40));
  s.set_pinned("a", true);
  s.upsert(mk("c", 3, 40));  // total 120 > 100: evict least-recent unpinned ("b")
  EXPECT_EQ(texts(s), (std::vector<std::string>{"c", "a"}));
  EXPECT_EQ(s.total_bytes(), 80u);
}

TEST(ClipStore, PinnedNeverEvictedEvenWhenLeastRecent) {
  ClipStore s(3);
  s.upsert(mk("p", 1));
  s.set_pinned("p", true);  // pinned + will become the least-recent
  for (int i = 0; i < 10; ++i) s.upsert(mk("u" + std::to_string(i), 10 + i));
  // "p" survives; the cap holds (pins occupy a slot, so 2 unpinned remain).
  EXPECT_EQ(s.size(), 3u);
  EXPECT_EQ(texts(s), (std::vector<std::string>{"u9", "u8", "p"}));
}

TEST(ClipStore, AllPinnedOverCapTerminates) {
  ClipStore s(2);
  s.upsert(mk("a", 1)); s.set_pinned("a", true);
  s.upsert(mk("b", 2)); s.set_pinned("b", true);
  s.upsert(mk("c", 3)); s.set_pinned("c", true);  // size 3 > cap, all pinned: no evict
  EXPECT_EQ(s.size(), 3u);
  EXPECT_EQ(texts(s), (std::vector<std::string>{"c", "b", "a"}));
}

// The begin()-guard edge: byte cap exceeded, everything pinned EXCEPT a single
// just-inserted unpinned entry at the front. That most-recent entry is the only
// eviction candidate, but it must be protected (never evict the most-recent).
TEST(ClipStore, ByteCapDoesNotEvictTheLoneMostRecentUnpinnedAmongPins) {
  ClipStore s(/*max_entries=*/0, /*max_bytes=*/100);
  s.upsert(mk("p1", 1, 60)); s.set_pinned("p1", true);
  s.upsert(mk("p2", 2, 60)); s.set_pinned("p2", true);  // 120 > 100, both pinned: kept
  s.upsert(mk("u", 3, 60));  // 180 > 100; only "u" is unpinned, but it is begin()
  EXPECT_EQ(s.size(), 3u);   // nothing evictable: u protected, p1/p2 pinned
  EXPECT_EQ(texts(s), (std::vector<std::string>{"u", "p2", "p1"}));
}

// --- Remove + clear ---------------------------------------------------------

TEST(ClipStore, RemoveDropsEntryAndFreesBytes) {
  ClipStore s(/*max_entries=*/0, /*max_bytes=*/0);
  s.upsert(mk("a", 1, 10));
  s.upsert(mk("b", 2, 20));
  s.remove("a");
  EXPECT_EQ(s.size(), 1u);
  EXPECT_EQ(texts(s), (std::vector<std::string>{"b"}));
  EXPECT_EQ(s.total_bytes(), 20u);
}

TEST(ClipStore, RemoveUnknownIdIsNoOp) {
  ClipStore s(10);
  s.upsert(mk("a", 1));
  s.remove("nonexistent");
  EXPECT_EQ(s.size(), 1u);
}

TEST(ClipStore, ClearUnpinnedKeepsPinned) {
  ClipStore s(10);
  s.upsert(mk("a", 1, 5));
  s.upsert(mk("b", 2, 7)); s.set_pinned("b", true);
  s.upsert(mk("c", 3, 9));
  s.clear_unpinned();
  EXPECT_EQ(s.size(), 1u);
  EXPECT_EQ(texts(s), (std::vector<std::string>{"b"}));
  EXPECT_EQ(s.total_bytes(), 7u);  // only the pinned entry's bytes remain
}

// --- set_limits: the second eviction trigger --------------------------------
//
// Eviction used to happen only in upsert(). set_limits() is the second trigger:
// a cap the user lowers must take effect at once, not on the next copy. Replay
// stays faithful because replay never calls set_limits — it constructs the store
// with the already-current caps and drives everything through upsert().

TEST(ClipStore, SetLimitsLowersCountAndEvictsImmediately) {
  ClipStore s(10);
  s.upsert(mk("a", 1));
  s.upsert(mk("b", 2));
  s.upsert(mk("c", 3));
  s.upsert(mk("d", 4));
  s.set_limits(2, 0);  // no further upsert: the reduction itself must evict
  EXPECT_EQ(s.size(), 2u);
  EXPECT_EQ(texts(s), (std::vector<std::string>{"d", "c"}));  // least-recent go
}

TEST(ClipStore, SetLimitsLowersByteBudgetAndEvictsImmediately) {
  ClipStore s(/*max_entries=*/0, /*max_bytes=*/0);
  s.upsert(mk("a", 1, 40));
  s.upsert(mk("b", 2, 40));
  s.upsert(mk("c", 3, 40));
  EXPECT_EQ(s.total_bytes(), 120u);
  s.set_limits(0, 100);
  EXPECT_EQ(texts(s), (std::vector<std::string>{"c", "b"}));
  EXPECT_EQ(s.total_bytes(), 80u);
}

TEST(ClipStore, SetLimitsSparesPinnedUnderCountCap) {
  ClipStore s(10);
  s.upsert(mk("a", 1)); s.set_pinned("a", true);  // pinned AND least-recent
  s.upsert(mk("b", 2));
  s.upsert(mk("c", 3));
  s.upsert(mk("d", 4));
  s.set_limits(2, 0);
  // "a" is exempt; the victims are the least-recent UNPINNED entries.
  EXPECT_EQ(s.size(), 2u);
  EXPECT_EQ(texts(s), (std::vector<std::string>{"d", "a"}));
}

// Pinned is exempt from the byte budget too, so lowering it can leave the store
// ABOVE the new cap. That is the documented trade-off (pinning many large images
// can push usage past max_bytes) — assert it rather than "fixing" it.
TEST(ClipStore, SetLimitsHoldsAboveByteBudgetWhenOnlyPinnedRemain) {
  ClipStore s(/*max_entries=*/0, /*max_bytes=*/0);
  s.upsert(mk("p1", 1, 60)); s.set_pinned("p1", true);
  s.upsert(mk("p2", 2, 60)); s.set_pinned("p2", true);
  s.upsert(mk("u", 3, 60));
  s.set_limits(0, 50);
  // "u" is unpinned but is the most-recent (front), which is never evicted; the
  // two pins are exempt. Nothing is evictable, so the budget is held above 50.
  EXPECT_EQ(s.size(), 3u);
  EXPECT_EQ(s.total_bytes(), 180u);
}

TEST(ClipStore, SetLimitsHoldsAboveCountCapWhenAllPinned) {
  ClipStore s(10);
  s.upsert(mk("a", 1)); s.set_pinned("a", true);
  s.upsert(mk("b", 2)); s.set_pinned("b", true);
  s.upsert(mk("c", 3)); s.set_pinned("c", true);
  s.set_limits(1, 0);  // must terminate, not spin, and must not drop a pin
  EXPECT_EQ(s.size(), 3u);
  EXPECT_EQ(texts(s), (std::vector<std::string>{"c", "b", "a"}));
}

TEST(ClipStore, SetLimitsRaisingCapEvictsNothingAndResurrectsNothing) {
  ClipStore s(2);
  s.upsert(mk("a", 1));
  s.upsert(mk("b", 2));
  s.upsert(mk("c", 3));  // "a" evicted at insert time
  s.set_limits(100, 0);
  EXPECT_EQ(s.size(), 2u);  // the store is in-memory: raising a cap brings nothing back
  EXPECT_EQ(texts(s), (std::vector<std::string>{"c", "b"}));
}

TEST(ClipStore, SetLimitsZeroMeansNoCap) {
  ClipStore s(/*max_entries=*/2, /*max_bytes=*/100);
  s.upsert(mk("a", 1, 40));
  s.upsert(mk("b", 2, 40));
  EXPECT_EQ(s.size(), 2u);
  s.set_limits(0, 0);  // both caps off
  s.upsert(mk("c", 3, 40));
  s.upsert(mk("d", 4, 40));
  EXPECT_EQ(s.size(), 4u);
  EXPECT_EQ(s.total_bytes(), 160u);
}

TEST(ClipStore, SetLimitsAccessorsReportNewValues) {
  ClipStore s(10, 1000);
  s.set_limits(42, 4096);
  EXPECT_EQ(s.max_entries(), 42u);
  EXPECT_EQ(s.max_bytes(), 4096u);
}

// The new caps must govern LATER upserts too, not just the one-shot evict.
TEST(ClipStore, SetLimitsGovernsSubsequentUpserts) {
  ClipStore s(100);
  s.upsert(mk("a", 1));
  s.set_limits(2, 0);
  s.upsert(mk("b", 2));
  s.upsert(mk("c", 3));
  s.upsert(mk("d", 4));
  EXPECT_EQ(s.size(), 2u);
  EXPECT_EQ(texts(s), (std::vector<std::string>{"d", "c"}));
}
