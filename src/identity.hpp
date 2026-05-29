#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

#include "entry.hpp"

namespace clipd {

// The single source of truth for per-entry identity. Both ingest (Core::add_*)
// and replay derive ids through here, so the scheme can never drift between
// write and read paths.
//
// id = sha256(kind_byte ‖ defining content), hex-encoded. The leading kind byte
// is domain separation: a text and a file (or image) with byte-identical content
// get distinct ids. For images the same digest is what the log record stores, so
// replay recovers the id by hex-encoding that stored digest (no rehashing of the
// blob).

std::array<uint8_t, 32> content_digest(Kind kind, const uint8_t* data, size_t len);
std::array<uint8_t, 32> content_digest(Kind kind, std::string_view content);

std::string content_id(Kind kind, std::string_view content);

}  // namespace clipd
