import XCTest
@testable import ClipdKit

/// A scriptable stand-in for NSPasteboard so the monitor's polling/filtering
/// logic is testable without the real system pasteboard or a running timer.
private final class FakePasteboard: PasteboardReading {
    var changeCount = 0
    var types: [String] = []
    var content: String?

    func string() -> String? { content }

    /// Simulate a copy: set content + types and bump the change counter.
    func write(_ text: String, types: [String] = ["public.utf8-plain-text"]) {
        content = text
        self.types = types
        changeCount += 1
    }
}

final class PasteboardMonitorTests: XCTestCase {
    func testEmitsTextAndTimestampOnChange() throws {
        let pb = FakePasteboard()
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 4242 })

        var captured: [(String, Int64)] = []
        monitor.onCopy = { captured.append(($0, $1)) }

        pb.write("hello")
        monitor.poll()

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.0, "hello")
        XCTAssertEqual(captured.first?.1, 4242)
    }

    func testSkipsConcealedType() throws {
        let pb = FakePasteboard()
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 })
        var captured: [String] = []
        monitor.onCopy = { text, _ in captured.append(text) }

        // Password managers mark secrets with org.nspasteboard.ConcealedType.
        pb.write("hunter2", types: ["org.nspasteboard.ConcealedType", "public.utf8-plain-text"])
        monitor.poll()

        XCTAssertEqual(captured, [], "concealed copies must never be ingested")
    }

    func testSkipsTransientType() throws {
        let pb = FakePasteboard()
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 })
        var captured: [String] = []
        monitor.onCopy = { text, _ in captured.append(text) }

        pb.write("ephemeral", types: ["org.nspasteboard.TransientType", "public.utf8-plain-text"])
        monitor.poll()

        XCTAssertEqual(captured, [])
    }

    func testDoesNotEmitWhenChangeCountUnchanged() throws {
        let pb = FakePasteboard()
        pb.write("once")                 // changeCount now 1
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 })  // seeds last = 1
        var emissions = 0
        monitor.onCopy = { _, _ in emissions += 1 }

        monitor.poll()                   // counter still 1 → nothing
        monitor.poll()

        XCTAssertEqual(emissions, 0)
    }

    func testIgnoresContentAlreadyPresentAtLaunch() throws {
        let pb = FakePasteboard()
        pb.write("pre-existing")         // already on the pasteboard before we start
        let monitor = PasteboardMonitor(pasteboard: pb, now: { 1 })
        var captured: [String] = []
        monitor.onCopy = { text, _ in captured.append(text) }

        monitor.poll()                   // no new copy since launch
        XCTAssertEqual(captured, [])

        pb.write("new copy")             // a real copy after launch
        monitor.poll()
        XCTAssertEqual(captured, ["new copy"])
    }
}
