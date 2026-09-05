import XCTest
@testable import ClipdKit

/// A scriptable pasteboard (mirrors the one in PasteboardMonitorTests) so the
/// controller can be driven through the real monitor → ingest → store path.
private final class FakePasteboard: PasteboardReading {
    var changeCount = 0
    var types: [String] = []
    var content: String?
    func string() -> String? { content }
    func imageCapture() -> ImageCapture? { nil }
    func fileURLPath() -> String? { nil }
    func write(_ text: String, types: [String] = ["public.utf8-plain-text"]) {
        content = text; self.types = types; changeCount += 1
    }
}

final class HistoryControllerTests: XCTestCase {
    private func makeClipboard(compactThresholdBytes: UInt64 = 1_000_000) throws -> Clipboard {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipd-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try Clipboard(logPath: dir.appendingPathComponent("clipd.log").path,
                             maxEntries: 10_000,
                             compactThresholdBytes: compactThresholdBytes)
    }

    func testNewCopyIsIngestedAndSearchable() throws {
        let clip = try makeClipboard()
        let pb = FakePasteboard()
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 7 })
        let controller = HistoryController(clipboard: clip,
                                           monitor: monitor,
                                           compactThresholdBytes: 1_000_000,
                                           now: { 8 })

        pb.write("findme")
        monitor.poll()

        let results = try controller.search("find", maxResults: 10)
        XCTAssertEqual(results.first?.text, "findme")
    }

    func testCompactsDuringSessionWhenLogExceedsThreshold() throws {
        // Tiny threshold so ingesting trips it almost immediately.
        let clip = try makeClipboard(compactThresholdBytes: 8)
        let pb = FakePasteboard()
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 0 })
        let controller = HistoryController(clipboard: clip,
                                           monitor: monitor,
                                           compactThresholdBytes: 8)

        // 200 copies of the same string: dedup keeps one live entry, but each
        // add appends a record. Without in-session compaction the log grows
        // unbounded; with it, the log stays pinned near a single live entry.
        for i in 0..<200 {
            pb.write("dup")
            monitor.poll()
        }

        XCTAssertEqual(try clip.stats().entryCount, 1)
        XCTAssertLessThan(try clip.stats().logBytes, 100,
                          "log should stay bounded — compaction must run during the session")
    }

    func testSetPinnedDeleteClearPassThrough() throws {
        let clip = try makeClipboard()
        let pb = FakePasteboard()
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 })
        let controller = HistoryController(clipboard: clip,
                                           monitor: monitor,
                                           compactThresholdBytes: 1_000_000,
                                           now: { 2 })

        pb.write("findme"); monitor.poll()
        let id = try XCTUnwrap(controller.search("findme").first?.id)

        try controller.setPinned(id, true)
        XCTAssertTrue(try controller.search("findme").first!.pinned)

        try controller.delete(id: id)
        XCTAssertEqual(try controller.search("findme").count, 0)

        pb.write("keepme"); monitor.poll()
        try controller.clear()  // nothing pinned now → empties the history
        XCTAssertEqual(try controller.search("").count, 0)
    }
}

// MARK: - Live limits passthrough

extension HistoryControllerTests {
    /// The controller is a passthrough: eviction policy lives in the C++ store,
    /// and stats has to be reachable so the shell can decide whether a proposed
    /// cap would evict before it asks the user.
    func testSetLimitsAndStatsPassThroughToTheCore() throws {
        let clip = try makeClipboard()
        let monitor = PasteboardMonitor(pasteboard: FakePasteboard(), now: { 1 })
        let controller = HistoryController(clipboard: clip,
                                           monitor: monitor,
                                           compactThresholdBytes: 1 << 30,
                                           now: { 2 })
        for i in 0..<12 { try clip.add("entry \(i)", at: Int64(i + 1)) }
        XCTAssertEqual(try controller.stats().entryCount, 12)

        try controller.setLimits(maxEntries: 4, maxBytes: 0)

        XCTAssertEqual(try controller.stats().entryCount, 4)
    }
}

// MARK: - Retention sweep

extension HistoryControllerTests {
    /// The sweep runs off the controller's INJECTED clock, so this asserts
    /// against a fixed `now` and never sleeps or reads wall-clock time.
    func testSweepExpiredRemovesBackdatedEntriesAndSparesRecentOnes() throws {
        let clip = try makeClipboard()
        let monitor = PasteboardMonitor(pasteboard: FakePasteboard(), now: { 1 })
        let day: Int64 = 86_400_000
        let now: Int64 = 100 * day
        let controller = HistoryController(clipboard: clip,
                                           monitor: monitor,
                                           compactThresholdBytes: 1 << 30,
                                           now: { now })
        try clip.add("ancient", at: now - 40 * day)
        try clip.add("recent", at: now - 2 * day)

        XCTAssertEqual(try controller.sweepExpired(retentionDays: 7), 1)

        let texts = try controller.search("").map(\.text)
        XCTAssertEqual(texts, ["recent"])
    }

    /// A pinned entry never expires — so "delete after N days" is not a blanket
    /// guarantee that nothing older survives.
    func testSweepExpiredSparesPinnedEntries() throws {
        let clip = try makeClipboard()
        let monitor = PasteboardMonitor(pasteboard: FakePasteboard(), now: { 1 })
        let day: Int64 = 86_400_000
        let now: Int64 = 100 * day
        let controller = HistoryController(clipboard: clip,
                                           monitor: monitor,
                                           compactThresholdBytes: 1 << 30,
                                           now: { now })
        try clip.add("keepme", at: now - 40 * day)
        try clip.add("dropme", at: now - 40 * day)
        let id = try XCTUnwrap(controller.search("keepme").first?.id)
        try controller.setPinned(id, true)

        XCTAssertEqual(try controller.sweepExpired(retentionDays: 7), 1)

        let texts = try controller.search("").map(\.text)
        XCTAssertEqual(texts, ["keepme"])
    }

    /// Never means never: the sweep must not reach the core at all.
    func testSweepExpiredIsANoOpWhenRetentionIsNever() throws {
        let clip = try makeClipboard()
        let monitor = PasteboardMonitor(pasteboard: FakePasteboard(), now: { 1 })
        let controller = HistoryController(clipboard: clip,
                                           monitor: monitor,
                                           compactThresholdBytes: 1 << 30,
                                           now: { 100 * 86_400_000 })
        try clip.add("ancient", at: 1)

        XCTAssertEqual(try controller.sweepExpired(retentionDays: 0), 0)
        XCTAssertEqual(try controller.stats().entryCount, 1)
    }
}
