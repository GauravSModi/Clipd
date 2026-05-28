import XCTest
@testable import ClipdKit

/// Exercises the Clipboard wrapper's contracts: the NULL-vs-count==0 distinction,
/// most-recent ordering on an empty query, that dedup/scoring stay the core's job,
/// stats/compact, and that every call is serialized on the one private queue.
final class ClipboardTests: XCTestCase {
    private func makeClipboard(maxEntries: Int = 100,
                               compactThresholdBytes: UInt64 = 1_000_000) throws -> Clipboard {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipd-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try Clipboard(logPath: dir.appendingPathComponent("clipd.log").path,
                             maxEntries: maxEntries,
                             compactThresholdBytes: compactThresholdBytes)
    }

    func testStatsReportsLiveEntryCount() throws {
        let clip = try makeClipboard()
        try clip.add("one", at: 1)
        try clip.add("two", at: 2)

        let stats = try clip.stats()

        XCTAssertEqual(stats.entryCount, 2)
        XCTAssertGreaterThan(stats.logBytes, 0)
    }

    func testCompactShrinksLogAfterDuplicateAdds() throws {
        let clip = try makeClipboard()
        for i in 0..<50 { try clip.add("same text", at: Int64(i)) }
        let before = try clip.stats().logBytes

        try clip.compact()

        XCTAssertLessThan(try clip.stats().logBytes, before)
        // Dedup is the core's job, not the wrapper's: 50 adds of one string
        // collapse to a single live entry.
        XCTAssertEqual(try clip.stats().entryCount, 1)
    }

    func testNoMatchReturnsEmptyNotFailure() throws {
        let clip = try makeClipboard()
        try clip.add("alpha", at: 1)

        // No subsequence match → a successful search with count == 0, which the
        // wrapper surfaces as [] — distinct from the NULL failure case (a throw).
        XCTAssertEqual(try clip.search("zzzz", maxResults: 10, now: 2), [])
    }

    func testEmptyQueryReturnsMostRecentFirst() throws {
        let clip = try makeClipboard()
        try clip.add("first", at: 1)
        try clip.add("second", at: 2)
        try clip.add("third", at: 3)

        let results = try clip.search("", maxResults: 10, now: 4)

        XCTAssertEqual(results.map(\.text), ["third", "second", "first"])
    }

    func testConcurrentCallsAreSerializedWithoutCorruption() throws {
        let clip = try makeClipboard(maxEntries: 10_000)
        let adds = 200

        // Hammer the (non-thread-safe) handle from many threads at once. Correct
        // only because every call funnels through the one serial queue; without
        // it these concurrent clipd_add calls would be undefined behavior.
        DispatchQueue.concurrentPerform(iterations: adds) { i in
            try? clip.add("entry-\(i)", at: Int64(i))
        }
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            _ = try? clip.search("entry", maxResults: 5, now: 1000)
        }

        XCTAssertEqual(try clip.stats().entryCount, adds)
    }
}
