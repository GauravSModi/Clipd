#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

namespace clipd {

// SHA-256 (FIPS 180-4). Hand-rolled and dependency-free, mirroring crc32.{hpp,cpp}
// so the core stays portable (no CommonCrypto / OpenSSL). CRC32 guards record
// framing against torn writes; SHA-256 provides collision-resistant content
// identity and blob addressing — two different jobs.
//
// Streaming API so callers can hash a one-byte kind prefix followed by a
// multi-megabyte payload without copying it into one buffer (domain separation
// for the per-entry id).
class Sha256 {
 public:
  Sha256();

  void update(const uint8_t* data, size_t len);
  void update(std::string_view data);

  // Pad, append the length, and emit the 32-byte digest. Single-use: the
  // context must not be updated again after finalize().
  std::array<uint8_t, 32> finalize();

 private:
  void process_block(const uint8_t* block);

  std::array<uint32_t, 8> state_;
  std::array<uint8_t, 64> buffer_;
  size_t buffer_len_ = 0;
  uint64_t total_len_ = 0;
};

// One-shot helpers.
std::array<uint8_t, 32> sha256(const uint8_t* data, size_t len);
std::array<uint8_t, 32> sha256(std::string_view data);

// Lowercase hex of a 32-byte digest (64 chars).
std::string to_hex(const std::array<uint8_t, 32>& digest);

// Convenience: to_hex(sha256(data)).
std::string sha256_hex(std::string_view data);

}  // namespace clipd
