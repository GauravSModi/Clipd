// Pure content-type classifier for the search panel's per-row affordances. Holds
// no history logic (no dedup/scoring/storage) and never touches the core or store
// — detection only, kept in the UI-free layer so it's testable.
//
// v1 rule: a snippet is classified only when the *whole trimmed string* is a
// single URL / email / hex color, so a row shows at most one unambiguous
// affordance and a paragraph that merely contains a link stays `.plain`.

import Foundation

/// A parsed 8-bit RGB triple for a hex-color swatch.
public struct ClipdRGB: Equatable {
    public let red: Int
    public let green: Int
    public let blue: Int

    public init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// What a clipboard snippet "is", for affordance purposes.
public enum ClipdContentType: Equatable {
    case url(URL)
    case email(URL)        // a mailto: URL, ready to open
    case hexColor(ClipdRGB)
    case plain
}

// Compiling an NSDataDetector / NSRegularExpression isn't free; reuse one each.
private let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
private let hexRegex = try! NSRegularExpression(pattern: "^#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})$")

public func clipdDetectContentType(_ text: String) -> ClipdContentType {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .plain }

    // Hex color first, and only with a leading '#': people copy colors *with* the
    // '#', whereas bare hex-looking words (bad, facade, decade) are text.
    if let rgb = parseHexColor(trimmed) { return .hexColor(rgb) }

    // URL / email: only when the single match spans the entire trimmed string.
    if let detector = linkDetector {
        let whole = NSRange(trimmed.startIndex..., in: trimmed)
        let matches = detector.matches(in: trimmed, range: whole)
        if matches.count == 1, let match = matches.first, match.range == whole,
           let url = match.url {
            return url.scheme == "mailto" ? .email(url) : .url(url)
        }
    }
    return .plain
}

private func parseHexColor(_ s: String) -> ClipdRGB? {
    let whole = NSRange(s.startIndex..., in: s)
    guard hexRegex.firstMatch(in: s, range: whole) != nil else { return nil }

    var hex = String(s.dropFirst())            // drop the '#'
    if hex.count == 3 {                         // expand #abc → #aabbcc
        hex = hex.map { "\($0)\($0)" }.joined()
    }
    let value = UInt32(hex, radix: 16)!
    return ClipdRGB(red: Int((value >> 16) & 0xFF),
                    green: Int((value >> 8) & 0xFF),
                    blue: Int(value & 0xFF))
}
