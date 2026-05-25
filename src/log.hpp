#pragma once

#include <cstdint>
#include <filesystem>
#include <functional>
#include <vector>

#include "entry.hpp"

namespace clipd {

// Crash-safe append-only log of clipboard entries.
//
// On-disk record format (all integers little-endian):
//   [uint32 length][uint32 crc32][payload]
// where payload = [int64 timestamp][text bytes], length = payload byte count,
// and crc32 is computed over the payload.
//
// Crash safety:
//  - replay() validates each record by length and CRC. The first record that
//    fails (short read, length overrun, or CRC mismatch) marks the torn tail;
//    the file is truncated to the last fully-valid record, leaving a clean log.
//  - compact() rewrites the log to a temp file then atomically renames it over
//    the original, so a crash leaves either the old or the new complete log,
//    never a corrupt in-between.
//
// Order contract: append() writes chronologically; replay() yields entries in
// file order (oldest-first). compact() writes the supplied vector in order, so
// callers pass entries oldest-first to preserve replay order.
//
// Not thread-safe: access is serialized by the caller.
class Log {
 public:
  explicit Log(std::filesystem::path path);

  // Ensure the log file exists (creates an empty one if missing).
  void open();

  // Append one record for `e`.
  void append(const Entry& e);

  // Replay valid records in file order, truncating any torn tail in place.
  void replay(const std::function<void(const Entry&)>& on_entry);

  // Rewrite the log to contain exactly `live`, atomically replacing the file.
  void compact(const std::vector<Entry>& live);

  uint64_t size_bytes() const;

 private:
  std::filesystem::path path_;
};

}  // namespace clipd
