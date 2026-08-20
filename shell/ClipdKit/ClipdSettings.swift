// ClipdSettings — the app's typed settings store. Explicit defaults, write-through
// persistence to UserDefaults, and a change signal, so every settings surface reads
// one table instead of scattering `UserDefaults.standard` calls around the shell.
//
// Pure and UI-free like the other kit helpers (ContentType/SelectionIndex/
// PasteAction): Combine is Foundation-level, so this stays testable without AppKit.
// The store holds no history logic — it only remembers numbers and flags.
//
// The global hotkey is deliberately NOT here: KeyboardShortcuts owns its own
// persistence, and ClipdKit does not depend on that package (it is a dependency of
// the Clipd app target only).

import Combine
import Foundation

public final class ClipdSettings: ObservableObject {
    /// The app-wide store, on the standard suite — the same domain KeyboardShortcuts
    /// writes the hotkey to, so all of Clipd's preferences live in one place.
    public static let shared = ClipdSettings()

    // MARK: - Defaults
    //
    // The single default table. These were AppDelegate's private constants before
    // the settings store existed; the app now builds its core from these values.

    public static let defaultMaxEntries = 10_000
    /// Total live byte budget. Images are MB-scale, so an unbounded budget would
    /// let a few large copies fill the disk.
    public static let defaultMaxBytes: UInt64 = 256 * 1024 * 1024        // 256 MB
    /// Per-image cap, so a single huge TIFF can't dominate the whole budget.
    public static let defaultMaxBlobBytes: UInt64 = 50 * 1024 * 1024     // 50 MB
    /// Log size above which the core compacts.
    public static let defaultCompactThresholdBytes: UInt64 = 4 * 1024 * 1024  // 4 MB

    private enum Key {
        static let maxEntries = "clipd.maxEntries"
        static let maxBytes = "clipd.maxBytes"
        static let maxBlobBytes = "clipd.maxBlobBytes"
        static let compactThresholdBytes = "clipd.compactThresholdBytes"
        // Pre-existing first-run bookkeeping. These two key strings are verbatim
        // what AppDelegate wrote before this store existed — changing them would
        // re-show the first-run prompts on every upgraded install.
        static let didPromptLaunchAtLogin = "didPromptLaunchAtLogin"
        static let didRequestAccessibility = "didRequestAccessibility"
        static let captureIsPaused = "clipd.captureIsPaused"
        static let capturesText = "clipd.capturesText"
        static let capturesImages = "clipd.capturesImages"
        static let capturesFiles = "clipd.capturesFiles"
    }

    private let defaults: UserDefaults

    // MARK: - Values
    //
    // Assignments in init() do not fire didSet, so constructing a store never
    // writes the defaults back out; only a real change persists.

    @Published public var maxEntries: Int {
        didSet { defaults.set(maxEntries, forKey: Key.maxEntries) }
    }

    @Published public var maxBytes: UInt64 {
        didSet { defaults.set(Int(clamping: maxBytes), forKey: Key.maxBytes) }
    }

    @Published public var maxBlobBytes: UInt64 {
        didSet { defaults.set(Int(clamping: maxBlobBytes), forKey: Key.maxBlobBytes) }
    }

    @Published public var compactThresholdBytes: UInt64 {
        didSet {
            defaults.set(Int(clamping: compactThresholdBytes),
                         forKey: Key.compactThresholdBytes)
        }
    }

    /// Set once the first-launch "Launch at Login?" offer has been shown.
    @Published public var didPromptLaunchAtLogin: Bool {
        didSet { defaults.set(didPromptLaunchAtLogin, forKey: Key.didPromptLaunchAtLogin) }
    }

    /// Set once the one-time Accessibility permission prompt (for paste-back) has
    /// been raised. Tracked separately so it also fires for installs that predate
    /// paste-back.
    @Published public var didRequestAccessibility: Bool {
        didSet { defaults.set(didRequestAccessibility, forKey: Key.didRequestAccessibility) }
    }

    /// Whether clipboard capture is paused. Persisted (not session-only): it has a
    /// Settings checkbox, so it IS a setting, and silently resuming capture on the
    /// next launch would be a bad surprise for a privacy-framed app.
    @Published public var captureIsPaused: Bool {
        didSet { defaults.set(captureIsPaused, forKey: Key.captureIsPaused) }
    }

    /// Per-kind capture filters. A capture filter is a CAPTURE control, not a
    /// privacy guarantee — it stops new copies being recorded; it does not remove
    /// anything already stored, and the store is still local plaintext.
    @Published public var capturesText: Bool {
        didSet { defaults.set(capturesText, forKey: Key.capturesText) }
    }
    @Published public var capturesImages: Bool {
        didSet { defaults.set(capturesImages, forKey: Key.capturesImages) }
    }
    @Published public var capturesFiles: Bool {
        didSet { defaults.set(capturesFiles, forKey: Key.capturesFiles) }
    }

    /// `defaults` is injectable so tests run against a throwaway suite instead of
    /// the user's real preferences.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        maxEntries = Self.positiveInt(defaults, Key.maxEntries,
                                      default: Self.defaultMaxEntries)
        maxBytes = Self.byteCount(defaults, Key.maxBytes,
                                  default: Self.defaultMaxBytes)
        maxBlobBytes = Self.byteCount(defaults, Key.maxBlobBytes,
                                      default: Self.defaultMaxBlobBytes)
        compactThresholdBytes = Self.byteCount(defaults, Key.compactThresholdBytes,
                                               default: Self.defaultCompactThresholdBytes)
        didPromptLaunchAtLogin = defaults.object(forKey: Key.didPromptLaunchAtLogin) as? Bool ?? false
        didRequestAccessibility = defaults.object(forKey: Key.didRequestAccessibility) as? Bool ?? false
        captureIsPaused = defaults.object(forKey: Key.captureIsPaused) as? Bool ?? false
        capturesText = defaults.object(forKey: Key.capturesText) as? Bool ?? true
        capturesImages = defaults.object(forKey: Key.capturesImages) as? Bool ?? true
        capturesFiles = defaults.object(forKey: Key.capturesFiles) as? Bool ?? true
    }

    /// The CapturePolicy PasteboardMonitor should apply right now, assembled from
    /// the four properties above — the one thing the app hands to the monitor.
    public var capturePolicy: CapturePolicy {
        CapturePolicy(isPaused: captureIsPaused, allowsText: capturesText,
                     allowsImage: capturesImages, allowsFile: capturesFiles)
    }

    // MARK: - Reads
    //
    // `defaults.integer(forKey:)` returns 0 for an absent key, which is
    // indistinguishable from a stored 0 — so both helpers check for the object
    // first and fall back to the documented default when it is missing or absurd.
    // This is input validation against a corrupt plist, not storage policy: the
    // caps themselves are enforced by the C++ ClipStore.

    /// A count that must be at least 1 — a zero-entry history is never a useful
    /// configuration, so 0 (and anything negative) falls back.
    private static func positiveInt(_ defaults: UserDefaults, _ key: String,
                                    default fallback: Int) -> Int {
        guard let stored = defaults.object(forKey: key) as? Int, stored > 0 else {
            return fallback
        }
        return stored
    }

    /// A byte count where **0 is meaningful** and must survive: clipd.h documents
    /// max_bytes 0 as unbounded and max_blob_bytes 0 as no per-image limit. Only a
    /// negative (impossible through the UI, so: corrupt plist) falls back.
    private static func byteCount(_ defaults: UserDefaults, _ key: String,
                                  default fallback: UInt64) -> UInt64 {
        guard let stored = defaults.object(forKey: key) as? Int, stored >= 0 else {
            return fallback
        }
        return UInt64(stored)
    }
}
