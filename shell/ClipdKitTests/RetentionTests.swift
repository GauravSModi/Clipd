import XCTest
@testable import ClipdKit

/// The pure retention helpers: the periods the History tab offers, the cutoff
/// math the sweep runs on, and the decision about whether a proposed period
/// change would start deleting things (which is what gates the confirmation).
///
/// Every cutoff assertion uses a fixed `now`. Nothing here reads the wall clock.
final class RetentionTests: XCTestCase {

    // MARK: - Options

    /// Unlike the Stage 4 caps, retention DOES offer a "never" row: it is the
    /// current behavior, the default, and a completely normal choice.
    func testOptionsLeadWithNeverAndAscend() {
        XCTAssertEqual(ClipdRetention.dayOptions, [0, 7, 30, 90, 365])
        XCTAssertEqual(ClipdRetention.defaultDays, 0)
        XCTAssertTrue(ClipdRetention.dayOptions.contains(ClipdRetention.defaultDays))
    }

    func testLabelsReadAsPeriods() {
        XCTAssertEqual(ClipdRetention.label(forDays: 0), "Never")
        XCTAssertEqual(ClipdRetention.label(forDays: 7), "7 days")
        XCTAssertEqual(ClipdRetention.label(forDays: 90), "90 days")
        XCTAssertEqual(ClipdRetention.label(forDays: 365), "1 year")
    }

    /// A junk or unknown stored value must fall back to Never — the direction
    /// that deletes nothing. Falling back to some arbitrary period would start
    /// destroying history off a corrupt plist.
    func testSanitizeFallsBackToNeverNotToAPeriod() {
        XCTAssertEqual(ClipdRetention.sanitize(30), 30)
        XCTAssertEqual(ClipdRetention.sanitize(0), 0)
        XCTAssertEqual(ClipdRetention.sanitize(-7), 0)
        XCTAssertEqual(ClipdRetention.sanitize(13), 0)      // not an offered option
        XCTAssertEqual(ClipdRetention.sanitize(Int.max), 0)
    }

    // MARK: - Cutoff

    func testNeverHasNoCutoffSoTheSweepIsANoOp() {
        XCTAssertNil(ClipdRetention.cutoffMs(now: 1_000_000_000_000, days: 0))
    }

    func testCutoffIsNowMinusThePeriod() {
        let now: Int64 = 1_000_000_000_000
        let day: Int64 = 86_400_000
        XCTAssertEqual(ClipdRetention.cutoffMs(now: now, days: 7), now - 7 * day)
        XCTAssertEqual(ClipdRetention.cutoffMs(now: now, days: 365), now - 365 * day)
    }

    /// A nonsensical period can't produce a cutoff in the future, which would
    /// sweep the entire history.
    func testNegativePeriodHasNoCutoff() {
        XCTAssertNil(ClipdRetention.cutoffMs(now: 1_000, days: -5))
    }

    // MARK: - Change detection

    func testShorteningThePeriodAsksFirst() {
        XCTAssertEqual(clipdRetentionChange(currentDays: 90, proposedDays: 30),
                       .shortens(toDays: 30))
    }

    /// Never → a period is the biggest shortening there is: nothing expired
    /// before, and now things start to.
    func testTurningExpiryOnAsksFirst() {
        XCTAssertEqual(clipdRetentionChange(currentDays: 0, proposedDays: 7),
                       .shortens(toDays: 7))
    }

    /// Lengthening and choosing Never delete nothing, so they apply silently —
    /// the same rule Stage 4 uses for raising a cap.
    func testLengtheningAndNeverApplySilently() {
        XCTAssertEqual(clipdRetentionChange(currentDays: 7, proposedDays: 90), .none)
        XCTAssertEqual(clipdRetentionChange(currentDays: 30, proposedDays: 0), .none)
        XCTAssertEqual(clipdRetentionChange(currentDays: 0, proposedDays: 0), .none)
        XCTAssertEqual(clipdRetentionChange(currentDays: 30, proposedDays: 30), .none)
    }

    // MARK: - Copy
    //
    // The wording is pinned here, not just reviewed once: it has to stay honest
    // about what expiry does and does not promise.

    func testRetentionAlertNamesThePeriodAndThePinnedExemption() {
        let change = ClipdRetentionChange.shortens(toDays: 30)
        XCTAssertTrue(change.messageText.contains("30 days"))
        XCTAssertTrue(change.informativeText.lowercased().contains("pinned"))
    }

    /// Expiry is removal, not secure erase, and an expired entry is not
    /// retrievable either — so the copy must promise NEITHER permanence NOR
    /// recoverability. This is the most tempting place in the project to
    /// overclaim privacy.
    func testRetentionAlertPromisesNeitherPermanenceNorRecovery() {
        let text = (ClipdRetentionChange.shortens(toDays: 7).messageText + " "
            + ClipdRetentionChange.shortens(toDays: 7).informativeText).lowercased()
        for forbidden in ["permanent", "erase", "wipe", "secure",
                          "recover", "restore", "undo", "undone"] {
            XCTAssertFalse(text.contains(forbidden),
                           "retention alert must not say “\(forbidden)”")
        }
    }

    func testNoChangeHasNoCopyToShow() {
        XCTAssertEqual(ClipdRetentionChange.none.messageText, "")
        XCTAssertEqual(ClipdRetentionChange.none.informativeText, "")
    }

    /// The one fact the alert must carry: clearing keeps pinned entries.
    func testClearOnQuitCopyNamesThePinnedExemption() {
        let text = (ClipdClearOnQuit.messageText + " "
            + ClipdClearOnQuit.informativeText).lowercased()
        XCTAssertTrue(text.contains("unpinned"))
        XCTAssertTrue(text.contains("pinned entries are kept"))
    }

    /// Kept short on purpose (2026-09-29): the best-effort and slow-quit caveats
    /// were cut from the alert, so it says only what switching this on does.
    func testClearOnQuitCopyStaysShort() {
        XCTAssertLessThanOrEqual(ClipdClearOnQuit.informativeText.count, 90)
    }

    func testClearOnQuitCopyDoesNotOverclaimErasure() {
        let text = (ClipdClearOnQuit.messageText + " "
            + ClipdClearOnQuit.informativeText).lowercased()
        for forbidden in ["permanent", "erase", "wipe", "secure"] {
            XCTAssertFalse(text.contains(forbidden),
                           "clear-on-quit copy must not say “\(forbidden)”")
        }
    }
}
