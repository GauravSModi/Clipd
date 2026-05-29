#include "identity.hpp"

#include "sha256.hpp"

namespace clipd {

std::array<uint8_t, 32> content_digest(Kind kind, const uint8_t* data, size_t len) {
  Sha256 ctx;
  const uint8_t kind_byte = static_cast<uint8_t>(kind);
  ctx.update(&kind_byte, 1);
  ctx.update(data, len);
  return ctx.finalize();
}

std::array<uint8_t, 32> content_digest(Kind kind, std::string_view content) {
  return content_digest(kind, reinterpret_cast<const uint8_t*>(content.data()),
                        content.size());
}

std::string content_id(Kind kind, std::string_view content) {
  return to_hex(content_digest(kind, content));
}

}  // namespace clipd
