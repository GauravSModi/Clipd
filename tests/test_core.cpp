#include "core.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <filesystem>
#include <string>
#include <vector>

using clipd::Core;
using clipd::ScoredEntry;
namespace fs = std::filesystem;

namespace {

constexpr uint64_t kNoAutoCompact = 1ull << 40;  // effectively never

class CoreTest : public ::testing::Test {
 protected:
  void SetUp() override {
    path_ = fs::temp_directory_path() /
            ("clipd_core_test_" +
             std::to_string(reinterpret_cast<uintptr_t>(this)));
    fs::remove(path_);
  }
  void TearDown() override { fs::remove(path_); }

  std::vector<std::string> all_texts(const Core& core, int64_t now) {
    std::vector<std::string> out;
    for (const auto& s : core.search("", 1000, now)) out.push_back(s.entry.text);
    return out;
  }

  bool contains(const Core& core, const std::string& text, int64_t now) {
    auto v = all_texts(core, now);
    return std::find(v.begin(), v.end(), text) != v.end();
  }

  fs::path path_;
};

TEST_F(CoreTest, AddAndSearchFindsMatch) {
  Core core(path_, 100, kNoAutoCompact);
  core.start();
  core.add("hello world", 1);
  core.add("goodbye", 2);
  auto results = core.search("hw", 10, 10);
  ASSERT_FALSE(results.empty());
  EXPECT_EQ(results[0].entry.text, "hello world");
}

TEST_F(CoreTest, SearchExcludesNonMatches) {
  Core core(path_, 100, kNoAutoCompact);
  core.start();
  core.add("apple", 1);
  core.add("banana", 2);
  EXPECT_TRUE(core.search("xyz", 10, 10).empty());
}

TEST_F(CoreTest, SearchRespectsMaxResults) {
  Core core(path_, 100, kNoAutoCompact);
  core.start();
  core.add("cat1", 1);
  core.add("cat2", 2);
  core.add("cat3", 3);
  EXPECT_EQ(core.search("cat", 2, 10).size(), 2u);
}

TEST_F(CoreTest, SearchTieBrokenByRecency) {
  Core core(path_, 100, kNoAutoCompact);
  core.start();
  // "xa" and "xb" have identical match quality for query "x"; only recency
  // differs. The more recent one must rank first.
  core.add("xa", 1000);
  core.add("xb", 2000);
  auto results = core.search("x", 10, 2000);
  ASSERT_EQ(results.size(), 2u);
  EXPECT_EQ(results[0].entry.text, "xb");
  EXPECT_GT(results[0].score, results[1].score);
}

TEST_F(CoreTest, DedupKeepsSingleEntryWithLatestTimestamp) {
  Core core(path_, 100, kNoAutoCompact);
  core.start();
  core.add("repeat", 1);
  core.add("other", 2);
  core.add("repeat", 3);  // re-copy
  auto results = core.search("repeat", 10, 10);
  ASSERT_EQ(results.size(), 1u);
  EXPECT_EQ(results[0].entry.timestamp, 3);
}

TEST_F(CoreTest, PersistsAcrossRestart) {
  {
    Core core(path_, 100, kNoAutoCompact);
    core.start();
    core.add("persisted", 1);
    core.add("alsohere", 2);
  }
  Core reopened(path_, 100, kNoAutoCompact);
  reopened.start();
  EXPECT_TRUE(contains(reopened, "persisted", 10));
  EXPECT_TRUE(contains(reopened, "alsohere", 10));
}

TEST_F(CoreTest, ReplayDoesNotResurrectEvictedEntries) {
  {
    Core core(path_, 2, kNoAutoCompact);
    core.start();
    core.add("first", 1);
    core.add("second", 2);
    core.add("third", 3);  // evicts "first" from the live store
  }
  // Reopen at the SAME cap: replay reproduces eviction, "first" stays gone.
  Core reopened(path_, 2, kNoAutoCompact);
  reopened.start();
  EXPECT_FALSE(contains(reopened, "first", 10));
  EXPECT_TRUE(contains(reopened, "second", 10));
  EXPECT_TRUE(contains(reopened, "third", 10));
  EXPECT_EQ(reopened.stats().entry_count, 2u);
}

TEST_F(CoreTest, RaisingCapRecoversEvictedBeforeCompaction) {
  {
    Core core(path_, 2, kNoAutoCompact);
    core.start();
    core.add("first", 1);
    core.add("second", 2);
    core.add("third", 3);  // "first" evicted from store, still in the log
  }
  // The log still holds "first"; a larger cap re-derives it on replay.
  Core bigger(path_, 5, kNoAutoCompact);
  bigger.start();
  EXPECT_TRUE(contains(bigger, "first", 10));
  EXPECT_EQ(bigger.stats().entry_count, 3u);
}

TEST_F(CoreTest, CompactionDiscardsEvictedPermanently) {
  {
    Core core(path_, 2, kNoAutoCompact);
    core.start();
    core.add("first", 1);
    core.add("second", 2);
    core.add("third", 3);  // "first" evicted from store
    core.compact();        // rewrites log to the live set, dropping "first"
  }
  // Even a larger cap cannot recover "first": compaction discarded it.
  Core bigger(path_, 5, kNoAutoCompact);
  bigger.start();
  EXPECT_FALSE(contains(bigger, "first", 10));
  EXPECT_TRUE(contains(bigger, "second", 10));
  EXPECT_TRUE(contains(bigger, "third", 10));
}

TEST_F(CoreTest, CompactionPreservesRecencyOrderOnReplay) {
  {
    Core core(path_, 100, kNoAutoCompact);
    core.start();
    core.add("oldest", 1);
    core.add("middle", 2);
    core.add("newest", 3);
    core.compact();
  }
  Core reopened(path_, 100, kNoAutoCompact);
  reopened.start();
  auto texts = all_texts(reopened, 10);
  ASSERT_EQ(texts.size(), 3u);
  EXPECT_EQ(texts[0], "newest");  // most-recent first
  EXPECT_EQ(texts[2], "oldest");
}

TEST_F(CoreTest, LoweringCapOnReopenEvictsDownToNewCap) {
  {
    Core core(path_, 5, kNoAutoCompact);
    core.start();
    core.add("e1", 1);
    core.add("e2", 2);
    core.add("e3", 3);
    core.add("e4", 4);
    core.add("e5", 5);  // five live entries at cap 5
  }
  // Reopen at a SMALLER cap: chronological replay re-applies eviction at the new
  // cap, so only the two most-recent survive and the older three drop.
  Core smaller(path_, 2, kNoAutoCompact);
  smaller.start();
  EXPECT_EQ(smaller.stats().entry_count, 2u);
  EXPECT_TRUE(contains(smaller, "e5", 10));
  EXPECT_TRUE(contains(smaller, "e4", 10));
  EXPECT_FALSE(contains(smaller, "e3", 10));
  EXPECT_FALSE(contains(smaller, "e1", 10));
}

TEST_F(CoreTest, RaisedCapRecoveredEntriesSurviveCompaction) {
  {
    Core core(path_, 2, kNoAutoCompact);
    core.start();
    core.add("first", 1);
    core.add("second", 2);
    core.add("third", 3);  // "first" evicted from store, still in the log
  }
  // Raise the cap so "first" is recovered on replay, then compact — rewriting the
  // log to the recovered live set makes the recovery durable.
  {
    Core bigger(path_, 5, kNoAutoCompact);
    bigger.start();
    ASSERT_TRUE(contains(bigger, "first", 10));
    bigger.compact();
  }
  // Reopening at the same larger cap still sees all three: compaction persisted
  // the recovered entry rather than dropping it.
  Core reopened(path_, 5, kNoAutoCompact);
  reopened.start();
  EXPECT_TRUE(contains(reopened, "first", 10));
  EXPECT_EQ(reopened.stats().entry_count, 3u);
}

TEST_F(CoreTest, FailedAddLeavesStoreUnchanged) {
  // add() appends to the log before mutating the store, so a failed write
  // leaves the store untouched — the two never disagree mid-session.
  fs::path dir = fs::temp_directory_path() /
                 ("clipd_core_addfail_" +
                  std::to_string(reinterpret_cast<uintptr_t>(this)));
  fs::remove_all(dir);
  fs::create_directory(dir);

  Core core(dir / "log", 100, kNoAutoCompact);
  core.start();
  core.add("ok", 1);
  ASSERT_EQ(core.stats().entry_count, 1u);

  fs::remove_all(dir);  // log's parent is gone: the next append must fail
  EXPECT_THROW(core.add("dropped", 2), std::exception);
  EXPECT_EQ(core.stats().entry_count, 1u);  // store not mutated by a failed add
}

}  // namespace
