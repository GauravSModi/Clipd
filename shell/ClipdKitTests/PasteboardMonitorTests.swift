import XCTest
@testable import ClipdKit

/// A scriptable stand-in for NSPasteboard so the monitor's polling/filtering
/// logic is testable without the real system pasteboard or a running timer.
private final class FakePasteboard: PasteboardReading {
    var changeCount = 0
    var types: [String] = []
    var content: String?
    var image: ImageCapture?
    var filePath: String?

    func string() -> String? { content }
    func imageCapture() -> ImageCapture? { image }
    func fileURLPath() -> String? { filePath }

    /// Simulate a text copy: set content + types and bump the change counter.
    func write(_ text: String, types: [String] = ["public.utf8-plain-text"]) {
        content = text
        self.types = types
        changeCount += 1
    }

    func writeImage(_ image: ImageCapture, types: [String] = ["public.png"]) {
        self.image = image
        self.types = types
        changeCount += 1
    }

    func writeFile(_ path: String, types: [String] = ["public.file-url"]) {
        filePath = path
        self.types = types
        changeCount += 1
    }
}

final class PasteboardMonitorTests: XCTestCase {
    func testEmitsTextAndTimestampOnChange() throws {
        let pb = FakePasteboard()
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 4242 })

        var captured: [(Capture, Int64)] = []
        monitor.onCapture = { captured.append(($0, $1)) }

        pb.write("hello")
        monitor.poll()

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.0, .text("hello"))
        XCTAssertEqual(captured.first?.1, 4242)
    }

    func testEmitsImageCapture() throws {
        let pb = FakePasteboard()
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 })
        var captured: [Capture] = []
        monitor.onCapture = { c, _ in captured.append(c) }

        let img = ImageCapture(data: Data([0x89, 0x50, 0x4e, 0x47]),
                               width: 800, height: 600, format: .png)
        pb.writeImage(img)
        monitor.poll()

        XCTAssertEqual(captured, [.image(img)])
    }

    func testEmitsFileCapture() throws {
        let pb = FakePasteboard()
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 })
        var captured: [Capture] = []
        monitor.onCapture = { c, _ in captured.append(c) }

        pb.writeFile("/Users/me/report.pdf")
        monitor.poll()

        XCTAssertEqual(captured, [.file(path: "/Users/me/report.pdf")])
    }

    func testTextWinsWhenBothTextAndImagePresent() throws {
        // A rich-text copy can carry both text and an inline image; the text is
        // the more searchable representation, so it wins.
        let pb = FakePasteboard()
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 })
        var captured: [Capture] = []
        monitor.onCapture = { c, _ in captured.append(c) }

        pb.content = "rich text"
        pb.image = ImageCapture(data: Data([1, 2, 3]), width: 1, height: 1, format: .png)
        pb.types = ["public.utf8-plain-text", "public.png"]
        pb.changeCount += 1
        monitor.poll()

        XCTAssertEqual(captured, [.text("rich text")])
    }

    func testImageWinsOverFileWhenNoText() throws {
        let pb = FakePasteboard()
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 })
        var captured: [Capture] = []
        monitor.onCapture = { c, _ in captured.append(c) }

        let img = ImageCapture(data: Data([9]), width: 2, height: 2, format: .tiff)
        pb.image = img
        pb.filePath = "/tmp/x"
        pb.types = ["public.tiff", "public.file-url"]
        pb.changeCount += 1
        monitor.poll()

        XCTAssertEqual(captured, [.image(img)])
    }

    func testSkipsConcealedType() throws {
        let pb = FakePasteboard()
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 })
        var captured: [Capture] = []
        monitor.onCapture = { c, _ in captured.append(c) }

        // Password managers mark secrets with org.nspasteboard.ConcealedType.
        pb.write("hunter2", types: ["org.nspasteboard.ConcealedType", "public.utf8-plain-text"])
        monitor.poll()

        XCTAssertEqual(captured, [], "concealed copies must never be ingested")
    }

    func testSkipsTransientType() throws {
        let pb = FakePasteboard()
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 })
        var captured: [Capture] = []
        monitor.onCapture = { c, _ in captured.append(c) }

        pb.write("ephemeral", types: ["org.nspasteboard.TransientType", "public.utf8-plain-text"])
        monitor.poll()

        XCTAssertEqual(captured, [])
    }

    func testConcealedImageIsAlsoSkipped() throws {
        // The security filter applies to every kind, not just text.
        let pb = FakePasteboard()
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 })
        var captured: [Capture] = []
        monitor.onCapture = { c, _ in captured.append(c) }

        pb.writeImage(ImageCapture(data: Data([1]), width: 1, height: 1, format: .png),
                      types: ["org.nspasteboard.ConcealedType", "public.png"])
        monitor.poll()

        XCTAssertEqual(captured, [])
    }

    func testDoesNotEmitWhenChangeCountUnchanged() throws {
        let pb = FakePasteboard()
        pb.write("once")                 // changeCount now 1
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 })  // seeds last = 1
        var emissions = 0
        monitor.onCapture = { _, _ in emissions += 1 }

        monitor.poll()                   // counter still 1 → nothing
        monitor.poll()

        XCTAssertEqual(emissions, 0)
    }

    func testIgnoresContentAlreadyPresentAtLaunch() throws {
        let pb = FakePasteboard()
        pb.write("pre-existing")         // already on the pasteboard before we start
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 })
        var captured: [Capture] = []
        monitor.onCapture = { c, _ in captured.append(c) }

        monitor.poll()                   // no new copy since launch
        XCTAssertEqual(captured, [])

        pb.write("new copy")             // a real copy after launch
        monitor.poll()
        XCTAssertEqual(captured, [.text("new copy")])
    }
}
