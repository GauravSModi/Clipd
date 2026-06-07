#include "log.hpp"

#include <gtest/gtest.h>

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "crc32.hpp"
#include "entry.hpp"

using clipd::ControlOp;
using clipd::Entry;
using clipd::ImageFormat;
using clipd::Kind;
using clipd::Log;
namespace fs = std::filesystem;

namespace {

class LogTest : public ::testing::Test {
 protected:
  void SetUp() override {
    path_ = fs::temp_directory_path() /
            ("clipd_log_test_" + std::to_string(::testing::UnitTest::GetInstance()
                                                     ->random_seed()) +
             "_" + std::to_string(reinterpret_cast<uintptr_t>(this)));
    fs::remove(path_);
  }
  void TearDown() override { fs::remove(path_); }

  std::vector<Entry> replay_all() {
    std::vector<Entry> out;
    Log log(path_);
    log.replay([&](const Entry& e) { out.push_back(e); });
    return out;
  }

  // Capture control records (pin/unpin/tombstone/clear) in file order.
  std::vector<std::pair<ControlOp, std::string>> replay_controls() {
    std::vector<std::pair<ControlOp, std::string>> out;
    Log log(path_);
    log.replay([](const Entry&) {},
               [&](ControlOp op, const std::string& id) { out.emplace_back(op, id); });
    return out;
  }

  void append_raw(const std::string& bytes) {
    std::ofstream f(path_, std::ios::binary | std::ios::app);
    f.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
  }

  // Encode a legacy v0 record (no file header, no type tag):
  //   [u32 length][u32 crc32][i64 timestamp][text]
  // exactly as Clipd wrote before this feature, so we can prove old logs replay.
  void append_v0_record(int64_t ts, const std::string& text) {
    auto put_u32 = [](std::string& out, uint32_t v) {
      for (int i = 0; i < 4; ++i)
        out.push_back(static_cast<char>((v >> (8 * i)) & 0xFF));
    };
    std::string payload;
    auto u = static_cast<uint64_t>(ts);
    for (int i = 0; i < 8; ++i)
      payload.push_back(static_cast<char>((u >> (8 * i)) & 0xFF));
    payload.append(text);

    std::string record;
    put_u32(record, static_cast<uint32_t>(payload.size()));
    put_u32(record, clipd::crc32(payload));
    record.append(payload);
    append_raw(record);
  }

  uint64_t file_size() const { return fs::file_size(path_); }

  std::string first_bytes(size_t n) const {
    std::ifstream f(path_, std::ios::binary);
    std::string out(n, '\0');
    f.read(out.data(), static_cast<std::streamsize>(n));
    out.resize(static_cast<size_t>(f.gcount()));
    return out;
  }

  fs::path path_;
};

TEST_F(LogTest, AppendAndReplayRoundtrip) {
  {
    Log log(path_);
    log.open();
    log.append({"alpha", 1});
    log.append({"beta", 2});
    log.append({"gamma", 3});
  }
  auto entries = replay_all();
  ASSERT_EQ(entries.size(), 3u);
  EXPECT_EQ(entries[0].text, "alpha");
  EXPECT_EQ(entries[0].timestamp, 1);
  EXPECT_EQ(entries[2].text, "gamma");
  EXPECT_EQ(entries[2].timestamp, 3);
}

TEST_F(LogTest, ReplayEmptyLogYieldsNothing) {
  Log log(path_);
  log.open();
  EXPECT_TRUE(replay_all().empty());
}

TEST_F(LogTest, HandlesEmptyTextPayload) {
  {
    Log log(path_);
    log.open();
    log.append({"", 42});
  }
  auto entries = replay_all();
  ASSERT_EQ(entries.size(), 1u);
  EXPECT_EQ(entries[0].text, "");
  EXPECT_EQ(entries[0].timestamp, 42);
}

TEST_F(LogTest, TornTail_PartialRecordIsTruncated) {
  {
    Log log(path_);
    log.open();
    log.append({"good1", 1});
    log.append({"good2", 2});
  }
  uint64_t valid_size = file_size();
  // Simulate a crash mid-write: a length header promising bytes that aren't
  // there.
  append_raw(std::string("\x20\x00\x00\x00", 4));  // length = 32, no payload
  append_raw("garbage");

  auto entries = replay_all();
  ASSERT_EQ(entries.size(), 2u);
  EXPECT_EQ(entries[1].text, "good2");
  // Torn tail truncated back to the last valid record.
  EXPECT_EQ(file_size(), valid_size);
  // A second replay sees a clean log.
  EXPECT_EQ(replay_all().size(), 2u);
}

TEST_F(LogTest, TornTail_BadCrcIsTruncated) {
  {
    Log log(path_);
    log.open();
    log.append({"keepme", 1});
    log.append({"corruptme", 2});
  }
  uint64_t full = file_size();
  // Flip the final payload byte so the last record's CRC no longer matches.
  {
    std::fstream f(path_, std::ios::binary | std::ios::in | std::ios::out);
    f.seekp(static_cast<std::streamoff>(full) - 1);
    char c = '\x00';
    f.read(&c, 1);
    f.seekp(static_cast<std::streamoff>(full) - 1);
    c = static_cast<char>(c ^ 0xFF);
    f.write(&c, 1);
  }
  auto entries = replay_all();
  ASSERT_EQ(entries.size(), 1u);
  EXPECT_EQ(entries[0].text, "keepme");
  EXPECT_LT(file_size(), full);
}

TEST_F(LogTest, TornTail_LengthOverrunsFileIsTruncated) {
  {
    Log log(path_);
    log.open();
    log.append({"solid", 7});
  }
  uint64_t valid_size = file_size();
  // A header claiming a huge payload that the file cannot contain.
  append_raw(std::string("\xFF\xFF\xFF\x7F", 4));  // length ~2GB
  append_raw(std::string("\x00\x00\x00\x00", 4));  // bogus crc
  append_raw("tiny");

  auto entries = replay_all();
  ASSERT_EQ(entries.size(), 1u);
  EXPECT_EQ(entries[0].text, "solid");
  EXPECT_EQ(file_size(), valid_size);
}

TEST_F(LogTest, CompactionPreservesLiveSetAndShrinks) {
  {
    Log log(path_);
    log.open();
    // Many records, including superseded duplicates.
    for (int i = 0; i < 50; ++i) log.append({"dup", i});
    log.append({"live_a", 100});
    log.append({"live_b", 101});
  }
  uint64_t before = file_size();

  std::vector<Entry> live{{"dup", 49}, {"live_a", 100}, {"live_b", 101}};
  {
    Log log(path_);
    log.compact(live);
  }
  EXPECT_LT(file_size(), before);

  auto entries = replay_all();
  ASSERT_EQ(entries.size(), 3u);
  EXPECT_EQ(entries[0].text, "dup");
  EXPECT_EQ(entries[0].timestamp, 49);
  EXPECT_EQ(entries[1].text, "live_a");
  EXPECT_EQ(entries[2].text, "live_b");
}

TEST_F(LogTest, CompactionResultIsItselfReplayable) {
  {
    Log log(path_);
    log.open();
    log.append({"x", 1});
  }
  {
    Log log(path_);
    log.compact({{"only", 5}});
  }
  // Replay, then append more, then replay again — the compacted file is a
  // normal valid log.
  EXPECT_EQ(replay_all().size(), 1u);
  {
    Log log(path_);
    log.append({"added", 6});
  }
  auto entries = replay_all();
  ASSERT_EQ(entries.size(), 2u);
  EXPECT_EQ(entries[1].text, "added");
}

TEST_F(LogTest, MidStreamCorruptionTruncatesEverythingAfter) {
  uint64_t after_first = 0;
  {
    Log log(path_);
    log.open();
    log.append({"good1", 1});
    after_first = file_size();  // end of the first, fully-valid record
    log.append({"good2", 2});
    log.append({"good3", 3});
  }
  // Corrupt a payload byte of the SECOND record — mid-stream, not the tail. The
  // third record after it stays a perfectly valid record on disk.
  {
    std::fstream f(path_, std::ios::binary | std::ios::in | std::ios::out);
    std::streamoff off = static_cast<std::streamoff>(after_first) + 8;  // good2's first payload byte
    f.seekg(off);
    char c = '\x00';
    f.read(&c, 1);
    f.seekp(off);
    c = static_cast<char>(c ^ 0xFF);
    f.write(&c, 1);
  }
  // Replay stops at the first invalid record and truncates everything past it —
  // good3 is discarded despite being valid, because it lies beyond the torn
  // point. The log must never resurrect data after a break.
  auto entries = replay_all();
  ASSERT_EQ(entries.size(), 1u);
  EXPECT_EQ(entries[0].text, "good1");
  EXPECT_EQ(file_size(), after_first);
  // A second replay sees a clean, single-record log.
  EXPECT_EQ(replay_all().size(), 1u);
}

TEST_F(LogTest, StaleTmpFileDoesNotAffectReplay) {
  {
    Log log(path_);
    log.open();
    log.append({"a", 1});
    log.append({"b", 2});
  }
  // An interrupted earlier compaction could leave a ".tmp" sibling behind.
  fs::path tmp = path_;
  tmp += ".tmp";
  {
    std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
    const std::string junk = "not a valid clipd record";
    f.write(junk.data(), static_cast<std::streamsize>(junk.size()));
  }
  // Replay reads the real log, never the stray ".tmp".
  auto entries = replay_all();
  ASSERT_EQ(entries.size(), 2u);
  EXPECT_EQ(entries[1].text, "b");
  // A fresh compaction overwrites the stale ".tmp" and consumes it via the
  // rename, leaving no leftover.
  {
    Log log(path_);
    log.compact({{"a", 1}, {"b", 2}});
  }
  EXPECT_FALSE(fs::exists(tmp));
  EXPECT_EQ(replay_all().size(), 2u);
}

TEST_F(LogTest, CompactionLeavesNoTmpFile) {
  {
    Log log(path_);
    log.open();
    log.append({"x", 1});
    log.append({"y", 2});
  }
  fs::path tmp = path_;
  tmp += ".tmp";
  {
    Log log(path_);
    log.compact({{"y", 2}});
  }
  // The fsync-then-rename path must consume the temp file, never leave it behind.
  EXPECT_FALSE(fs::exists(tmp));
  auto entries = replay_all();
  ASSERT_EQ(entries.size(), 1u);
  EXPECT_EQ(entries[0].text, "y");
}

TEST_F(LogTest, OpenOnUnwritablePathThrows) {
  // Log lives under a directory that does not exist, so the file cannot be
  // created. open() must surface this, not swallow the failed stream.
  fs::path bad = fs::temp_directory_path() /
                 ("clipd_no_such_dir_" +
                  std::to_string(reinterpret_cast<uintptr_t>(this))) /
                 "log";
  fs::remove_all(bad.parent_path());  // make sure the parent really is absent
  Log log(bad);
  EXPECT_THROW(log.open(), std::exception);
}

TEST_F(LogTest, AppendOnUnwritablePathThrows) {
  // The directory is gone, so the append stream can't open. A failed write must
  // throw, not be silently dropped.
  fs::path bad = fs::temp_directory_path() /
                 ("clipd_no_such_dir_append_" +
                  std::to_string(reinterpret_cast<uintptr_t>(this))) /
                 "log";
  fs::remove_all(bad.parent_path());
  Log log(bad);
  EXPECT_THROW(log.append({"x", 1}), std::exception);
}

// --- v1 format: header + typed records -------------------------------------

TEST_F(LogTest, OpenWritesV1HeaderToFreshLog) {
  Log log(path_);
  log.open();
  // The file now begins with the "CLPD" magic so future reads know it is v1.
  EXPECT_EQ(first_bytes(4), "CLPD");
  EXPECT_FALSE(log.is_legacy());
}

TEST_F(LogTest, TextRecordRoundTripsWithKind) {
  {
    Log log(path_);
    log.open();
    log.append({"hello", 5});
  }
  auto entries = replay_all();
  ASSERT_EQ(entries.size(), 1u);
  EXPECT_EQ(entries[0].kind, Kind::Text);
  EXPECT_EQ(entries[0].text, "hello");
  EXPECT_EQ(entries[0].timestamp, 5);
}

TEST_F(LogTest, FileRecordRoundTrips) {
  Entry file;
  file.kind = Kind::File;
  file.text = "/Users/me/report.pdf";  // for File, text is the path
  file.timestamp = 9;
  {
    Log log(path_);
    log.open();
    log.append(file);
  }
  auto entries = replay_all();
  ASSERT_EQ(entries.size(), 1u);
  EXPECT_EQ(entries[0].kind, Kind::File);
  EXPECT_EQ(entries[0].text, "/Users/me/report.pdf");
  EXPECT_EQ(entries[0].timestamp, 9);
}

TEST_F(LogTest, ImageRecordRoundTripsMetadata) {
  Entry img;
  img.kind = Kind::Image;
  img.id = std::string(64, 'a');  // a 64-hex-char blob id
  img.timestamp = 42;
  img.byte_size = 123456;
  img.width = 1024;
  img.height = 768;
  img.image_format = ImageFormat::Tiff;
  // text (label) is intentionally left empty — the log stores metadata, not the
  // derived label.
  {
    Log log(path_);
    log.open();
    log.append(img);
  }
  auto entries = replay_all();
  ASSERT_EQ(entries.size(), 1u);
  EXPECT_EQ(entries[0].kind, Kind::Image);
  EXPECT_EQ(entries[0].id, std::string(64, 'a'));
  EXPECT_EQ(entries[0].timestamp, 42);
  EXPECT_EQ(entries[0].byte_size, 123456u);
  EXPECT_EQ(entries[0].width, 1024u);
  EXPECT_EQ(entries[0].height, 768u);
  EXPECT_EQ(entries[0].image_format, ImageFormat::Tiff);
}

TEST_F(LogTest, MixedKindsRoundTripInOrder) {
  Entry img;
  img.kind = Kind::Image;
  img.id = std::string(64, 'b');
  img.timestamp = 2;
  img.byte_size = 99;
  img.width = 10;
  img.height = 20;
  Entry file;
  file.kind = Kind::File;
  file.text = "/tmp/x";
  file.timestamp = 3;
  {
    Log log(path_);
    log.open();
    log.append({"txt", 1});
    log.append(img);
    log.append(file);
  }
  auto entries = replay_all();
  ASSERT_EQ(entries.size(), 3u);
  EXPECT_EQ(entries[0].kind, Kind::Text);
  EXPECT_EQ(entries[1].kind, Kind::Image);
  EXPECT_EQ(entries[1].id, std::string(64, 'b'));
  EXPECT_EQ(entries[2].kind, Kind::File);
  EXPECT_EQ(entries[2].text, "/tmp/x");
}

TEST_F(LogTest, TornTailAfterImageRecordIsTruncated) {
  Entry img;
  img.kind = Kind::Image;
  img.id = std::string(64, 'c');
  img.timestamp = 1;
  img.byte_size = 7;
  img.width = 4;
  img.height = 4;
  {
    Log log(path_);
    log.open();
    log.append({"keep", 1});
    log.append(img);
  }
  uint64_t valid_size = file_size();
  append_raw(std::string("\x40\x00\x00\x00", 4));  // length=64, no payload
  append_raw("junk");

  auto entries = replay_all();
  ASSERT_EQ(entries.size(), 2u);
  EXPECT_EQ(entries[1].kind, Kind::Image);
  EXPECT_EQ(file_size(), valid_size);  // torn tail truncated, header + 2 records kept
}

// --- legacy v0 logs: detection, replay, migration --------------------------

TEST_F(LogTest, LegacyV0LogIsDetected) {
  append_v0_record(1, "old1");
  append_v0_record(2, "old2");
  Log log(path_);
  EXPECT_TRUE(log.is_legacy());
}

TEST_F(LogTest, LegacyV0LogReplaysAsTextEntries) {
  append_v0_record(1, "old1");
  append_v0_record(2, "old2");
  auto entries = replay_all();
  ASSERT_EQ(entries.size(), 2u);
  EXPECT_EQ(entries[0].kind, Kind::Text);
  EXPECT_EQ(entries[0].text, "old1");
  EXPECT_EQ(entries[0].timestamp, 1);
  EXPECT_EQ(entries[1].text, "old2");
}

TEST_F(LogTest, LegacyV0TornTailStillTruncates) {
  append_v0_record(1, "good");
  uint64_t valid_size = file_size();
  append_raw(std::string("\x20\x00\x00\x00", 4));  // length=32, no payload
  append_raw("garbage");
  auto entries = replay_all();
  ASSERT_EQ(entries.size(), 1u);
  EXPECT_EQ(entries[0].text, "good");
  EXPECT_EQ(file_size(), valid_size);
}

TEST_F(LogTest, CompactWritesV1Header) {
  {
    Log log(path_);
    log.open();
    log.append({"x", 1});
  }
  {
    Log log(path_);
    log.compact({{"only", 5}});
  }
  EXPECT_EQ(first_bytes(4), "CLPD");
  Log log(path_);
  EXPECT_FALSE(log.is_legacy());
}

TEST_F(LogTest, CompactingALegacyLogMigratesItToV1) {
  // The migration building block: a v0 log can be rewritten to v1 by compacting
  // its replayed contents, after which it is no longer legacy and replays.
  append_v0_record(1, "old1");
  append_v0_record(2, "old2");

  std::vector<Entry> live;
  {
    Log log(path_);
    log.replay([&](const Entry& e) { live.push_back(e); });
  }
  {
    Log log(path_);
    log.compact(live);
  }
  EXPECT_EQ(first_bytes(4), "CLPD");
  Log log(path_);
  EXPECT_FALSE(log.is_legacy());
  auto entries = replay_all();
  ASSERT_EQ(entries.size(), 2u);
  EXPECT_EQ(entries[0].text, "old1");
  EXPECT_EQ(entries[1].text, "old2");
}

// --- v1 control records: pin / unpin / tombstone / clear --------------------

TEST_F(LogTest, ControlRecordsRoundTripInOrder) {
  const std::string id(64, 'a');
  const std::string id2(64, 'b');
  {
    Log log(path_);
    log.open();
    log.append_control(ControlOp::Pin, id);
    log.append_control(ControlOp::Unpin, id);
    log.append_control(ControlOp::Tombstone, id2);
    log.append_control(ControlOp::Clear);
  }
  auto controls = replay_controls();
  ASSERT_EQ(controls.size(), 4u);
  EXPECT_EQ(controls[0].first, ControlOp::Pin);
  EXPECT_EQ(controls[0].second, id);
  EXPECT_EQ(controls[1].first, ControlOp::Unpin);
  EXPECT_EQ(controls[1].second, id);
  EXPECT_EQ(controls[2].first, ControlOp::Tombstone);
  EXPECT_EQ(controls[2].second, id2);
  EXPECT_EQ(controls[3].first, ControlOp::Clear);
  EXPECT_TRUE(controls[3].second.empty());
}

TEST_F(LogTest, PinThenUnpinReplayInFileOrder) {
  const std::string id(64, 'c');
  {
    Log log(path_);
    log.open();
    log.append_control(ControlOp::Pin, id);
    log.append_control(ControlOp::Unpin, id);
  }
  auto controls = replay_controls();
  ASSERT_EQ(controls.size(), 2u);
  EXPECT_EQ(controls[0].first, ControlOp::Pin);   // later record (unpin) wins is
  EXPECT_EQ(controls[1].first, ControlOp::Unpin);  // a store concern; here just order
}

TEST_F(LogTest, ContentAndControlReplayInterleavedInOrder) {
  const std::string id(64, 'd');
  {
    Log log(path_);
    log.open();
    log.append({"alpha", 1});
    log.append_control(ControlOp::Pin, id);
    log.append({"beta", 2});
  }
  // The live set is re-derived chronologically only if content and control
  // records are yielded strictly in file order, not batched.
  std::vector<std::string> seq;
  Log log(path_);
  log.replay([&](const Entry& e) { seq.push_back("e:" + e.text); },
             [&](ControlOp, const std::string&) { seq.push_back("c"); });
  ASSERT_EQ(seq.size(), 3u);
  EXPECT_EQ(seq[0], "e:alpha");
  EXPECT_EQ(seq[1], "c");
  EXPECT_EQ(seq[2], "e:beta");
}

TEST_F(LogTest, TornTailAfterControlRecordIsTruncated) {
  const std::string id(64, 'e');
  {
    Log log(path_);
    log.open();
    log.append({"keep", 1});
    log.append_control(ControlOp::Pin, id);
  }
  uint64_t valid_size = file_size();
  append_raw(std::string("\x40\x00\x00\x00", 4));  // length=64, no payload
  append_raw("junk");

  auto controls = replay_controls();
  ASSERT_EQ(controls.size(), 1u);                 // the valid PIN survives
  EXPECT_EQ(controls[0].first, ControlOp::Pin);
  EXPECT_EQ(file_size(), valid_size);             // torn tail truncated
  EXPECT_EQ(replay_all().size(), 1u);             // and the "keep" content too
}

TEST_F(LogTest, CompactionEmitsPinRecordForPinnedEntries) {
  // Pinned state must survive compaction: a pinned entry is written as its
  // content record PLUS a PIN record carrying its id (so replay re-pins it).
  Entry favorite{"fav", 5};
  favorite.id = std::string(64, 'f');  // compact emits PIN with this id
  favorite.pinned = true;
  Entry plain{"plain", 6};
  {
    Log log(path_);
    log.compact({favorite, plain});
  }
  auto entries = replay_all();
  ASSERT_EQ(entries.size(), 2u);  // both content records present

  auto controls = replay_controls();
  ASSERT_EQ(controls.size(), 1u);  // exactly one PIN, for the pinned entry
  EXPECT_EQ(controls[0].first, ControlOp::Pin);
  EXPECT_EQ(controls[0].second, std::string(64, 'f'));
}

}  // namespace
