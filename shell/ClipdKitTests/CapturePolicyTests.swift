import XCTest
@testable import ClipdKit

/// CapturePolicy is pure (pause flag + per-kind allow flags) plus the pure decision
/// function that turns a raw pasteboard reading into a Capture or nil. No pasteboard,
/// no UI, no UserDefaults — PasteboardMonitor and ClipdSettings each build on this.
final class CapturePolicyTests: XCTestCase {

    // MARK: - capturingEverything

    func testCapturingEverythingAllowsAllKindsAndIsNotPaused() {
        let policy = CapturePolicy.capturingEverything

        XCTAssertFalse(policy.isPaused)
        XCTAssertTrue(policy.allows(.text))
        XCTAssertTrue(policy.allows(.image))
        XCTAssertTrue(policy.allows(.file))
    }

    // MARK: - Paused short-circuits every kind

    func testPausedYieldsNilForTextImageAndFile() {
        let policy = CapturePolicy(isPaused: true, allowsText: true,
                                   allowsImage: true, allowsFile: true)
        let img = ImageCapture(data: Data([1]), width: 1, height: 1, format: .png)

        XCTAssertNil(clipdSelectCapture(file: nil, text: "hello", image: nil, policy: policy))
        XCTAssertNil(clipdSelectCapture(file: nil, text: nil, image: img, policy: policy))
        XCTAssertNil(clipdSelectCapture(file: "/tmp/x", text: nil, image: nil, policy: policy))
    }

    // MARK: - Priority preserved when everything is allowed

    func testPriorityIsFileThenTextThenImageWhenAllAllowed() {
        let policy = CapturePolicy.capturingEverything
        let img = ImageCapture(data: Data([1, 2, 3]), width: 32, height: 32, format: .tiff)

        // Finder-shaped: file URL + filename text + icon image all present → file wins.
        XCTAssertEqual(
            clipdSelectCapture(file: "/Users/me/Resume.pdf", text: "Resume.pdf", image: img,
                               policy: policy),
            .file(path: "/Users/me/Resume.pdf"))

        // Text + image, no file → text wins.
        XCTAssertEqual(
            clipdSelectCapture(file: nil, text: "rich text", image: img, policy: policy),
            .text("rich text"))

        // Image only → image wins.
        XCTAssertEqual(
            clipdSelectCapture(file: nil, text: nil, image: img, policy: policy),
            .image(img))
    }

    // MARK: - Disallowed winner skips entirely (decision 3: no fall-through)

    func testDisallowedFileWinnerSkipsEntirelyRatherThanFallingThroughToText() {
        let policy = CapturePolicy(isPaused: false, allowsText: true,
                                   allowsImage: true, allowsFile: false)
        let img = ImageCapture(data: Data([1]), width: 32, height: 32, format: .tiff)

        // File would win the priority contest, but files are disallowed. Must be nil,
        // NOT .text("Resume.pdf") — a disallowed kind is not a re-run of the contest
        // among the remaining representations.
        let result = clipdSelectCapture(file: "/Users/me/Resume.pdf", text: "Resume.pdf",
                                        image: img, policy: policy)
        XCTAssertNil(result)
    }

    func testImagesOffStillCapturesTextWhenBothPresent() {
        let policy = CapturePolicy(isPaused: false, allowsText: true,
                                   allowsImage: false, allowsFile: true)
        let img = ImageCapture(data: Data([1]), width: 1, height: 1, format: .png)

        XCTAssertEqual(
            clipdSelectCapture(file: nil, text: "rich text", image: img, policy: policy),
            .text("rich text"))
    }

    func testImagesOffSkipsImageOnlyCopy() {
        let policy = CapturePolicy(isPaused: false, allowsText: true,
                                   allowsImage: false, allowsFile: true)
        let img = ImageCapture(data: Data([1]), width: 1, height: 1, format: .png)

        XCTAssertNil(clipdSelectCapture(file: nil, text: nil, image: img, policy: policy))
    }

    // MARK: - Emptiness guards preserved

    func testEmptyTextAndEmptyPathAreIgnored() {
        let policy = CapturePolicy.capturingEverything
        let img = ImageCapture(data: Data([1]), width: 1, height: 1, format: .png)

        // Empty string text and empty path must be treated as absent, same as before
        // this change, falling through to the next representation.
        XCTAssertEqual(
            clipdSelectCapture(file: "", text: "", image: img, policy: policy),
            .image(img))
    }
}
