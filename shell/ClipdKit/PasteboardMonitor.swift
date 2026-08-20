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

    /// Bundle ids of apps whose copies we skip by SOURCE, because they don't tag
    /// the pasteboard. Apple's Passwords app copies a password as plain text with
    /// no ConcealedType marker, so the type filter can't catch it; skipping by the
    /// frontmost app at copy time is a best-effort fallback (it has a small timing
    /// race and only covers the apps listed here — it is not security).
    private static let excludedSourceApps: Set<String> = [
        "com.apple.Passwords",        // macOS 15+ Passwords app
        "com.apple.keychainaccess",   // Keychain Access
    ]

    /// Bundle id of the app that was frontmost when a copy happened, used for the
    /// source-app skip above. Injected so it's testable; the app passes an
    /// NSWorkspace-backed closure, the pure layer defaults to nil (no skip).
    private let frontmostBundleID: () -> String?

    /// The pause flag + per-kind filters, read fresh on every poll. A provider
    /// closure (not a stored value or a ClipdSettings reference) so a settings
    /// change takes effect immediately without rebuilding the monitor, and this
    /// class stays pure/testable with a hand-built policy.
    private let policy: () -> CapturePolicy

    /// Called with (capture, epoch-ms timestamp) for each new, non-excluded copy.
    public var onCapture: ((Capture, Int64) -> Void)?

    public init(pasteboard: PasteboardReading,
                now: @escaping () -> Int64 = clipdNowMs,
                policy: @escaping () -> CapturePolicy = { .capturingEverything },
                frontmostBundleID: @escaping () -> String? = { nil }) {
        self.pasteboard = pasteboard
        self.now = now
        self.policy = policy
        self.frontmostBundleID = frontmostBundleID
        // Seed from the current counter so whatever already sits on the pasteboard
        // at launch isn't re-ingested; only copies made afterward are captured.
        self.lastChangeCount = pasteboard.changeCount
    }

    /// One poll tick: if the pasteboard changed, read and (unless excluded) emit.
    /// Returns true iff a copy was emitted. The timer just calls this repeatedly.
    ///
    /// Priority is file → text → image. A copied file must be checked FIRST: a
    /// Finder file copy also puts the filename on the pasteboard as plain text
    /// (and the icon as an image), so a text-first check would store the file as
    /// just its name. Text still beats image so rich text with an inline image is
    /// stored as text (the more searchable representation).
    @discardableResult
    public func poll() -> Bool {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return false }
        lastChangeCount = current

        guard !pasteboard.types.contains(where: Self.excludedTypes.contains) else { return false }

        // Fallback for apps that don't tag concealed copies (notably Apple's
        // Passwords app, which copies a bare plain-text string): skip by source.
        if let bundleID = frontmostBundleID(), Self.excludedSourceApps.contains(bundleID) {
            return false
        }

        // Read fresh so a pause/filter change made in Settings or the status menu
        // takes effect on the very next poll. Checked before reading pasteboard
        // contents (the expensive part) so a paused tick stays cheap.
        let policy = self.policy()
        guard !policy.isPaused else { return false }

        guard let capture = clipdSelectCapture(file: pasteboard.fileURLPath(),
                                               text: pasteboard.string(),
                                               image: pasteboard.imageCapture(),
                                               policy: policy) else { return false }
        emit(capture)
        return true
    }

    private func emit(_ capture: Capture) {
        onCapture?(capture, now())
    }
}
