import XCTest
@testable import ClipdKit

/// Proves the whole Phase 3 boundary end to end with one test: a Swift caller
/// creates a Clipboard backed by a temp log, records a copy, fuzzy-searches it,
/// and reads the result back as native Swift — which only works if the SwiftPM
/// build links both static archives, the C interop marshals correctly, and the
/// copy-out-then-free memory dance holds.
final class ClipboardRoundTripTests: XCTestCase {
    private var logPath: String!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipd-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logPath = dir.appendingPathComponent("clipd.log").path
    }

    func testAddThenSubsequenceSearchRoundTrips() throws {
        let clip = try Clipboard(logPath: logPath,
                                 maxEntries: 100,
                                 compactThresholdBytes: 1_000_000)
        try clip.add("hello world", at: 123)

        let results = try clip.search("hlo", maxResults: 10, now: 456)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.text, "hello world")
    }
}
