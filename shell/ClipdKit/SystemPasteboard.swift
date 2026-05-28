// The production PasteboardReading backed by the real system pasteboard, plus
// the copy-back writer. This is trivial AppKit glue — the polling/filtering
// logic it feeds is unit-tested against a fake in PasteboardMonitorTests; this
// adapter just adapts NSPasteboard to that protocol.

#if canImport(AppKit)
import AppKit

public struct SystemPasteboard: PasteboardReading {
    private let pasteboard: NSPasteboard

    public init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }
    public var types: [String] { (pasteboard.types ?? []).map(\.rawValue) }
    public func string() -> String? { pasteboard.string(forType: .string) }
}

public enum SystemClipboardWriter {
    /// Place `text` on the system pasteboard — used to copy a chosen history
    /// entry back so the user can paste it.
    public static func write(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
#endif
