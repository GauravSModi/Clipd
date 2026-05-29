import XCTest
@testable import ClipdKit

/// Exercises the image/file/blob additions across the real C boundary: the
/// length-carrying clipd_add_image, the richer ClipdMatch (kind/id/dims), and the
/// clipd_read_blob copy-out-then-free path.
final class ClipboardImageTests: XCTestCase {
    private func makeClipboard() throws -> Clipboard {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipd-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try Clipboard(logPath: dir.appendingPathComponent("clipd.log").path,
                             maxEntries: 100, compactThresholdBytes: 1_000_000)
    }

    func testAddImageSearchableWithMetadata() throws {
        let clip = try makeClipboard()
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x01, 0x02])
        try clip.addImage(bytes, width: 1024, height: 768, format: .png, at: 1)

        let results = try clip.search("image", maxResults: 10, now: 100)
        XCTAssertEqual(results.count, 1)
        let m = results[0]
        XCTAssertEqual(m.kind, .image)
        XCTAssertEqual(m.width, 1024)
        XCTAssertEqual(m.height, 768)
        XCTAssertEqual(m.byteSize, UInt64(bytes.count))
        XCTAssertEqual(m.id.count, 64)  // sha256-hex
    }

    func testReadBlobRoundTripsImageBytes() throws {
        let clip = try makeClipboard()
        let bytes = Data([0x00, 0x01, 0xff, 0x80, 0x52, 0x41, 0x57])  // NUL + high byte
        try clip.addImage(bytes, width: 2, height: 2, format: .png, at: 1)

        let results = try clip.search("", maxResults: 10, now: 100)
        XCTAssertEqual(results.count, 1)
        let blob = clip.readBlob(id: results[0].id)
        XCTAssertEqual(blob, bytes)
    }

    func testReadBlobUnknownIdReturnsNil() throws {
        let clip = try makeClipboard()
        XCTAssertNil(clip.readBlob(id: String(repeating: "a", count: 64)))
    }

    func testAddFileIsFileKindWithPath() throws {
        let clip = try makeClipboard()
        try clip.addFile("/Users/me/notes.txt", at: 1)

        let results = try clip.search("notes", maxResults: 10, now: 100)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].kind, .file)
        XCTAssertEqual(results[0].text, "/Users/me/notes.txt")
    }

    func testIdenticalImagesDedupeToOneEntry() throws {
        let clip = try makeClipboard()
        let bytes = Data([1, 2, 3, 4, 5])
        try clip.addImage(bytes, width: 4, height: 4, format: .png, at: 1)
        try clip.addImage(bytes, width: 4, height: 4, format: .png, at: 9)

        XCTAssertEqual(try clip.stats().entryCount, 1)
    }
}
