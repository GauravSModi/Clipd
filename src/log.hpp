#pragma once

#include <cstdint>
#include <filesystem>
#include <functional>
#include <vector>

#include "entry.hpp"

namespace clipd {

// A control record: a state change keyed on an entry id, not a content entry.
// Pin/Unpin/Tombstone carry the target id; Clear carries none. The record's
// position in the log is its order — control records carry no timestamp and
// never bump recency.
enum class ControlOp : uint8_t { Pin, Unpin, Tombstone, Clear };

// Crash-safe append-only log of clipboard entries.
//
// File layout (v1): a fixed header followed by length-framed records.
//   header  = "CLPD" magic (4 bytes) + uint32 version
//   record  = [uint32 length][uint32 crc32][payload]   (all little-endian)
//   payload = [uint8 type][body], crc32 is over the payload
//     type TEXT  (0): [int64 timestamp][text bytes]
//     type IMAGE (1): [int64 timestamp][uint64 byte_size][uint32 width]
//                     [uint32 height][uint8 image_format][id bytes]  (id = tail)
//     type FILE  (2): [int64 timestamp][path bytes]
// The id is stored as its hex string (the tail of an IMAGE body); a text/file
// entry's id is re-derived from content on replay, so it is not stored.
//
// Migration: logs written before this feature have no header and untagged
// payloads ([int64 timestamp][text]). They are detected (the first 4 bytes are
// not the magic) and replayed with the legacy decoder, every record a TEXT
// entry. Callers migrate such a log to v1 by compacting after replay; an empty
// or sub-header-sized file is treated as fresh and gets a v1 header on open().
//
// Crash safety:
//  - replay() validates each record by length and CRC. The first record that
//    fails marks the torn tail; the file is truncated to the last fully-valid
//    record (never below the header), leaving a clean log.
//  - compact() rewrites the log (header + records) to a temp file then
//    atomically renames it over the original, so a crash leaves either the old
//    or the new complete log, never a corrupt in-between.
//
// Order contract: append() writes chronologically; replay() yields entries in
// file order (oldest-first). compact() writes the supplied vector in order, so
// callers pass entries oldest-first to preserve replay order.
//
// Not thread-safe: access is serialized by the caller.
class Log {
 public:
  explicit Log(std::filesystem::path path);

  // Ensure the log exists and begins with a v1 header. A missing, empty, or
  // sub-header-sized file is (re)initialized with the header; an existing v1 or
  // legacy log is left untouched (a legacy log is migrated later via compact()).
  void open();

  // Append one record for `e`, tagged by its kind.
  void append(const Entry& e);

  // Append one control record (pin/unpin/tombstone keyed on `id`; clear takes
  // no id). State change only — no content, no timestamp.
  void append_control(ControlOp op, const std::string& id = "");

  // Replay valid records in file order (decoding v1 or legacy), truncating any
  // torn tail in place. Content records are yielded to `on_entry` (with kind +
  // on-disk fields; the caller derives id/label for non-image kinds); control
  // records to `on_control` (pin/unpin/tombstone with the target id, clear with
  // an empty id). Both are yielded strictly in file order so the caller can
  // re-derive the live set chronologically.
  void replay(const std::function<void(const Entry&)>& on_entry,
              const std::function<void(ControlOp, const std::string&)>& on_control =
                  {});

  // Rewrite the log to a v1 header plus exactly `live`, atomically replacing the
  // file.
  void compact(const std::vector<Entry>& live);

  // True iff the file exists, is non-empty, and does not begin with the v1 magic
  // — i.e. a pre-feature log that still needs migrating. False for a fresh log
  // after open().
  bool is_legacy() const;

  uint64_t size_bytes() const;

 private:
  std::filesystem::path path_;
};

}  // namespace clipd
