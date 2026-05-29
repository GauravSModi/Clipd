// The production PasteboardReading backed by the real system pasteboard, plus
// the copy-back writers. This is AppKit glue — the polling/filtering logic it
// feeds is unit-tested against a fake in PasteboardMonitorTests; this adapter
// just adapts NSPasteboard to that protocol.

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

    public func imageCapture() -> ImageCapture? {
        // Prefer PNG (lossless, compact); fall back to TIFF. The core never
        // decodes the bytes, so the shell supplies the pixel dimensions.
        let format: ClipImageFormat
        let data: Data
        if let png = pasteboard.data(forType: .png) {
            data = png
            format = .png
        } else if let tiff = pasteboard.data(forType: .tiff) {
            data = tiff
            format = .tiff
        } else {
            return nil
        }
        let rep = NSBitmapImageRep(data: data)
        let width = UInt32(rep?.pixelsWide ?? 0)
        let height = UInt32(rep?.pixelsHigh ?? 0)
        return ImageCapture(data: data, width: width, height: height, format: format)
    }

    public func fileURLPath() -> String? {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: opts)
                as? [URL], let first = urls.first, first.isFileURL else {
            return nil
        }
        return first.path
    }
}

public enum SystemClipboardWriter {
    /// Place `text` on the system pasteboard so a chosen history entry can be
    /// pasted back.
    public static func write(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Place image `data` back on the pasteboard under its original type, so
    /// paste-back preserves the encoding.
    public static func writeImage(_ data: Data, format: ClipImageFormat,
                                  to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setData(data, forType: format == .tiff ? .tiff : .png)
    }

    /// Place a file reference back on the pasteboard so pasting yields the file.
    public static func writeFile(_ path: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: path) as NSURL])
    }
}
#endif
