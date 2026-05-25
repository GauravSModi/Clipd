#include "crc32.hpp"

#include <gtest/gtest.h>

using clipd::crc32;

TEST(Crc32, KnownCheckVector) {
  // The canonical CRC32 check value for the ASCII string "123456789".
  EXPECT_EQ(crc32("123456789"), 0xCBF43926u);
}

TEST(Crc32, EmptyInputIsZero) {
  EXPECT_EQ(crc32(""), 0x00000000u);
}

TEST(Crc32, SingleByte) {
  // CRC32 of a single 'a' (0x61).
  EXPECT_EQ(crc32("a"), 0xE8B7BE43u);
}

TEST(Crc32, DiffersForDifferentInput) {
  EXPECT_NE(crc32("hello"), crc32("world"));
}

TEST(Crc32, EmbeddedNulIsHashed) {
  // Verify length is honored, not treated as a C string.
  const uint8_t with_nul[] = {'a', 0x00, 'b'};
  EXPECT_NE(crc32(reinterpret_cast<const uint8_t*>("a"), 1),
            crc32(with_nul, sizeof(with_nul)));
}
