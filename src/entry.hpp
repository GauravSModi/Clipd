#pragma once

#include <cstdint>
#include <string>

namespace clipd {

// What a captured entry holds. Text is stored inline; an image's bytes live in
// the content-addressed blob store (the entry keeps only metadata + the blob id);
// a file is captured by reference (its path string), never by copying contents.
enum class Kind : uint8_t { Text = 0, Image = 1, File = 2 };

// Image encoding, so paste-back can write the right pasteboard type.
enum class ImageFormat : uint8_t { Png = 0, Tiff = 1 };

// A single captured clipboard item.
//
// `text` and `timestamp` stay the first two members so existing aggregate
// initializations (`Entry{"abc", 1}`) keep compiling; the rest carry the
// multi-kind metadata and default to a text entry.
struct Entry {
  std::string text;             // Text: the content; File: the path; Image: a
                                // synthesized label (e.g. "image 1024x768 png").
  int64_t timestamp = 0;        // epoch milliseconds
  Kind kind = Kind::Text;
  std::string id;               // sha256-hex of (kind byte ‖ defining content):
                                // dedup key + stable identity; for images, also
                                // the blob filename.
  uint64_t byte_size = 0;       // cost for byte-budget eviction (blob size for
                                // images; text/path length otherwise).
  uint32_t width = 0;           // image pixel dimensions (0 for non-image)
  uint32_t height = 0;
  ImageFormat image_format = ImageFormat::Png;
  bool pinned = false;          // favorite: exempt from eviction; persisted via
                                // PIN/UNPIN log records, never evicted while set.
};

}  // namespace clipd
