// PasteboardMonitor — watches the pasteboard's change counter and emits new
// copies (text, image, or a file reference). The system pasteboard is abstracted
// behind PasteboardReading so the polling/filtering logic is testable without
// NSPasteboard or a live timer.
//
// Reading the change counter is ~free; reading contents is not — so we only read
// when the counter has moved. Stays thin: detection + the concealed/transient
// security filter only. No dedup/storage (that's the core, via Clipboard).

import Foundation

/// A decoded image lifted off the pasteboard: the raw bytes plus the metadata
/// the core stores (the core never decodes images itself).
public struct ImageCapture: Equatable {
    public let data: Data
    public let width: UInt32
    public let height: UInt32
    public let format: ClipImageFormat

    public init(data: Data, width: UInt32, height: UInt32, format: ClipImageFormat) {
        self.data = data
        self.width = width
        self.height = height
        self.format = format
    }
}

/// What a single pasteboard change yielded.
public enum Capture: Equatable {
    case text(String)
    case image(ImageCapture)
    case file(path: String)
}

/// The slice of NSPasteboard the monitor needs. The real adapter wraps
/// NSPasteboard.general; tests inject a scriptable fake.
public protocol PasteboardReading {
    var changeCount: Int { get }
    /// UTI type identifiers currently on the pasteboard (raw strings).
    var types: [String] { get }
    /// The plain-text content, if any.
    func string() -> String?
    /// Image bytes + metadata, if the pasteboard holds an image.
    func imageCapture() -> ImageCapture?
    /// The path of a copied file, if the pasteboard holds a file URL.
    func fileURLPath() -> String?
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

    /// Called with (capture, epoch-ms timestamp) for each new, non-excluded copy.
    public var onCapture: ((Capture, Int64) -> Void)?

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
    ///
    /// Priority is text → image → file: a copy carrying both text and an image
    /// (e.g. rich text with an inline image) is stored as text, which is the more
    /// searchable representation.
    @discardableResult
    public func poll() -> Bool {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return false }
        lastChangeCount = current

        guard !pasteboard.types.contains(where: Self.excludedTypes.contains) else { return false }

        if let text = pasteboard.string(), !text.isEmpty {
            emit(.text(text))
            return true
        }
        if let image = pasteboard.imageCapture() {
            emit(.image(image))
            return true
        }
        if let path = pasteboard.fileURLPath(), !path.isEmpty {
            emit(.file(path: path))
            return true
        }
        return false
    }

    private func emit(_ capture: Capture) {
        onCapture?(capture, now())
    }
}
