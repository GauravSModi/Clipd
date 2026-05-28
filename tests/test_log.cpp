#include "log.hpp"

#include <gtest/gtest.h>

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "entry.hpp"

using clipd::Entry;
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

  void append_raw(const std::string& bytes) {
    std::ofstream f(path_, std::ios::binary | std::ios::app);
    f.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
  }

  uint64_t file_size() const { return fs::file_size(path_); }

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

}  // namespace
