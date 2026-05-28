import XCTest
@testable import ClipdKit

/// Boundary tests for the pure relative-time formatter. It's locale-free and
/// deterministic (the absolute formatter, which is locale-dependent, isn't
/// asserted exactly). delta = nowMs - ts.
final class RelativeTimeTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000  // fixed reference instant

    private func relative(secondsAgo s: Int64) -> String {
        clipdRelativeTime(fromEpochMs: now - s * 1000, nowMs: now)
    }

    func testZeroAndSubMinuteIsJustNow() {
        XCTAssertEqual(relative(secondsAgo: 0), "just now")
        XCTAssertEqual(relative(secondsAgo: 59), "just now")
    }

    func testMinutes() {
        XCTAssertEqual(relative(secondsAgo: 60), "1m ago")
        XCTAssertEqual(relative(secondsAgo: 59 * 60), "59m ago")
    }

    func testHours() {
        XCTAssertEqual(relative(secondsAgo: 60 * 60), "1h ago")
        XCTAssertEqual(relative(secondsAgo: 23 * 3600), "23h ago")
    }

    func testDays() {
        XCTAssertEqual(relative(secondsAgo: 24 * 3600), "1d ago")
        XCTAssertEqual(relative(secondsAgo: 6 * 86400), "6d ago")
    }

    func testWeeks() {
        XCTAssertEqual(relative(secondsAgo: 7 * 86400), "1w ago")
        XCTAssertEqual(relative(secondsAgo: 21 * 86400), "3w ago")
    }

    func testFutureClampsToJustNow() {
        // Clock skew: a timestamp slightly ahead of now must not read negative.
        XCTAssertEqual(clipdRelativeTime(fromEpochMs: now + 5000, nowMs: now), "just now")
    }
}
