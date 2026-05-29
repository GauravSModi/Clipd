import XCTest
@testable import ClipdKit

/// The fallback rule: paste-back happens only when the user asked for it AND the
/// Accessibility permission is granted; otherwise it degrades to copy-only so the
/// action is never silently dropped.
final class PasteActionTests: XCTestCase {
    func testPasteRequestedAndTrustedPastes() {
        XCTAssertEqual(clipdResolvePasteAction(requested: .paste, accessibilityTrusted: true), .paste)
    }

    func testPasteRequestedButNotTrustedFallsBackToCopy() {
        XCTAssertEqual(clipdResolvePasteAction(requested: .paste, accessibilityTrusted: false), .copy)
    }

    func testCopyRequestedStaysCopyRegardlessOfTrust() {
        XCTAssertEqual(clipdResolvePasteAction(requested: .copy, accessibilityTrusted: true), .copy)
        XCTAssertEqual(clipdResolvePasteAction(requested: .copy, accessibilityTrusted: false), .copy)
    }
}
