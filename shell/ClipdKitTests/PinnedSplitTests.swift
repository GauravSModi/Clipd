import XCTest
@testable import ClipdKit

/// Pure helper that tells the view where the pinned section ends. Relies on the
/// core returning pinned matches as a contiguous leading run (pinned-first).
final class PinnedSplitTests: XCTestCase {
    private func match(_ text: String, pinned: Bool) -> Match {
        Match(text: text, timestamp: 0, score: 1, id: text, kind: .text, pinned: pinned)
    }

    func testCountsLeadingPinnedRun() {
        let ms = [match("a", pinned: true), match("b", pinned: true),
                  match("c", pinned: false), match("d", pinned: false)]
        XCTAssertEqual(clipdPinnedPrefixCount(ms), 2)
    }

    func testNonePinnedIsZero() {
        XCTAssertEqual(clipdPinnedPrefixCount([match("a", pinned: false)]), 0)
    }

    func testAllPinned() {
        XCTAssertEqual(
            clipdPinnedPrefixCount([match("a", pinned: true), match("b", pinned: true)]), 2)
    }

    func testEmptyIsZero() {
        XCTAssertEqual(clipdPinnedPrefixCount([]), 0)
    }
}
