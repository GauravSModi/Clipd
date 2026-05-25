#pragma once

#include <cstddef>
#include <cstdint>
#include <string_view>

namespace clipd {

// Standard IEEE CRC32 (reflected, polynomial 0xEDB88320), table-based.
uint32_t crc32(const uint8_t* data, size_t len);

// Convenience overload for byte-like contiguous views.
uint32_t crc32(std::string_view data);

}  // namespace clipd
