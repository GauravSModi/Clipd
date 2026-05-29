import XCTest
@testable import ClipdKit

/// Boundary tests for the pure content-type classifier. v1 rule: a snippet is
/// classified only when the *whole trimmed string* is a single URL / email / hex
/// color, so each row shows at most one unambiguous affordance.
final class ContentTypeTests: XCTestCase {
    func testWholeStringURL() {
        XCTAssertEqual(clipdDetectContentType("https://example.com"),
                       .url(URL(string: "https://example.com")!))
    }

    func testLeadingTrailingWhitespaceTrimmed() {
        XCTAssertEqual(clipdDetectContentType("  https://example.com  "),
                       .url(URL(string: "https://example.com")!))
    }

    func testEmailBecomesMailtoLink() {
        XCTAssertEqual(clipdDetectContentType("foo@bar.com"),
                       .email(URL(string: "mailto:foo@bar.com")!))
    }

    func testHexSixDigit() {
        XCTAssertEqual(clipdDetectContentType("#1a2b3c"),
                       .hexColor(ClipdRGB(red: 26, green: 43, blue: 60)))
    }

    func testHexSixDigitUppercase() {
        XCTAssertEqual(clipdDetectContentType("#1A2B3C"),
                       .hexColor(ClipdRGB(red: 26, green: 43, blue: 60)))
    }

    func testHexThreeDigitExpands() {
        // #abc → #aabbcc
        XCTAssertEqual(clipdDetectContentType("#abc"),
                       .hexColor(ClipdRGB(red: 170, green: 187, blue: 204)))
    }

    func testPlainProse() {
        XCTAssertEqual(clipdDetectContentType("hello world"), .plain)
    }

    func testBareHexWithoutHashIsPlain() {
        // No leading '#': overwhelmingly text, not a color.
        XCTAssertEqual(clipdDetectContentType("1a2b3c"), .plain)
    }

    func testHexLookingWordsAreplain() {
        // The false-positive guard: requiring '#' keeps these as text.
        XCTAssertEqual(clipdDetectContentType("abc"), .plain)
        XCTAssertEqual(clipdDetectContentType("bad"), .plain)
        XCTAssertEqual(clipdDetectContentType("facade"), .plain)
    }

    func testURLEmbeddedInProseIsPlain() {
        // Whole-string rule: a link inside a sentence is not an affordance in v1.
        XCTAssertEqual(clipdDetectContentType("see https://x.com here"), .plain)
    }

    func testMalformedHexLengthIsPlain() {
        XCTAssertEqual(clipdDetectContentType("#12345"), .plain)
    }

    func testEmpty() {
        XCTAssertEqual(clipdDetectContentType(""), .plain)
    }
}
