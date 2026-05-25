#pragma once

#include <cstdint>
#include <string>

namespace clipd {

// A single captured clipboard item.
struct Entry {
  std::string text;
  int64_t timestamp;  // epoch milliseconds
};

}  // namespace clipd
