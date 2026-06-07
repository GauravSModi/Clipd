// ClipdKit — the thin Swift bridge over the C++ clipboard-history core.
//
// `Clipboard` is the only thing that touches the C API. It honors the two
// inviolable contracts from clipd.h:
//   * Threading — a ClipdCore is not thread-safe; every call is serialized onto
//     one private serial queue.
//   * Memory — C++ owns every allocation. After clipd_search (and
//     clipd_read_blob) we copy each field into native Swift values, then hand the
//     block straight back to the matching free function; no C++ pointer outlives
//     the call.

import CClipd
import Foundation

/// What a captured entry holds.
public enum ClipKind: Equatable {
    case text
    case image
    case file
}

/// Image encoding, so paste-back can write the right pasteboard type.
public enum ClipImageFormat: Equatable {
    case png
    case tiff

    /// The ClipdImageFormat value the C API expects.
    var cValue: Int32 { self == .tiff ? Int32(CLIPD_IMAGE_TIFF.rawValue)
                                      : Int32(CLIPD_IMAGE_PNG.rawValue) }
}

/// One search hit, copied fully out of C++ memory.
public struct Match: Equatable {
    public let text: String       // display string: text / path / image label
    public let id: String         // sha256-hex identity; an image's blob key
    public let timestamp: Int64
    public let score: Float
    public let kind: ClipKind
    public let byteSize: UInt64
    public let width: UInt32
    public let height: UInt32
    public let pinned: Bool        // favorite: rendered in the pinned section

    public init(text: String, timestamp: Int64, score: Float, id: String = "",
                kind: ClipKind = .text, byteSize: UInt64 = 0, width: UInt32 = 0,
                height: UInt32 = 0, pinned: Bool = false) {
        self.text = text
        self.id = id
        self.timestamp = timestamp
        self.score = score
        self.kind = kind
        self.byteSize = byteSize
        self.width = width
        self.height = height
        self.pinned = pinned
    }
}

/// Store/log statistics, copied out of the C `ClipdStats`.
public struct Stats: Equatable {
    public let entryCount: Int
    public let logBytes: UInt64
    public let storeBytes: UInt64

    public init(entryCount: Int, logBytes: UInt64, storeBytes: UInt64 = 0) {
        self.entryCount = entryCount
        self.logBytes = logBytes
        self.storeBytes = storeBytes
    }
}

public enum ClipdError: Error {
    case creationFailed
    case addFailed
    case searchFailed
    case statsFailed
    case compactFailed
    case mutationFailed
}

public final class Clipboard {
    private let core: OpaquePointer
    private let queue = DispatchQueue(label: "com.clipd.core")

    /// Open (and replay) the log at `logPath`. `maxBytes` caps the summed live
    /// byte size (0 = unbounded); `maxBlobBytes` rejects a single image larger
    /// than the cap (0 = no per-image limit). Throws if the core can't start.
    public init(logPath: String, maxEntries: Int, compactThresholdBytes: UInt64,
                maxBytes: UInt64 = 0, maxBlobBytes: UInt64 = 0) throws {
        guard let handle = clipd_create(logPath, maxEntries, compactThresholdBytes,
                                        maxBytes, maxBlobBytes) else {
            throw ClipdError.creationFailed
        }
        core = handle
    }

    deinit {
        clipd_destroy(core)
    }

    /// Record a text copy of `text` stamped at `timestampMs` (epoch ms).
    public func add(_ text: String, at timestampMs: Int64) throws {
        try queue.sync {
            if clipd_add(core, text, timestampMs) != 0 {
                throw ClipdError.addFailed
            }
        }
    }

    /// Record an image copy. The bytes are content-addressed into the blob store
    /// (and deduplicated); `width`/`height`/`format` are supplied by the shell.
    public func addImage(_ data: Data, width: UInt32, height: UInt32,
                         format: ClipImageFormat, at timestampMs: Int64) throws {
        try queue.sync {
            let rc = data.withUnsafeBytes { raw -> Int32 in
                clipd_add_image(core, raw.bindMemory(to: UInt8.self).baseAddress,
                                data.count, width, height, format.cValue,
                                timestampMs)
            }
            if rc != 0 { throw ClipdError.addFailed }
        }
    }

    /// Record a file copy by reference (its `path`), not its contents.
    public func addFile(_ path: String, at timestampMs: Int64) throws {
        try queue.sync {
            if clipd_add_file(core, path, timestampMs) != 0 {
                throw ClipdError.addFailed
            }
        }
    }

    /// Pin/unpin the entry `id` (idempotent set-to-bool). A pinned entry is
    /// exempt from eviction and from clear().
    public func setPinned(_ id: String, _ pinned: Bool) throws {
        try queue.sync {
            if clipd_set_pinned(core, id, pinned ? 1 : 0) != 0 {
                throw ClipdError.mutationFailed
            }
        }
    }

    /// Delete the entry `id`. An image's blob is reclaimed at the next compaction.
    public func delete(id: String) throws {
        try queue.sync {
            if clipd_delete(core, id) != 0 { throw ClipdError.mutationFailed }
        }
    }

    /// Clear history, keeping pinned entries (rewrites the log to pinned-only).
    public func clear() throws {
        try queue.sync {
            if clipd_clear(core) != 0 { throw ClipdError.mutationFailed }
        }
    }

    /// Fetch the bytes of the blob `id` (an image Match's id), copied out of C++
    /// memory. Returns nil if the blob is missing.
    public func readBlob(id: String) -> Data? {
        queue.sync {
            var len = 0
            guard let ptr = clipd_read_blob(core, id, &len) else { return nil }
            defer { clipd_free_blob(ptr) }
            return Data(bytes: ptr, count: len)
        }
    }

    /// Fuzzy-search, best-first, scoring recency relative to `nowMs` (epoch ms).
    /// A NULL result is a failure (throws); a no-match search returns [].
    public func search(_ query: String, maxResults: Int, now nowMs: Int64) throws -> [Match] {
        try queue.sync {
            guard let results = clipd_search(core, query, maxResults, nowMs) else {
                throw ClipdError.searchFailed
            }
            defer { clipd_free_results(results) }

            let count = results.pointee.count
            guard count > 0, let matches = results.pointee.matches else { return [] }

            return (0..<count).map { index in
                let match = matches[index]
                let kind: ClipKind
                if match.kind == CLIPD_IMAGE {
                    kind = .image
                } else if match.kind == CLIPD_FILE {
                    kind = .file
                } else {
                    kind = .text
                }
                return Match(text: match.text.map(String.init(cString:)) ?? "",
                             timestamp: match.timestamp,
                             score: match.score,
                             id: match.id.map(String.init(cString:)) ?? "",
                             kind: kind,
                             byteSize: match.byte_size,
                             width: match.width,
                             height: match.height,
                             pinned: match.pinned != 0)
            }
        }
    }

    /// Current live-entry count, on-disk log size, and live byte usage.
    public func stats() throws -> Stats {
        try queue.sync {
            var out = ClipdStats()
            if clipd_stats(core, &out) != 0 {
                throw ClipdError.statsFailed
            }
            return Stats(entryCount: out.entry_count, logBytes: out.log_bytes,
                         storeBytes: out.store_bytes)
        }
    }

    /// Rewrite the log to exactly the live set (drops superseded/evicted records)
    /// and GC blobs no longer referenced.
    public func compact() throws {
        try queue.sync {
            if clipd_compact(core) != 0 {
                throw ClipdError.compactFailed
            }
        }
    }
}
