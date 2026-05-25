#include "crc32.hpp"

#include <array>

namespace clipd {
namespace {

// Precompute the 256-entry lookup table for the reflected IEEE polynomial
// 0xEDB88320 at startup.
std::array<uint32_t, 256> make_table() {
  std::array<uint32_t, 256> table{};
  for (uint32_t i = 0; i < 256; ++i) {
    uint32_t c = i;
    for (int k = 0; k < 8; ++k) {
      c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
    }
    table[i] = c;
  }
  return table;
}

const std::array<uint32_t, 256>& table() {
  static const std::array<uint32_t, 256> t = make_table();
  return t;
}

}  // namespace

uint32_t crc32(const uint8_t* data, size_t len) {
  const auto& t = table();
  uint32_t crc = 0xFFFFFFFFu;
  for (size_t i = 0; i < len; ++i) {
    crc = t[(crc ^ data[i]) & 0xFFu] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFFu;
}

uint32_t crc32(std::string_view data) {
  return crc32(reinterpret_cast<const uint8_t*>(data.data()), data.size());
}

}  // namespace clipd
