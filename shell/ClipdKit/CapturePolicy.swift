// CapturePolicy — a pure pause flag + per-kind allow flags, plus the pure decision
// function that turns a raw pasteboard reading into a Capture or nil. No pasteboard,
// no timer, no UserDefaults: PasteboardMonitor consults it via an injected provider,
// and ClipdSettings assembles one from the user's stored preferences.
//
// A capture filter is a CAPTURE control, not a privacy guarantee: it stops new
// copies being recorded, it does not remove anything already stored, and the store
// is still local plaintext (see CLAUDE.md "Known limitations").

import Foundation

/// Whether capture is paused, and which kinds are allowed through when it isn't.
public struct CapturePolicy: Equatable {
    public var isPaused: Bool
    public var allowsText: Bool
    public var allowsImage: Bool
    public var allowsFile: Bool

    public init(isPaused: Bool, allowsText: Bool, allowsImage: Bool, allowsFile: Bool) {
        self.isPaused = isPaused
        self.allowsText = allowsText
        self.allowsImage = allowsImage
        self.allowsFile = allowsFile
    }

    /// The default when no policy is injected: capture everything, paused or not.
    public static let capturingEverything = CapturePolicy(
        isPaused: false, allowsText: true, allowsImage: true, allowsFile: true)

    public func allows(_ kind: ClipKind) -> Bool {
        switch kind {
        case .text: return allowsText
        case .image: return allowsImage
        case .file: return allowsFile
        }
    }
}

/// Decide what a single pasteboard change should yield, given raw readings and a
/// policy. Priority is file → text → image (unchanged from before capture gates
/// existed — see PasteboardMonitor.poll()'s doc comment for why). The policy is
/// applied to the WINNER of that contest: a disallowed winner skips the copy
/// entirely rather than falling through to the next representation, so e.g.
/// disabling "files" means a Finder copy records nothing, not its filename.
public func clipdSelectCapture(file: String?, text: String?, image: ImageCapture?,
                               policy: CapturePolicy) -> Capture? {
    guard !policy.isPaused else { return nil }

    if let file, !file.isEmpty {
        return policy.allows(.file) ? .file(path: file) : nil
    }
    if let text, !text.isEmpty {
        return policy.allows(.text) ? .text(text) : nil
    }
    if let image {
        return policy.allows(.image) ? .image(image) : nil
    }
    return nil
}
