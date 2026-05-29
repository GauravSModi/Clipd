import XCTest
@testable import ClipdKit

/// Boundary tests for the pure keyboard-selection index math. No wrap: moving
/// past an edge clamps. Re-clamp keeps the selection valid as the result set
/// shrinks while typing. ⌘1–9 maps shortcut N to the (N-1)th row when present.
final class SelectionIndexTests: XCTestCase {
    func testEmptyClampsToZero() {
        XCTAssertEqual(clipdMovedSelection(0, by: -1, count: 0), 0)
        XCTAssertEqual(clipdMovedSelection(0, by: 5, count: 0), 0)
        XCTAssertEqual(clipdClampedSelection(3, count: 0), 0)
    }

    func testSingleElementStaysPut() {
        XCTAssertEqual(clipdMovedSelection(0, by: 1, count: 1), 0)
        XCTAssertEqual(clipdMovedSelection(0, by: -1, count: 1), 0)
    }

    func testMoveWithinRange() {
        XCTAssertEqual(clipdMovedSelection(2, by: 1, count: 5), 3)
        XCTAssertEqual(clipdMovedSelection(2, by: -1, count: 5), 1)
    }

    func testClampAtTopEdge() {
        XCTAssertEqual(clipdMovedSelection(0, by: -1, count: 5), 0)
    }

    func testClampAtBottomEdge() {
        XCTAssertEqual(clipdMovedSelection(4, by: 1, count: 5), 4)
    }

    func testLargeDeltaClamps() {
        XCTAssertEqual(clipdMovedSelection(0, by: 100, count: 5), 4)
        XCTAssertEqual(clipdMovedSelection(4, by: -100, count: 5), 0)
    }

    func testClampedSelectionAfterResultsChange() {
        XCTAssertEqual(clipdClampedSelection(10, count: 5), 4)   // shrank below index
        XCTAssertEqual(clipdClampedSelection(-3, count: 5), 0)
        XCTAssertEqual(clipdClampedSelection(2, count: 5), 2)    // still valid
    }

    func testRecentShortcutInRange() {
        XCTAssertEqual(clipdRecentIndex(forShortcut: 1, count: 5), 0)
        XCTAssertEqual(clipdRecentIndex(forShortcut: 3, count: 3), 2)
    }

    func testRecentShortcutBeyondCountIsNil() {
        XCTAssertNil(clipdRecentIndex(forShortcut: 9, count: 3))
        XCTAssertNil(clipdRecentIndex(forShortcut: 4, count: 3))
    }

    func testRecentShortcutZeroOrNegativeIsNil() {
        XCTAssertNil(clipdRecentIndex(forShortcut: 0, count: 5))
        XCTAssertNil(clipdRecentIndex(forShortcut: -1, count: 5))
    }
}
