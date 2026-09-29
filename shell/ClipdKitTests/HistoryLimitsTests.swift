import XCTest
@testable import ClipdKit

/// The pure History-cap helpers: the bounds the UI clamps to, and the decision
/// about whether a proposed pair of caps would actually evict anything (which is
/// what gates the confirmation alert).
final class HistoryLimitsTests: XCTestCase {

    // MARK: - Bounds

    func testEntryBoundsAreTheDocumentedRange() {
        XCTAssertEqual(ClipdHistoryLimits.minEntries, 100)
        XCTAssertEqual(ClipdHistoryLimits.maxEntries, 100_000)
    }

    /// The UI offers no "unlimited" option, so 0 must never be reachable through
    /// the picker even though clipd.h still documents 0 as unbounded for API
    /// callers.
    func testByteBudgetOptionsAreAscendingAndNeverZero() {
        let options = ClipdHistoryLimits.byteBudgetOptions
        XCTAssertFalse(options.isEmpty)
        XCTAssertFalse(options.contains(0))
        XCTAssertEqual(options, options.sorted())
        XCTAssertEqual(options.first, 64 * 1024 * 1024)
        XCTAssertEqual(options.last, 4 * 1024 * 1024 * 1024)
    }

    /// The shipped default has to be selectable, or opening Settings would show a
    /// picker with nothing selected and silently retune the budget on first touch.
    func testDefaultByteBudgetIsOneOfTheOptions() {
        XCTAssertTrue(ClipdHistoryLimits.byteBudgetOptions
            .contains(ClipdSettings.defaultMaxBytes))
    }

    // MARK: - Reduction detection

    func testNoReductionWhenBothCapsAreAboveTheLiveSet() {
        XCTAssertEqual(
            clipdLimitReduction(liveCount: 40, liveBytes: 500,
                                maxEntries: 100, maxBytes: 1_000),
            .none)
    }

    /// The boundary: a cap exactly equal to the live state evicts nothing, so it
    /// must not raise a confirmation.
    func testNoReductionWhenCapsExactlyEqualTheLiveSet() {
        XCTAssertEqual(
            clipdLimitReduction(liveCount: 40, liveBytes: 500,
                                maxEntries: 40, maxBytes: 500),
            .none)
    }

    func testZeroCapsMeanUnboundedSoNothingIsEvicted() {
        XCTAssertEqual(
            clipdLimitReduction(liveCount: 9_999, liveBytes: 1 << 40,
                                maxEntries: 0, maxBytes: 0),
            .none)
    }

    func testCountReductionReportsTheUpperBound() {
        XCTAssertEqual(
            clipdLimitReduction(liveCount: 1_312, liveBytes: 500,
                                maxEntries: 500, maxBytes: 1_000),
            .count(upTo: 812, newMax: 500))
    }

    func testByteReductionReportsSizesNotACount() {
        XCTAssertEqual(
            clipdLimitReduction(liveCount: 40, liveBytes: 900,
                                maxEntries: 100, maxBytes: 600),
            .bytes(liveBytes: 900, newMax: 600))
    }

    func testBothCapsReducedIsReportedAsBoth() {
        XCTAssertEqual(
            clipdLimitReduction(liveCount: 60, liveBytes: 900,
                                maxEntries: 25, maxBytes: 600),
            .both(upTo: 35, newMaxEntries: 25, liveBytes: 900, newMaxBytes: 600))
    }

    // MARK: - Alert copy
    //
    // CLAUDE.md is explicit that an evicted entry lives on in the log until the
    // next compaction, and disappears for good at that point. So the alert may
    // promise NEITHER permanence nor recoverability — pin the wording here so a
    // later copy edit can't quietly overclaim in either direction.

    private var allReductionCopy: [String] {
        let cases: [ClipdLimitReduction] = [
            .count(upTo: 812, newMax: 500),
            .bytes(liveBytes: 900, newMax: 600),
            .both(upTo: 35, newMaxEntries: 25, liveBytes: 900, newMaxBytes: 600),
        ]
        return cases.flatMap { [$0.messageText, $0.informativeText] }
    }

    func testCopyNeverPromisesPermanenceOrRecoverability() {
        for text in allReductionCopy {
            let lowered = text.lowercased()
            for word in ["permanent", "forever", "restore", "recover", "undo"] {
                XCTAssertFalse(lowered.contains(word),
                               "alert copy must not say “\(word)”: \(text)")
            }
        }
    }

    func testCountCopyNamesTheBoundAsAnUpperBoundAndMentionsPinned() {
        let copy = ClipdLimitReduction.count(upTo: 812, newMax: 500)
        XCTAssertTrue(copy.messageText.contains("500"))
        // "up to", because pinned entries are exempt and the real number can be
        // smaller — ClipdStats carries no pinned count to make it exact.
        XCTAssertTrue(copy.informativeText.contains("812"))
        XCTAssertTrue(copy.informativeText.lowercased().contains("up to"))
        XCTAssertTrue(copy.informativeText.lowercased().contains("pinned"))
    }

    func testByteCopyNamesBothSizes() {
        let copy = ClipdLimitReduction.bytes(liveBytes: 400 * 1024 * 1024,
                                             newMax: 128 * 1024 * 1024)
        XCTAssertTrue(copy.informativeText.contains("400 MB"))
        XCTAssertTrue(copy.informativeText.contains("128 MB"))
    }

    func testNoneHasNoCopyToShow() {
        XCTAssertTrue(ClipdLimitReduction.none.messageText.isEmpty)
        XCTAssertTrue(ClipdLimitReduction.none.informativeText.isEmpty)
    }

    func testByteBudgetLabelsAreHumanReadable() {
        XCTAssertEqual(ClipdHistoryLimits.label(forBytes: 64 * 1024 * 1024), "64 MB")
        XCTAssertEqual(ClipdHistoryLimits.label(forBytes: 1024 * 1024 * 1024), "1 GB")
        XCTAssertEqual(ClipdHistoryLimits.label(forBytes: 4 * 1024 * 1024 * 1024), "4 GB")
    }
}

extension HistoryLimitsTests {
    /// A stored budget that isn't in the option set (an older default, or a
    /// hand-edited plist) still has to select something, or the picker renders
    /// blank and the first touch silently retunes the budget.
    func testNearestByteBudgetRoundsUpToAnOption() {
        XCTAssertEqual(ClipdHistoryLimits.nearestByteBudget(to: 100 * 1024 * 1024),
                       128 * 1024 * 1024)
        XCTAssertEqual(ClipdHistoryLimits.nearestByteBudget(to: 1),
                       64 * 1024 * 1024)
        XCTAssertEqual(ClipdHistoryLimits.nearestByteBudget(to: 1 << 40),
                       4 * 1024 * 1024 * 1024)  // above every option: clamp to the top
    }

    func testNearestByteBudgetKeepsAnExactOption() {
        for option in ClipdHistoryLimits.byteBudgetOptions {
            XCTAssertEqual(ClipdHistoryLimits.nearestByteBudget(to: option), option)
        }
    }
}

// MARK: - The "Keep at most" field
//
// Bugs 3 and 4 from the 2026-09-23 run-the-app test: the field accepted letters,
// and an out-of-range number was clamped and saved without a word.

extension HistoryLimitsTests {
    /// The filter runs on every edit, typed or pasted, so nothing but digits can
    /// sit in the box.
    func testDigitsOnlyDropsEverythingButDigits() {
        XCTAssertEqual(ClipdHistoryLimits.digitsOnly("12a3"), "123")
        XCTAssertEqual(ClipdHistoryLimits.digitsOnly("abc"), "")
        XCTAssertEqual(ClipdHistoryLimits.digitsOnly("10,000"), "10000")  // a pasted grouped number
        XCTAssertEqual(ClipdHistoryLimits.digitsOnly(" 2 0 0 "), "200")
        XCTAssertEqual(ClipdHistoryLimits.digitsOnly(""), "")
    }

    /// Swift counts these as whole numbers, but Int() can't parse them — let one
    /// in and the box holds a "number" that can never be applied.
    func testDigitsOnlyDropsNonASCIIDigits() {
        XCTAssertEqual(ClipdHistoryLimits.digitsOnly("٣٤"), "")   // Arabic-Indic 3, 4
        XCTAssertEqual(ClipdHistoryLimits.digitsOnly("１２"), "")  // full-width 1, 2
    }

    /// An in-range number that differs from the one in force is the only thing the
    /// field ever applies. Both bounds are inclusive.
    func testAnInRangeNumberIsAValidEdit() {
        XCTAssertEqual(ClipdEntriesEdit(text: "200", current: 10_000), .valid(200))
        XCTAssertEqual(ClipdEntriesEdit(text: "100", current: 10_000), .valid(100))
        XCTAssertEqual(ClipdEntriesEdit(text: "100000", current: 10_000), .valid(100_000))
        XCTAssertEqual(ClipdEntriesEdit(text: "0200", current: 10_000), .valid(200))
    }

    /// Refused, never clamped: a clamp applies a number nobody typed. "10000200"
    /// is how the 2026-09-23 run's cap became 100,000 — the caret landed after
    /// "10000" and "200" went on the end.
    func testAnOutOfRangeNumberIsInvalidNotClamped() {
        XCTAssertEqual(ClipdEntriesEdit(text: "10000200", current: 10_000), .invalid)
        XCTAssertEqual(ClipdEntriesEdit(text: "100001", current: 10_000), .invalid)
        XCTAssertEqual(ClipdEntriesEdit(text: "99", current: 10_000), .invalid)
        XCTAssertEqual(ClipdEntriesEdit(text: "0", current: 10_000), .invalid)
    }

    /// Too many digits for Int is just another out-of-range number — not a crash,
    /// and not a silent fallback to something else.
    func testANumberTooLongForIntIsInvalid() {
        let huge = String(repeating: "9", count: 25)
        XCTAssertEqual(ClipdEntriesEdit(text: huge, current: 10_000), .invalid)
    }

    /// Nothing to apply: an empty box (leaving it restores the value in force), or
    /// the number already in force however it's written. The in-force check comes
    /// before the range check, so a hand-edited value outside the UI's range can
    /// sit in the box without a beep every time the user clicks away.
    func testEmptyOrTheNumberInForceIsUnchanged() {
        XCTAssertEqual(ClipdEntriesEdit(text: "", current: 10_000), .unchanged)
        XCTAssertEqual(ClipdEntriesEdit(text: "10000", current: 10_000), .unchanged)
        XCTAssertEqual(ClipdEntriesEdit(text: "010000", current: 10_000), .unchanged)
        XCTAssertEqual(ClipdEntriesEdit(text: "500000", current: 500_000), .unchanged)
    }

    /// The caption is what keeps the box honest while it holds an unsaved number.
    /// A refused number must never be captioned as if Return would apply it.
    func testOnlyAValidEditIsCaptionedAsApplicable() {
        XCTAssertTrue(ClipdEntriesEdit.valid(200).caption.contains("Return"))
        XCTAssertFalse(ClipdEntriesEdit.invalid.caption.contains("Return"))
        XCTAssertFalse(ClipdEntriesEdit.unchanged.caption.contains("Return"))
    }
}
