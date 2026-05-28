// HistoryController — the glue that ties the pasteboard monitor to the store and
// exposes search to the UI. It holds no policy of its own: dedup/scoring/storage
// all live in the core (via Clipboard), and the one serial queue lives in
// Clipboard, so every C call is already serialized.

import Foundation

public final class HistoryController {
    private let clipboard: Clipboard
    private let monitor: PasteboardMonitor
    private let compactThresholdBytes: UInt64
    private let now: () -> Int64

    public init(clipboard: Clipboard,
                monitor: PasteboardMonitor,
                compactThresholdBytes: UInt64,
                now: @escaping () -> Int64 = clipdNowMs) {
        self.clipboard = clipboard
        self.monitor = monitor
        self.compactThresholdBytes = compactThresholdBytes
        self.now = now
        monitor.onCopy = { [weak self] text, timestamp in
            self?.ingest(text, at: timestamp)
        }
    }

    /// Fuzzy-search the history, stamping recency with the current clock.
    /// An empty query returns the most recent entries.
    public func search(_ query: String, maxResults: Int = 50) throws -> [Match] {
        try clipboard.search(query, maxResults: maxResults, now: now())
    }

    private func ingest(_ text: String, at timestamp: Int64) {
        // A failed write leaves the store unchanged (the core makes add atomic);
        // we don't crash the app over one dropped copy.
        do {
            try clipboard.add(text, at: timestamp)
            try compactIfNeeded()
        } catch {
            // Best-effort capture; a dropped copy or skipped compaction is not fatal.
        }
    }

    /// Keep the append-only log bounded during a long-running session. The core
    /// compacts past this threshold at startup; this re-applies the same rule as
    /// the session adds records (the policy lives in the core — we only decide
    /// *when* to ask).
    private func compactIfNeeded() throws {
        if try clipboard.stats().logBytes > compactThresholdBytes {
            try clipboard.compact()
        }
    }
}
