// Drives the flat C API (clipd.h) the way the Swift shell will: through the
// extern "C" boundary only, never touching the C++ core directly. Run under
// ASan/UBSan, this also proves the single-arena result alloc/free is leak- and
// pointer-clean.

#include "clipd.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <filesystem>
#include <string>

namespace fs = std::filesystem;

// Defined in tests/c_smoke.c and compiled as C: a pure-C client of the API.
extern "C" int clipd_c_smoke(const char* log_path);

namespace {

constexpr uint64_t kNoAutoCompact = 1ull << 40;  // effectively never

class CApiTest : public ::testing::Test {
 protected:
  void SetUp() override {
    path_ = fs::temp_directory_path() /
            ("clipd_capi_test_" +
             std::to_string(reinterpret_cast<uintptr_t>(this)));
    fs::remove(path_);
  }
  void TearDown() override { fs::remove(path_); }

  std::string log_path() const { return path_.string(); }

  fs::path path_;
};

TEST_F(CApiTest, CreateReturnsHandleAndDestroyIsNullSafe) {
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact);
  ASSERT_NE(core, nullptr);
  clipd_destroy(core);
  clipd_destroy(nullptr);  // must be a safe no-op
}

TEST_F(CApiTest, CreateOnUnwritablePathReturnsNull) {
  // Parent directory does not exist: start() can't open the log and throws,
  // which the boundary must translate to a NULL handle (no exception escapes).
  fs::path bad = fs::temp_directory_path() /
                 ("clipd_capi_no_dir_" +
                  std::to_string(reinterpret_cast<uintptr_t>(this))) /
                 "log";
  fs::remove_all(bad.parent_path());
  EXPECT_EQ(clipd_create(bad.string().c_str(), 100, kNoAutoCompact), nullptr);
}

TEST_F(CApiTest, AddThenSearchReturnsScoredMatch) {
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact);
  ASSERT_NE(core, nullptr);

  ASSERT_EQ(clipd_add(core, "hello world", 1), 0);
  ASSERT_EQ(clipd_add(core, "goodbye", 2), 0);

  ClipdResults* r = clipd_search(core, "hw", 10, 100);
  ASSERT_NE(r, nullptr);
  ASSERT_EQ(r->count, 1u);
  EXPECT_STREQ(r->matches[0].text, "hello world");
  EXPECT_EQ(r->matches[0].timestamp, 1);
  EXPECT_GT(r->matches[0].score, 0.0f);

  clipd_free_results(r);
  clipd_destroy(core);
}

TEST_F(CApiTest, SearchNoMatchReturnsEmptyNonNull) {
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact);
  ASSERT_NE(core, nullptr);
  ASSERT_EQ(clipd_add(core, "apple", 1), 0);

  // No match is a *successful* empty result (non-NULL, count 0), NOT a failure.
  // Swift branches on exactly this difference, so pin it.
  ClipdResults* r = clipd_search(core, "zzz", 10, 100);
  ASSERT_NE(r, nullptr);
  EXPECT_EQ(r->count, 0u);
  clipd_free_results(r);
  clipd_destroy(core);
}

TEST_F(CApiTest, SearchFailureReturnsNull) {
  // A failure (here: NULL handle) returns NULL — distinct from empty-but-valid.
  EXPECT_EQ(clipd_search(nullptr, "x", 10, 0), nullptr);
}

TEST_F(CApiTest, EmptyQueryReturnsRecentEntries) {
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact);
  ASSERT_NE(core, nullptr);
  ASSERT_EQ(clipd_add(core, "first", 1), 0);
  ASSERT_EQ(clipd_add(core, "second", 2), 0);

  ClipdResults* r = clipd_search(core, "", 10, 100);
  ASSERT_NE(r, nullptr);
  EXPECT_EQ(r->count, 2u);
  clipd_free_results(r);
  clipd_destroy(core);
}

TEST_F(CApiTest, SearchRespectsMaxResults) {
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact);
  ASSERT_NE(core, nullptr);
  ASSERT_EQ(clipd_add(core, "cat1", 1), 0);
  ASSERT_EQ(clipd_add(core, "cat2", 2), 0);
  ASSERT_EQ(clipd_add(core, "cat3", 3), 0);

  ClipdResults* r = clipd_search(core, "cat", 2, 100);
  ASSERT_NE(r, nullptr);
  EXPECT_EQ(r->count, 2u);
  clipd_free_results(r);
  clipd_destroy(core);
}

TEST_F(CApiTest, RecencyReferenceFlowsThroughNow) {
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact);
  ASSERT_NE(core, nullptr);
  // Equal match quality for query "x"; only recency differs, so now_ms must
  // tilt the ranking to the more recent entry.
  ASSERT_EQ(clipd_add(core, "xa", 1000), 0);
  ASSERT_EQ(clipd_add(core, "xb", 2000), 0);

  ClipdResults* r = clipd_search(core, "x", 10, 2000);
  ASSERT_NE(r, nullptr);
  ASSERT_EQ(r->count, 2u);
  EXPECT_STREQ(r->matches[0].text, "xb");
  EXPECT_GT(r->matches[0].score, r->matches[1].score);
  clipd_free_results(r);
  clipd_destroy(core);
}

TEST_F(CApiTest, FreeResultsOnNullIsNoOp) {
  clipd_free_results(nullptr);  // must be a safe no-op
}

TEST_F(CApiTest, PersistsAcrossReopen) {
  {
    ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact);
    ASSERT_NE(core, nullptr);
    ASSERT_EQ(clipd_add(core, "persisted", 1), 0);
    ASSERT_EQ(clipd_add(core, "alsohere", 2), 0);
    clipd_destroy(core);
  }
  ClipdCore* reopened = clipd_create(log_path().c_str(), 100, kNoAutoCompact);
  ASSERT_NE(reopened, nullptr);
  ClipdResults* r = clipd_search(reopened, "", 10, 100);
  ASSERT_NE(r, nullptr);
  EXPECT_EQ(r->count, 2u);
  clipd_free_results(r);
  clipd_destroy(reopened);
}

TEST_F(CApiTest, StatsReportsEntryCountAndLogGrowth) {
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact);
  ASSERT_NE(core, nullptr);

  ClipdStats s0{};
  ASSERT_EQ(clipd_stats(core, &s0), 0);
  EXPECT_EQ(s0.entry_count, 0u);

  ASSERT_EQ(clipd_add(core, "one", 1), 0);
  ASSERT_EQ(clipd_add(core, "two", 2), 0);

  ClipdStats s1{};
  ASSERT_EQ(clipd_stats(core, &s1), 0);
  EXPECT_EQ(s1.entry_count, 2u);
  EXPECT_GT(s1.log_bytes, s0.log_bytes);

  clipd_destroy(core);
}

TEST_F(CApiTest, StatsOnNullArgsFails) {
  ClipdStats s{};
  EXPECT_NE(clipd_stats(nullptr, &s), 0);  // NULL handle → failure
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact);
  ASSERT_NE(core, nullptr);
  EXPECT_NE(clipd_stats(core, nullptr), 0);  // NULL out → failure
  clipd_destroy(core);
}

TEST_F(CApiTest, CompactShrinksLogAfterDedup) {
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact);
  ASSERT_NE(core, nullptr);
  // Re-copy the same text repeatedly: dedup keeps one live entry, but each copy
  // is appended, so superseded records accumulate until compaction.
  for (int i = 0; i < 50; ++i) ASSERT_EQ(clipd_add(core, "dup", i), 0);

  ClipdStats before{};
  ASSERT_EQ(clipd_stats(core, &before), 0);
  ASSERT_EQ(clipd_compact(core), 0);
  ClipdStats after{};
  ASSERT_EQ(clipd_stats(core, &after), 0);

  EXPECT_EQ(after.entry_count, 1u);              // dedup → one live entry
  EXPECT_LT(after.log_bytes, before.log_bytes);  // compaction dropped the rest
  clipd_destroy(core);
}

TEST_F(CApiTest, PureCClientCompilesAndRuns) {
  // The C client (tests/c_smoke.c) adds three entries and searches "alpha",
  // which matches "alpha one" and "alpha three" but not "beta two".
  EXPECT_EQ(clipd_c_smoke(log_path().c_str()), 2);
}

}  // namespace
