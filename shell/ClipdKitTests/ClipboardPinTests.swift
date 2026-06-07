import XCTest
@testable import ClipdKit

/// The Clipboard bridge for pin/delete/clear and the Match.pinned mapping. Each
/// call funnels through the one serial queue (same contract as add/search).
final class ClipboardPinTests: XCTestCase {
    private func makeClipboard() throws -> Clipboard {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipd-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try Clipboard(logPath: dir.appendingPathComponent("clipd.log").path,
                             maxEntries: 100, compactThresholdBytes: 1_000_000)
    }

    func testSetPinnedReflectedInMatchMapping() throws {
        let clip = try makeClipboard()
        try clip.add("favorite", at: 1)
        let id = try XCTUnwrap(clip.search("favorite", maxResults: 10, now: 2).first?.id)
        XCTAssertFalse(try clip.search("favorite", maxResults: 10, now: 2).first!.pinned)

        try clip.setPinned(id, true)
        XCTAssertTrue(try clip.search("favorite", maxResults: 10, now: 2).first!.pinned)

        try clip.setPinned(id, false)
        XCTAssertFalse(try clip.search("favorite", maxResults: 10, now: 2).first!.pinned)
    }

    func testDeleteRemovesEntry() throws {
        let clip = try makeClipboard()
        try clip.add("doomed", at: 1)
        try clip.add("survivor", at: 2)
        let id = try XCTUnwrap(clip.search("doomed", maxResults: 10, now: 3).first?.id)

        try clip.delete(id: id)

        XCTAssertEqual(try clip.search("doomed", maxResults: 10, now: 3).count, 0)
        XCTAssertEqual(try clip.search("survivor", maxResults: 10, now: 3).count, 1)
    }

    func testClearKeepsPinned() throws {
        let clip = try makeClipboard()
        try clip.add("fav", at: 1)
        let id = try XCTUnwrap(clip.search("fav", maxResults: 10, now: 2).first?.id)
        try clip.setPinned(id, true)
        try clip.add("trash", at: 2)

        try clip.clear()

        let results = try clip.search("", maxResults: 10, now: 3)
        XCTAssertEqual(results.map(\.text), ["fav"])
        XCTAssertTrue(results.first!.pinned)
    }
}
