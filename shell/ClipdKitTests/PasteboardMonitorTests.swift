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

    func testFileWinsOverImageWhenFileURLPresent() throws {
        // A copied file (even an image file) carries a file URL plus an icon/
        // thumbnail image; we want the FILE, not the icon. File beats image.
        let pb = FakePasteboard()
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 })
        var captured: [Capture] = []
        monitor.onCapture = { c, _ in captured.append(c) }

        pb.image = ImageCapture(data: Data([9]), width: 2, height: 2, format: .tiff)
        pb.filePath = "/tmp/x"
        pb.types = ["public.tiff", "public.file-url"]
        pb.changeCount += 1
        monitor.poll()

        XCTAssertEqual(captured, [.file(path: "/tmp/x")])
    }

    func testFinderFileCopyIsCapturedAsFileNotFilenameText() throws {
        // Regression: a real Finder ⌘C puts the file URL AND the filename string
        // AND the file's icon (tiff). Text-first priority used to grab the
        // filename and store the copy as text; a file copy must be captured as a
        // FILE so paste-back yields the file, not its name.
        let pb = FakePasteboard()
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 })
        var captured: [Capture] = []
        monitor.onCapture = { c, _ in captured.append(c) }

        pb.content = "Resume - Gaurav Modi.pdf"   // the filename string Finder adds
        pb.image = ImageCapture(data: Data([1, 2, 3]), width: 32, height: 32, format: .tiff)  // the icon
        pb.filePath = "/Users/me/Resume - Gaurav Modi.pdf"
        pb.types = ["public.file-url", "public.utf8-plain-text", "public.tiff"]
        pb.changeCount += 1
        monitor.poll()

        XCTAssertEqual(captured, [.file(path: "/Users/me/Resume - Gaurav Modi.pdf")])
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

    func testSkipsCopyFromExcludedSourceApp() throws {
        // The macOS Passwords app copies a password as plain text with NO
        // ConcealedType marker, so the type filter can't catch it. As a
        // best-effort fallback, a copy made while a known secret app is frontmost
        // is skipped by source app.
        let pb = FakePasteboard()
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 },
                                        excludedApps: { ["com.apple.Passwords"] },
                                        frontmostBundleID: { "com.apple.Passwords" })
        var captured: [Capture] = []
        monitor.onCapture = { c, _ in captured.append(c) }

        pb.write("hunter2")  // plain text, no concealed marker (Apple's behavior)
        monitor.poll()

        XCTAssertEqual(captured, [], "copies from the macOS Passwords app must be skipped")
    }

    func testCapturesCopyFromOrdinaryApp() throws {
        let pb = FakePasteboard()
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 },
                                        excludedApps: { ["com.apple.Passwords"] },
                                        frontmostBundleID: { "com.apple.TextEdit" })
        var captured: [Capture] = []
        monitor.onCapture = { c, _ in captured.append(c) }

        pb.write("just text")
        monitor.poll()

        XCTAssertEqual(captured, [.text("just text")])
    }

    // MARK: - Excluded source apps (user-editable, injected)

    func testConsultsTheInjectedExcludedSetNotACompiledInOne() throws {
        // The list is a user-managed setting now: only what's injected is skipped.
        // com.apple.Passwords is captured here precisely because the injected set
        // doesn't contain it — proof no static set is still in play.
        let pb = FakePasteboard()
        var captured: [Capture] = []

        let excluded = PasteboardMonitor(pasteboard: pb, now: { 1 },
                                         excludedApps: { ["com.example.vault"] },
                                         frontmostBundleID: { "com.example.vault" })
        excluded.onCapture = { c, _ in captured.append(c) }
        pb.write("from the user's own excluded app")
        excluded.poll()
        XCTAssertEqual(captured, [], "a user-added app must be skipped")

        let notExcluded = PasteboardMonitor(pasteboard: pb, now: { 1 },
                                            excludedApps: { ["com.example.vault"] },
                                            frontmostBundleID: { "com.apple.Passwords" })
        notExcluded.onCapture = { c, _ in captured.append(c) }
        pb.write("hunter2")
        notExcluded.poll()
        XCTAssertEqual(captured, [.text("hunter2")],
                       "an app the user removed from the list must be captured again")
    }

    func testExcludedSetIsReReadOnEveryPollWithoutRebuildingTheMonitor() throws {
        // Editing the list in Settings must take effect on the next poll, with no
        // app restart — same contract as the Stage 2 capture policy.
        let pb = FakePasteboard()
        var excluded: Set<String> = []
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 },
                                        excludedApps: { excluded },
                                        frontmostBundleID: { "com.example.vault" })
        var captured: [Capture] = []
        monitor.onCapture = { c, _ in captured.append(c) }

        pb.write("before the user excluded it")
        monitor.poll()
        XCTAssertEqual(captured, [.text("before the user excluded it")])

        excluded.insert("com.example.vault")
        pb.write("after the user excluded it")
        monitor.poll()
        XCTAssertEqual(captured, [.text("before the user excluded it")],
                       "the same monitor instance must pick up the list change")
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

    // MARK: - Capture policy (pause + per-kind filters)

    func testPausedCopyIsSkippedNotDeferredToResume() throws {
        // Required regression: a copy made while paused must be dropped for good,
        // not replayed the moment capture resumes.
        let pb = FakePasteboard()
        var paused = true
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 },
                                        policy: { CapturePolicy(isPaused: paused,
                                                                allowsText: true,
                                                                allowsImage: true,
                                                                allowsFile: true) })
        var captured: [Capture] = []
        monitor.onCapture = { c, _ in captured.append(c) }

        pb.write("made while paused")
        monitor.poll()
        XCTAssertEqual(captured, [], "a copy made while paused must not be captured")

        paused = false
        monitor.poll()                   // no NEW pasteboard change since the last poll
        XCTAssertEqual(captured, [],
                       "resuming must not resurrect the copy made while paused")

        pb.write("made after resuming")
        monitor.poll()
        XCTAssertEqual(captured, [.text("made after resuming")])
    }

    func testDisallowedKindIsSkippedWhileOtherKindsStillCapture() throws {
        let pb = FakePasteboard()
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 },
                                        policy: { CapturePolicy(isPaused: false,
                                                                allowsText: true,
                                                                allowsImage: false,
                                                                allowsFile: true) })
        var captured: [Capture] = []
        monitor.onCapture = { c, _ in captured.append(c) }

        pb.writeImage(ImageCapture(data: Data([1]), width: 1, height: 1, format: .png))
        monitor.poll()
        XCTAssertEqual(captured, [], "images are disallowed by policy")

        pb.write("still captured")
        monitor.poll()
        XCTAssertEqual(captured, [.text("still captured")])
    }

    func testPolicyIsReReadOnEveryPollWithoutRebuildingTheMonitor() throws {
        let pb = FakePasteboard()
        var allowsImage = false
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 },
                                        policy: { CapturePolicy(isPaused: false,
                                                                allowsText: true,
                                                                allowsImage: allowsImage,
                                                                allowsFile: true) })
        var captured: [Capture] = []
        monitor.onCapture = { c, _ in captured.append(c) }

        let img = ImageCapture(data: Data([1]), width: 1, height: 1, format: .png)
        pb.writeImage(img)
        monitor.poll()
        XCTAssertEqual(captured, [], "images start disallowed")

        allowsImage = true
        pb.writeImage(img)
        monitor.poll()
        XCTAssertEqual(captured, [.image(img)],
                       "the same monitor instance must pick up the policy change")
    }
}
