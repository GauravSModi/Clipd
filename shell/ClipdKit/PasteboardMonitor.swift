// PasteboardMonitor — watches the pasteboard's change counter and emits new text
// copies. The system pasteboard is abstracted behind PasteboardReading so the
// polling/filtering logic is testable without NSPasteboard or a live timer.
//
// Reading the change counter is ~free; reading contents is not — so we only read
// when the counter has moved. Stays thin: detection + the concealed/transient
// security filter only. No dedup/storage (that's the core, via Clipboard).

import Foundation

/// The slice of NSPasteboard the monitor needs. The real adapter wraps
/// NSPasteboard.general; tests inject a scriptable fake.
public protocol PasteboardReading {
    var changeCount: Int { get }
    /// UTI type identifiers currently on the pasteboard (raw strings).
    var types: [String] { get }
    /// The plain-text content, if any.
    func string() -> String?
}

public final class PasteboardMonitor {
    private let pasteboard: PasteboardReading
    private let now: () -> Int64
    private var lastChangeCount: Int

    /// Pasteboard markers for secrets/throwaway data that must never be stored.
    /// Password managers tag copied secrets ConcealedType; transient data is
    /// marked TransientType. Skipping these is the security floor (the log is
    /// still plaintext — not real security).
    private static let excludedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
    ]

    /// Called with (text, epoch-ms timestamp) for each new, non-excluded copy.
    public var onCopy: ((String, Int64) -> Void)?

    public init(pasteboard: PasteboardReading,
                now: @escaping () -> Int64 = clipdNowMs) {
        self.pasteboard = pasteboard
        self.now = now
        // Seed from the current counter so whatever already sits on the pasteboard
        // at launch isn't re-ingested; only copies made afterward are captured.
        self.lastChangeCount = pasteboard.changeCount
    }

    /// One poll tick: if the pasteboard changed, read and (unless excluded) emit.
    /// Returns true iff a copy was emitted. The timer just calls this repeatedly.
    @discardableResult
    public func poll() -> Bool {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return false }
        lastChangeCount = current

        guard !pasteboard.types.contains(where: Self.excludedTypes.contains) else { return false }
        guard let text = pasteboard.string(), !text.isEmpty else { return false }
        onCopy?(text, now())
        return true
    }
}
