#include "sha256.hpp"

#include <gtest/gtest.h>

#include <array>
#include <cstdint>
#include <string>
#include <string_view>

using clipd::Sha256;
using clipd::sha256;
using clipd::sha256_hex;
using clipd::to_hex;

namespace {

// Known-answer vectors from FIPS 180-4 / standard SHA-256 references.
TEST(Sha256Test, EmptyString) {
  EXPECT_EQ(sha256_hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
}

TEST(Sha256Test, Abc) {
  EXPECT_EQ(sha256_hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

TEST(Sha256Test, MultiBlockMessage) {
  // 56 bytes — crosses into a second 64-byte block with padding.
  EXPECT_EQ(sha256_hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
}

TEST(Sha256Test, LongRepeatedInput) {
  // One million 'a' characters — the classic SHA-256 stress vector.
  std::string million(1000000, 'a');
  EXPECT_EQ(sha256_hex(million),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
}

TEST(Sha256Test, HexDigestIs64LowercaseChars) {
  std::string hex = sha256_hex("anything");
  EXPECT_EQ(hex.size(), 64u);
  for (char c : hex) {
    EXPECT_TRUE((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) << "char: " << c;
  }
}

TEST(Sha256Test, RawDigestMatchesHex) {
  std::array<uint8_t, 32> raw = sha256("abc");
  EXPECT_EQ(to_hex(raw),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

// Streaming in pieces must equal the one-shot — this is exactly how Core does
// domain separation (update one kind byte, then the content) without copying.
TEST(Sha256Test, StreamingInPiecesEqualsOneShot) {
  Sha256 ctx;
  ctx.update("ab");
  ctx.update("c");
  EXPECT_EQ(to_hex(ctx.finalize()),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

TEST(Sha256Test, DomainSeparationPrefixChangesDigest) {
  // A leading kind byte must change the hash, so a text and a file with the
  // same content bytes get distinct ids.
  Sha256 text_ctx;
  const uint8_t text_kind = 0x00;
  text_ctx.update(&text_kind, 1);
  text_ctx.update("/Users/me/a.png");

  Sha256 file_ctx;
  const uint8_t file_kind = 0x02;
  file_ctx.update(&file_kind, 1);
  file_ctx.update("/Users/me/a.png");

  EXPECT_NE(to_hex(text_ctx.finalize()), to_hex(file_ctx.finalize()));
}

}  // namespace
