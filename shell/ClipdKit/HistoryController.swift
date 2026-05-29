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
        monitor.onCapture = { [weak self] capture, timestamp in
            self?.ingest(capture, at: timestamp)
        }
    }

    /// Fuzzy-search the history, stamping recency with the current clock.
    /// An empty query returns the most recent entries.
    public func search(_ query: String, maxResults: Int = 50) throws -> [Match] {
        try clipboard.search(query, maxResults: maxResults, now: now())
    }

    /// The bytes of an image entry's blob (for thumbnails / paste-back), or nil.
    public func readBlob(id: String) -> Data? {
        clipboard.readBlob(id: id)
    }

    private func ingest(_ capture: Capture, at timestamp: Int64) {
        // A failed write leaves the store unchanged (the core makes each add
        // atomic); we don't crash the app over one dropped copy.
        do {
            switch capture {
            case .text(let text):
                try clipboard.add(text, at: timestamp)
            case .image(let image):
                try clipboard.addImage(image.data, width: image.width,
                                       height: image.height, format: image.format,
                                       at: timestamp)
            case .file(let path):
                try clipboard.addFile(path, at: timestamp)
            }
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
