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
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
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
  EXPECT_EQ(clipd_create(bad.string().c_str(), 100, kNoAutoCompact, 0, 0), nullptr);
}

TEST_F(CApiTest, AddThenSearchReturnsScoredMatch) {
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
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
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
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
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
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
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
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
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
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
    ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
    ASSERT_NE(core, nullptr);
    ASSERT_EQ(clipd_add(core, "persisted", 1), 0);
    ASSERT_EQ(clipd_add(core, "alsohere", 2), 0);
    clipd_destroy(core);
  }
  ClipdCore* reopened = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
  ASSERT_NE(reopened, nullptr);
  ClipdResults* r = clipd_search(reopened, "", 10, 100);
  ASSERT_NE(r, nullptr);
  EXPECT_EQ(r->count, 2u);
  clipd_free_results(r);
  clipd_destroy(reopened);
}

TEST_F(CApiTest, StatsReportsEntryCountAndLogGrowth) {
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
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
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
  ASSERT_NE(core, nullptr);
  EXPECT_NE(clipd_stats(core, nullptr), 0);  // NULL out → failure
  clipd_destroy(core);
}

TEST_F(CApiTest, CompactShrinksLogAfterDedup) {
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
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

// --- images, files, and the richer ClipdMatch ------------------------------

TEST_F(CApiTest, TextMatchHasTextKindAndId) {
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
  ASSERT_NE(core, nullptr);
  ASSERT_EQ(clipd_add(core, "hello", 1), 0);

  ClipdResults* r = clipd_search(core, "hello", 10, 100);
  ASSERT_NE(r, nullptr);
  ASSERT_EQ(r->count, 1u);
  EXPECT_EQ(r->matches[0].kind, CLIPD_TEXT);
  ASSERT_NE(r->matches[0].id, nullptr);
  EXPECT_EQ(std::string(r->matches[0].id).size(), 64u);  // sha256-hex
  clipd_free_results(r);
  clipd_destroy(core);
}

TEST_F(CApiTest, AddImageSearchResultCarriesKindDimsAndId) {
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
  ASSERT_NE(core, nullptr);
  const std::string png = "\x89PNG\r\n\x1a\nIMAGEBYTES";
  ASSERT_EQ(clipd_add_image(core, reinterpret_cast<const uint8_t*>(png.data()),
                            png.size(), 1024, 768, CLIPD_IMAGE_PNG, 1),
            0);

  ClipdResults* r = clipd_search(core, "image", 10, 100);
  ASSERT_NE(r, nullptr);
  ASSERT_EQ(r->count, 1u);
  EXPECT_EQ(r->matches[0].kind, CLIPD_IMAGE);
  EXPECT_EQ(r->matches[0].width, 1024u);
  EXPECT_EQ(r->matches[0].height, 768u);
  EXPECT_EQ(r->matches[0].byte_size, png.size());
  ASSERT_NE(r->matches[0].id, nullptr);
  EXPECT_EQ(std::string(r->matches[0].id).size(), 64u);
  clipd_free_results(r);
  clipd_destroy(core);
}

TEST_F(CApiTest, ReadBlobRoundTripsImageBytes) {
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
  ASSERT_NE(core, nullptr);
  const std::string png("\x00\x01\x02\xffRAW", 7);  // embedded NUL + high byte
  ASSERT_EQ(clipd_add_image(core, reinterpret_cast<const uint8_t*>(png.data()),
                            png.size(), 2, 2, CLIPD_IMAGE_PNG, 1),
            0);

  ClipdResults* r = clipd_search(core, "", 10, 100);
  ASSERT_NE(r, nullptr);
  ASSERT_EQ(r->count, 1u);
  std::string id = r->matches[0].id;
  clipd_free_results(r);

  size_t len = 0;
  const uint8_t* bytes = clipd_read_blob(core, id.c_str(), &len);
  ASSERT_NE(bytes, nullptr);
  ASSERT_EQ(len, png.size());
  EXPECT_EQ(std::string(reinterpret_cast<const char*>(bytes), len), png);
  clipd_free_blob(bytes);
  clipd_destroy(core);
}

TEST_F(CApiTest, ReadBlobUnknownIdReturnsNull) {
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
  ASSERT_NE(core, nullptr);
  size_t len = 123;
  EXPECT_EQ(clipd_read_blob(core, std::string(64, 'a').c_str(), &len), nullptr);
  clipd_destroy(core);
}

TEST_F(CApiTest, AddFileResultIsFileKindWithPath) {
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
  ASSERT_NE(core, nullptr);
  ASSERT_EQ(clipd_add_file(core, "/Users/me/notes.txt", 1), 0);

  ClipdResults* r = clipd_search(core, "notes", 10, 100);
  ASSERT_NE(r, nullptr);
  ASSERT_EQ(r->count, 1u);
  EXPECT_EQ(r->matches[0].kind, CLIPD_FILE);
  EXPECT_STREQ(r->matches[0].text, "/Users/me/notes.txt");
  clipd_free_results(r);
  clipd_destroy(core);
}

TEST_F(CApiTest, ImageFileBlobNullArgsAreSafe) {
  EXPECT_NE(clipd_add_image(nullptr, nullptr, 0, 0, 0, CLIPD_IMAGE_PNG, 0), 0);
  EXPECT_NE(clipd_add_file(nullptr, "x", 0), 0);
  size_t len = 0;
  EXPECT_EQ(clipd_read_blob(nullptr, "id", &len), nullptr);
  clipd_free_blob(nullptr);  // safe no-op

  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
  ASSERT_NE(core, nullptr);
  EXPECT_NE(clipd_add_image(core, nullptr, 0, 1, 1, CLIPD_IMAGE_PNG, 0), 0);
  EXPECT_NE(clipd_add_file(core, nullptr, 0), 0);
  clipd_destroy(core);
}

TEST_F(CApiTest, StatsReportsStoreBytes) {
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
  ASSERT_NE(core, nullptr);
  ASSERT_EQ(clipd_add(core, "abcde", 1), 0);  // 5 bytes
  ClipdStats s{};
  ASSERT_EQ(clipd_stats(core, &s), 0);
  EXPECT_EQ(s.store_bytes, 5u);
  clipd_destroy(core);
}

// --- Pinned / delete / clear over the C boundary ----------------------------

// Fetch the id of the single search match for `query` (caller asserts count==1).
static std::string only_match_id(ClipdCore* core, const char* query) {
  ClipdResults* r = clipd_search(core, query, 10, 100);
  std::string id = (r && r->count == 1) ? std::string(r->matches[0].id) : "";
  clipd_free_results(r);
  return id;
}

TEST_F(CApiTest, SetPinnedReflectedInSearchMatch) {
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
  ASSERT_NE(core, nullptr);
  ASSERT_EQ(clipd_add(core, "favorite", 1), 0);

  std::string id = only_match_id(core, "favorite");
  ASSERT_EQ(id.size(), 64u);
  // Unpinned by default.
  ClipdResults* before = clipd_search(core, "favorite", 10, 100);
  ASSERT_EQ(before->count, 1u);
  EXPECT_EQ(before->matches[0].pinned, 0);
  clipd_free_results(before);

  ASSERT_EQ(clipd_set_pinned(core, id.c_str(), 1), 0);

  ClipdResults* after = clipd_search(core, "favorite", 10, 100);
  ASSERT_EQ(after->count, 1u);
  EXPECT_EQ(after->matches[0].pinned, 1);  // pinned field round-trips the arena
  clipd_free_results(after);
  clipd_destroy(core);
}

TEST_F(CApiTest, DeleteRemovesFromSearch) {
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
  ASSERT_NE(core, nullptr);
  ASSERT_EQ(clipd_add(core, "doomed", 1), 0);
  ASSERT_EQ(clipd_add(core, "survivor", 2), 0);

  std::string id = only_match_id(core, "doomed");
  ASSERT_EQ(id.size(), 64u);
  ASSERT_EQ(clipd_delete(core, id.c_str()), 0);

  EXPECT_EQ(clipd_search(core, "doomed", 10, 100)->count, 0u);  // leak ok: ASan run
  ClipdResults* r = clipd_search(core, "survivor", 10, 100);
  EXPECT_EQ(r->count, 1u);
  clipd_free_results(r);
  clipd_destroy(core);
}

TEST_F(CApiTest, ClearKeepsPinned) {
  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
  ASSERT_NE(core, nullptr);
  ASSERT_EQ(clipd_add(core, "fav", 1), 0);
  std::string id = only_match_id(core, "fav");
  ASSERT_EQ(clipd_set_pinned(core, id.c_str(), 1), 0);
  ASSERT_EQ(clipd_add(core, "trash", 2), 0);

  ASSERT_EQ(clipd_clear(core), 0);

  ClipdResults* r = clipd_search(core, "", 10, 100);
  ASSERT_EQ(r->count, 1u);          // only the pinned entry survives
  EXPECT_STREQ(r->matches[0].text, "fav");
  EXPECT_EQ(r->matches[0].pinned, 1);
  clipd_free_results(r);
  clipd_destroy(core);
}

TEST_F(CApiTest, PinDeleteClearNullArgsAreSafe) {
  EXPECT_NE(clipd_set_pinned(nullptr, "id", 1), 0);
  EXPECT_NE(clipd_delete(nullptr, "id"), 0);
  EXPECT_NE(clipd_clear(nullptr), 0);

  ClipdCore* core = clipd_create(log_path().c_str(), 100, kNoAutoCompact, 0, 0);
  ASSERT_NE(core, nullptr);
  EXPECT_NE(clipd_set_pinned(core, nullptr, 1), 0);
  EXPECT_NE(clipd_delete(core, nullptr), 0);
  // A clear on an empty store is a valid no-op success.
  EXPECT_EQ(clipd_clear(core), 0);
  clipd_destroy(core);
}

}  // namespace
