#include "identity.hpp"

#include <gtest/gtest.h>

#include <array>
#include <cstdint>
#include <string>

#include "entry.hpp"
#include "sha256.hpp"

using clipd::content_digest;
using clipd::content_id;
using clipd::Kind;
using clipd::Sha256;
using clipd::to_hex;

namespace {

// The whole point of domain separation: a text and a file with byte-identical
// content must get distinct ids so they don't wrongly dedup-bump each other and
// so feature 2's pin/delete can address each unambiguously.
TEST(Identity, SameContentDifferentKindsDiffer) {
  EXPECT_NE(content_id(Kind::Text, "/Users/me/a.png"),
            content_id(Kind::File, "/Users/me/a.png"));
  EXPECT_NE(content_id(Kind::Text, "/Users/me/a.png"),
            content_id(Kind::Image, "/Users/me/a.png"));
  EXPECT_NE(content_id(Kind::Image, "/Users/me/a.png"),
            content_id(Kind::File, "/Users/me/a.png"));
}

TEST(Identity, Deterministic) {
  EXPECT_EQ(content_id(Kind::Text, "abc"), content_id(Kind::Text, "abc"));
}

TEST(Identity, IdIsHexOf64Chars) {
  EXPECT_EQ(content_id(Kind::Text, "abc").size(), 64u);
}

// Ties the helper to the exact documented scheme: sha256(kind_byte ‖ content),
// hex-encoded. An image's id is the hex of its domain-separated digest, which is
// the raw digest the log stores for that image record.
TEST(Identity, MatchesManualStreamedDomainSeparation) {
  Sha256 ctx;
  const uint8_t image_kind = 0x01;
  ctx.update(&image_kind, 1);
  ctx.update("PNGDATA");
  std::array<uint8_t, 32> digest = ctx.finalize();

  EXPECT_EQ(content_id(Kind::Image, "PNGDATA"), to_hex(digest));
  EXPECT_EQ(content_digest(Kind::Image,
                           reinterpret_cast<const uint8_t*>("PNGDATA"), 7),
            digest);
}

}  // namespace
