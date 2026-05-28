// ClipdKit — the thin Swift bridge over the C++ clipboard-history core.
//
// `Clipboard` is the only thing that touches the C API. It honors the two
// inviolable contracts from clipd.h:
//   * Threading — a ClipdCore is not thread-safe; every call is serialized onto
//     one private serial queue.
//   * Memory — C++ owns every allocation. After clipd_search we copy each field
//     into native Swift values, then hand the block straight back to
//     clipd_free_results; no C++ pointer outlives the call.

import CClipd
import Foundation

/// One search hit, copied fully out of C++ memory.
public struct Match: Equatable {
    public let text: String
    public let timestamp: Int64
    public let score: Float

    public init(text: String, timestamp: Int64, score: Float) {
        self.text = text
        self.timestamp = timestamp
        self.score = score
    }
}

/// Store/log statistics, copied out of the C `ClipdStats`.
public struct Stats: Equatable {
    public let entryCount: Int
    public let logBytes: UInt64

    public init(entryCount: Int, logBytes: UInt64) {
        self.entryCount = entryCount
        self.logBytes = logBytes
    }
}

public enum ClipdError: Error {
    case creationFailed
    case addFailed
    case searchFailed
    case statsFailed
    case compactFailed
}

public final class Clipboard {
    private let core: OpaquePointer
    private let queue = DispatchQueue(label: "com.clipd.core")

    /// Open (and replay) the log at `logPath`. Throws if the core can't start
    /// — e.g. an unwritable path or a replay failure (clipd_create returns NULL).
    public init(logPath: String, maxEntries: Int, compactThresholdBytes: UInt64) throws {
        guard let handle = clipd_create(logPath, maxEntries, compactThresholdBytes) else {
            throw ClipdError.creationFailed
        }
        core = handle
    }

    deinit {
        clipd_destroy(core)
    }

    /// Record a copy of `text` stamped at `timestampMs` (epoch ms).
    public func add(_ text: String, at timestampMs: Int64) throws {
        try queue.sync {
            if clipd_add(core, text, timestampMs) != 0 {
                throw ClipdError.addFailed
            }
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
                return Match(text: match.text.map(String.init(cString:)) ?? "",
                             timestamp: match.timestamp,
                             score: match.score)
            }
        }
    }

    /// Current live-entry count and on-disk log size.
    public func stats() throws -> Stats {
        try queue.sync {
            var out = ClipdStats()
            if clipd_stats(core, &out) != 0 {
                throw ClipdError.statsFailed
            }
            return Stats(entryCount: out.entry_count, logBytes: out.log_bytes)
        }
    }

    /// Rewrite the log to exactly the live set (drops superseded/evicted records).
    public func compact() throws {
        try queue.sync {
            if clipd_compact(core) != 0 {
                throw ClipdError.compactFailed
            }
        }
    }
}
