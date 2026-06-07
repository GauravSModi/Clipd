#include "core.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <optional>
#include <string>
#include <vector>

#include "entry.hpp"
#include "identity.hpp"

using clipd::Core;
using clipd::ImageFormat;
using clipd::Kind;
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

  // Capture a string as image bytes (the bytes are opaque to the core).
  void add_image(Core& core, const std::string& bytes, uint32_t w, uint32_t h,
                 ImageFormat fmt, int64_t ts) {
    core.add_image(reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size(), w,
                   h, fmt, ts);
  }

  std::optional<ScoredEntry> find_by_id(const Core& core, const std::string& id,
                                        int64_t now) {
    for (const auto& s : core.search("", 1000, now)) {
      if (s.entry.id == id) return s;
    }
    return std::nullopt;
  }

  // Write a legacy v0 log (no header, untagged [i64 ts][text] records) directly,
  // so we can prove start() migrates an existing pre-feature log.
  void write_v0_log(const std::vector<std::pair<int64_t, std::string>>& records) {
    auto put_u32 = [](std::string& out, uint32_t v) {
      for (int i = 0; i < 4; ++i)
        out.push_back(static_cast<char>((v >> (8 * i)) & 0xFF));
    };
    auto crc = [](const std::string& s) {
      uint32_t c = 0xFFFFFFFFu;
      for (unsigned char b : s) {
        c ^= b;
        for (int k = 0; k < 8; ++k) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
      }
      return c ^ 0xFFFFFFFFu;
    };
    std::ofstream f(path_, std::ios::binary | std::ios::trunc);
    for (const auto& [ts, text] : records) {
      std::string payload;
      auto u = static_cast<uint64_t>(ts);
      for (int i = 0; i < 8; ++i)
        payload.push_back(static_cast<char>((u >> (8 * i)) & 0xFF));
      payload.append(text);
      std::string rec;
      put_u32(rec, static_cast<uint32_t>(payload.size()));
      put_u32(rec, crc(payload));
      rec.append(payload);
      f.write(rec.data(), static_cast<std::streamsize>(rec.size()));
    }
  }

  std::string first_bytes(size_t n) const {
    std::ifstream f(path_, std::ios::binary);
    std::string out(n, '\0');
    f.read(out.data(), static_cast<std::streamsize>(n));
    out.resize(static_cast<size_t>(f.gcount()));
    return out;
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

// --- images and files ------------------------------------------------------

TEST_F(CoreTest, AddImageIsStoredAndSearchableByLabel) {
  Core core(path_, 100, kNoAutoCompact);
  core.start();
  add_image(core, "PNGBYTES", 1024, 768, ImageFormat::Png, 1);

  auto byword = core.search("image", 10, 10);
  ASSERT_EQ(byword.size(), 1u);
  EXPECT_EQ(byword[0].entry.kind, Kind::Image);
  EXPECT_EQ(byword[0].entry.width, 1024u);
  EXPECT_EQ(byword[0].entry.height, 768u);
  // The synthesized label carries the dimensions, so they are searchable too.
  EXPECT_FALSE(core.search("1024", 10, 10).empty());
}

TEST_F(CoreTest, AddImageDedupsIdenticalBytes) {
  Core core(path_, 100, kNoAutoCompact);
  core.start();
  add_image(core, "SAMEBYTES", 10, 10, ImageFormat::Png, 1);
  add_image(core, "SAMEBYTES", 10, 10, ImageFormat::Png, 5);  // re-copy
  EXPECT_EQ(core.stats().entry_count, 1u);
  // Recency bumped to the later timestamp.
  std::string id = clipd::content_id(Kind::Image, "SAMEBYTES");
  auto found = find_by_id(core, id, 10);
  ASSERT_TRUE(found.has_value());
  EXPECT_EQ(found->entry.timestamp, 5);
}

TEST_F(CoreTest, ReadBlobReturnsTheImageBytes) {
  Core core(path_, 100, kNoAutoCompact);
  core.start();
  add_image(core, "RAWIMAGE", 4, 4, ImageFormat::Tiff, 1);
  std::string id = clipd::content_id(Kind::Image, "RAWIMAGE");
  auto bytes = core.read_blob(id);
  ASSERT_TRUE(bytes.has_value());
  EXPECT_EQ(*bytes, "RAWIMAGE");
}

TEST_F(CoreTest, AddFileStoresPathAndIsSearchableByName) {
  Core core(path_, 100, kNoAutoCompact);
  core.start();
  core.add_file("/Users/me/report.pdf", 1);

  auto byname = core.search("report", 10, 10);
  ASSERT_EQ(byname.size(), 1u);
  EXPECT_EQ(byname[0].entry.kind, Kind::File);
  EXPECT_EQ(byname[0].entry.text, "/Users/me/report.pdf");
}

TEST_F(CoreTest, ImageAndFilePersistAcrossRestart) {
  std::string img_id = clipd::content_id(Kind::Image, "IMGDATA");
  {
    Core core(path_, 100, kNoAutoCompact);
    core.start();
    add_image(core, "IMGDATA", 8, 8, ImageFormat::Png, 1);
    core.add_file("/tmp/a.txt", 2);
  }
  Core reopened(path_, 100, kNoAutoCompact);
  reopened.start();
  EXPECT_TRUE(find_by_id(reopened, img_id, 10).has_value());
  EXPECT_TRUE(contains(reopened, "/tmp/a.txt", 10));
  EXPECT_EQ(*reopened.read_blob(img_id), "IMGDATA");
}

TEST_F(CoreTest, MissingBlobIsSkippedOnReplayKeepingOtherEntries) {
  std::string img_id = clipd::content_id(Kind::Image, "GONE");
  {
    Core core(path_, 100, kNoAutoCompact);
    core.start();
    core.add("keepme", 1);
    add_image(core, "GONE", 2, 2, ImageFormat::Png, 2);
  }
  // Simulate the backing blob disappearing (e.g. manual deletion / partial copy).
  fs::path blob_dir = path_;
  blob_dir += ".blobs";
  fs::remove(blob_dir / img_id);

  Core reopened(path_, 100, kNoAutoCompact);
  reopened.start();
  // The CRC-valid image record replays but its blob is gone, so that one entry
  // is skipped — the rest of the log replays normally (not a torn-tail wipe).
  EXPECT_FALSE(find_by_id(reopened, img_id, 10).has_value());
  EXPECT_TRUE(contains(reopened, "keepme", 10));
  EXPECT_EQ(reopened.stats().entry_count, 1u);
}

TEST_F(CoreTest, CompactionGarbageCollectsOrphanBlobsKeepsReferenced) {
  std::string id_a = clipd::content_id(Kind::Image, "AAAA");
  std::string id_b = clipd::content_id(Kind::Image, "BBBB");
  Core core(path_, /*max_entries=*/1, kNoAutoCompact);  // cap 1 forces eviction
  core.start();
  add_image(core, "AAAA", 1, 1, ImageFormat::Png, 1);
  add_image(core, "BBBB", 1, 1, ImageFormat::Png, 2);  // evicts A from the store

  // A is evicted from the live set but its blob is still on disk pre-GC.
  EXPECT_TRUE(core.read_blob(id_a).has_value());
  core.compact();  // GC runs only after the new log is durably renamed
  EXPECT_FALSE(core.read_blob(id_a).has_value());  // orphan collected
  EXPECT_TRUE(core.read_blob(id_b).has_value());   // referenced blob kept
}

TEST_F(CoreTest, ByteBudgetEvictionIsReproducedOnReplay) {
  {
    Core core(path_, /*max_entries=*/0, kNoAutoCompact, /*max_bytes=*/10);
    core.start();
    core.add("aaaaa", 1);  // 5 bytes
    core.add("bbbbb", 2);  // 5 -> total 10
    core.add("ccccc", 3);  // 5 -> 15 > 10 -> evict "aaaaa"
  }
  Core reopened(path_, 0, kNoAutoCompact, /*max_bytes=*/10);
  reopened.start();
  EXPECT_FALSE(contains(reopened, "aaaaa", 10));
  EXPECT_TRUE(contains(reopened, "bbbbb", 10));
  EXPECT_TRUE(contains(reopened, "ccccc", 10));
}

TEST_F(CoreTest, LegacyLogMigratesToV1OnStart) {
  write_v0_log({{1, "old1"}, {2, "old2"}});
  {
    Core core(path_, 100, kNoAutoCompact);
    core.start();
    EXPECT_TRUE(contains(core, "old1", 10));
    EXPECT_TRUE(contains(core, "old2", 10));
  }
  // Migration rewrote the log in v1 format, so it now carries the header and a
  // reopen replays cleanly.
  EXPECT_EQ(first_bytes(4), "CLPD");
  Core reopened(path_, 100, kNoAutoCompact);
  reopened.start();
  EXPECT_TRUE(contains(reopened, "old1", 10));
  EXPECT_TRUE(contains(reopened, "old2", 10));
}

TEST_F(CoreTest, PerImageCapSkipsOversizeImages) {
  Core core(path_, 100, kNoAutoCompact, /*max_bytes=*/0, /*max_blob_bytes=*/10);
  core.start();
  add_image(core, "0123456789AB", 1, 1, ImageFormat::Png, 1);  // 12 bytes > cap
  add_image(core, "small", 1, 1, ImageFormat::Png, 2);          // 5 bytes <= cap
  EXPECT_EQ(core.stats().entry_count, 1u);
  EXPECT_FALSE(core.read_blob(clipd::content_id(Kind::Image, "0123456789AB"))
                   .has_value());
  EXPECT_TRUE(
      core.read_blob(clipd::content_id(Kind::Image, "small")).has_value());
}

// --- Pinned / delete / clear ------------------------------------------------

TEST_F(CoreTest, SetPinnedPersistsAcrossRestart) {
  std::string id = clipd::content_id(Kind::Text, "fav");
  {
    Core core(path_, 100, kNoAutoCompact);
    core.start();
    core.add("fav", 1);
    core.set_pinned(id, true);
    auto f = find_by_id(core, id, 10);
    ASSERT_TRUE(f.has_value());
    EXPECT_TRUE(f->entry.pinned);
  }
  Core reopened(path_, 100, kNoAutoCompact);
  reopened.start();
  auto f = find_by_id(reopened, id, 10);
  ASSERT_TRUE(f.has_value());
  EXPECT_TRUE(f->entry.pinned);  // PIN record replayed
}

// The interleaving guarantee: PIN must be applied at its log position, before
// the later adds that would otherwise evict the entry. If replay batched all
// adds before controls, "keep" would be evicted before being pinned.
TEST_F(CoreTest, PinnedSurvivesEvictionPressureAcrossRestart) {
  std::string pid = clipd::content_id(Kind::Text, "keep");
  {
    Core core(path_, /*max_entries=*/3, kNoAutoCompact);
    core.start();
    core.add("keep", 1);
    core.set_pinned(pid, true);
    for (int i = 0; i < 10; ++i) core.add("u" + std::to_string(i), 10 + i);
  }
  Core reopened(path_, 3, kNoAutoCompact);
  reopened.start();
  auto f = find_by_id(reopened, pid, 100);
  ASSERT_TRUE(f.has_value());
  EXPECT_TRUE(f->entry.pinned);
}

TEST_F(CoreTest, LaterPinUnpinWinsAcrossRestart) {
  std::string id = clipd::content_id(Kind::Text, "x");
  {
    Core core(path_, 100, kNoAutoCompact);
    core.start();
    core.add("x", 1);
    core.set_pinned(id, true);
    core.set_pinned(id, false);  // later UNPIN wins
  }
  Core reopened(path_, 100, kNoAutoCompact);
  reopened.start();
  auto f = find_by_id(reopened, id, 10);
  ASSERT_TRUE(f.has_value());
  EXPECT_FALSE(f->entry.pinned);
}

TEST_F(CoreTest, DeletePersistsAcrossRestart) {
  std::string id = clipd::content_id(Kind::Text, "doomed");
  {
    Core core(path_, 100, kNoAutoCompact);
    core.start();
    core.add("doomed", 1);
    core.add("survivor", 2);
    core.remove(id);
    EXPECT_FALSE(contains(core, "doomed", 10));
  }
  Core reopened(path_, 100, kNoAutoCompact);
  reopened.start();
  EXPECT_FALSE(contains(reopened, "doomed", 10));  // TOMBSTONE replayed
  EXPECT_TRUE(contains(reopened, "survivor", 10));
}

TEST_F(CoreTest, DeletedEntryNotResurrectedAfterCompaction) {
  std::string id = clipd::content_id(Kind::Text, "doomed");
  Core core(path_, 100, kNoAutoCompact);
  core.start();
  core.add("doomed", 1);
  core.add("survivor", 2);
  core.remove(id);
  core.compact();  // tombstone + dead record both dropped from the compacted log
  EXPECT_FALSE(contains(core, "doomed", 10));
  Core reopened(path_, 100, kNoAutoCompact);
  reopened.start();
  EXPECT_FALSE(contains(reopened, "doomed", 10));
  EXPECT_TRUE(contains(reopened, "survivor", 10));
}

// The orphan-blob handoff: remove() leaves an image's blob on disk; the next
// compaction's existing GC reclaims it (no targeted delete on remove).
TEST_F(CoreTest, DeletedImageBlobReclaimedAtNextCompaction) {
  std::string id = clipd::content_id(Kind::Image, "IMGX");
  Core core(path_, 100, kNoAutoCompact);
  core.start();
  add_image(core, "IMGX", 2, 2, ImageFormat::Png, 1);
  core.remove(id);
  EXPECT_TRUE(core.read_blob(id).has_value());   // blob deferred, still on disk
  core.compact();
  EXPECT_FALSE(core.read_blob(id).has_value());  // reclaimed by compaction GC
}

TEST_F(CoreTest, ClearKeepsPinnedAcrossRestart) {
  std::string pid = clipd::content_id(Kind::Text, "fav");
  {
    Core core(path_, 100, kNoAutoCompact);
    core.start();
    core.add("fav", 1);
    core.set_pinned(pid, true);
    core.add("trash1", 2);
    core.add("trash2", 3);
    core.clear();
    EXPECT_TRUE(contains(core, "fav", 10));
    EXPECT_FALSE(contains(core, "trash1", 10));
    EXPECT_FALSE(contains(core, "trash2", 10));
  }
  Core reopened(path_, 100, kNoAutoCompact);
  reopened.start();
  EXPECT_TRUE(contains(reopened, "fav", 10));
  EXPECT_FALSE(contains(reopened, "trash1", 10));
  auto f = find_by_id(reopened, pid, 10);
  ASSERT_TRUE(f.has_value());
  EXPECT_TRUE(f->entry.pinned);  // still pinned after clear + restart
}

TEST_F(CoreTest, ClearThenAddWorks) {
  Core core(path_, 100, kNoAutoCompact);
  core.start();
  core.add("old", 1);
  core.clear();
  core.add("fresh", 2);
  EXPECT_FALSE(contains(core, "old", 10));
  EXPECT_TRUE(contains(core, "fresh", 10));
}

TEST_F(CoreTest, SetPinnedAndDeleteUnknownIdAreNoOps) {
  Core core(path_, 100, kNoAutoCompact);
  core.start();
  core.add("a", 1);
  std::string ghost(64, '0');
  core.set_pinned(ghost, true);  // no entry, no crash
  core.remove(ghost);            // no entry, no crash
  EXPECT_EQ(core.stats().entry_count, 1u);
  EXPECT_TRUE(contains(core, "a", 10));
}

// Pinned-first ordering lives in Core::search's comparator: a pinned entry must
// surface even when recency would otherwise bury it past max_results.
TEST_F(CoreTest, SearchReturnsPinnedMatchesFirst) {
  Core core(path_, 100, kNoAutoCompact);
  core.start();
  std::string oldid = clipd::content_id(Kind::Text, "alpha");
  core.add("alpha", 1);  // oldest
  for (int i = 0; i < 20; ++i) core.add("alpha" + std::to_string(i), 10 + i);
  core.set_pinned(oldid, true);

  auto results = core.search("alpha", 3, 1000);
  ASSERT_FALSE(results.empty());
  EXPECT_EQ(results[0].entry.id, oldid);  // pinned old entry ranks first
  EXPECT_TRUE(results[0].entry.pinned);
}

}  // namespace
