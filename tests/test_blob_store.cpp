#include "blob_store.hpp"

#include <gtest/gtest.h>

#include <filesystem>
#include <optional>
#include <string>
#include <unordered_set>

using clipd::BlobStore;
namespace fs = std::filesystem;

namespace {

// A syntactically valid 64-char lowercase-hex blob id seeded from one char.
std::string hex_id(char seed) { return std::string(64, seed); }

class BlobStoreTest : public ::testing::Test {
 protected:
  void SetUp() override {
    dir_ = fs::temp_directory_path() /
           ("clipd_blob_test_" + std::to_string(reinterpret_cast<uintptr_t>(this)));
    fs::remove_all(dir_);
  }
  void TearDown() override { fs::remove_all(dir_); }

  void put(BlobStore& s, const std::string& id, const std::string& bytes) {
    s.put(id, reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size());
  }

  fs::path dir_;
};

TEST_F(BlobStoreTest, PutThenGetRoundTrips) {
  BlobStore s(dir_);
  s.open();
  // Binary payload with an embedded NUL and high bytes must survive intact.
  std::string bytes("\x00\x01\xff\x80PNG", 7);
  put(s, hex_id('a'), bytes);
  auto got = s.get(hex_id('a'));
  ASSERT_TRUE(got.has_value());
  EXPECT_EQ(*got, bytes);
}

TEST_F(BlobStoreTest, ExistsReflectsPut) {
  BlobStore s(dir_);
  s.open();
  EXPECT_FALSE(s.exists(hex_id('a')));
  put(s, hex_id('a'), "data");
  EXPECT_TRUE(s.exists(hex_id('a')));
}

TEST_F(BlobStoreTest, GetMissingReturnsEmpty) {
  BlobStore s(dir_);
  s.open();
  EXPECT_FALSE(s.get(hex_id('z')).has_value());
}

TEST_F(BlobStoreTest, PutIsWriteOnceContentAddressed) {
  BlobStore s(dir_);
  s.open();
  put(s, hex_id('a'), "first");
  put(s, hex_id('a'), "second");  // same id: already present, must be a no-op
  auto got = s.get(hex_id('a'));
  ASSERT_TRUE(got.has_value());
  EXPECT_EQ(*got, "first");
}

TEST_F(BlobStoreTest, PersistsAcrossInstances) {
  {
    BlobStore s(dir_);
    s.open();
    put(s, hex_id('a'), "durable");
  }
  BlobStore reopened(dir_);
  auto got = reopened.get(hex_id('a'));
  ASSERT_TRUE(got.has_value());
  EXPECT_EQ(*got, "durable");
}

TEST_F(BlobStoreTest, GcDeletesUnreferencedKeepsReferenced) {
  BlobStore s(dir_);
  s.open();
  put(s, hex_id('a'), "A");
  put(s, hex_id('b'), "B");
  put(s, hex_id('c'), "C");

  std::unordered_set<std::string> live{hex_id('a'), hex_id('c')};
  s.gc(live);

  EXPECT_TRUE(s.exists(hex_id('a')));
  EXPECT_FALSE(s.exists(hex_id('b')));  // unreferenced -> collected
  EXPECT_TRUE(s.exists(hex_id('c')));
}

TEST_F(BlobStoreTest, RejectsNonHexIdForReads) {
  BlobStore s(dir_);
  s.open();
  // Path-traversal / malformed ids (the read id may come from outside via the C
  // API) must never escape the blob directory.
  EXPECT_FALSE(s.exists("../escape"));
  EXPECT_FALSE(s.get("../escape").has_value());
  EXPECT_FALSE(s.get("not-hex").has_value());
  EXPECT_FALSE(s.get(std::string(63, 'a')).has_value());  // wrong length
}

}  // namespace
