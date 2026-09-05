// Retention — the pure pieces behind the History tab's age-expiry control: the
// periods the UI offers, the cutoff the sweep runs on, and the decision about
// whether a proposed period change would start deleting things (which is what
// gates the confirmation alert).
//
// Pure and UI-free like the other kit helpers, and — like HistoryLimits — it owns
// its user-facing copy so the wording can be pinned by a test. That matters more
// here than anywhere else in the project: expiry is the most tempting place to
// overclaim privacy, and the honest position is narrow. Expiry is REMOVAL, not
// secure erase; an expired entry is also not retrievable. So the copy must
// promise neither permanence nor recoverability, and must say that pinned
// entries never expire.
//
// It holds no deletion logic: the C++ Core does the sweep (riding the existing
// TOMBSTONE control record). This only decides when to sweep and what to say.

import Foundation

public enum ClipdRetention {
    /// Milliseconds in a day — the unit the C API's `cutoff_ms` is expressed in.
    private static let msPerDay: Int64 = 86_400_000

    /// The periods the UI offers, in days, with **0 meaning never**.
    ///
    /// Stage 4 deliberately gave the history caps no "unlimited" option, because
    /// a 0 cap is a value ClipdSettings treats as corrupt. Retention is the
    /// opposite case: never-expiring is the current behavior, the shipped
    /// default, and a completely normal choice — so it gets a real row.
    public static let dayOptions = [0, 7, 30, 90, 365]

    /// Never. Age expiry is opt-in: an app that silently started deleting history
    /// on upgrade would be a bad surprise.
    public static let defaultDays = 0

    public static func label(forDays days: Int) -> String {
        switch days {
        case 0: return "Never"
        case 365: return "1 year"
        default: return "\(days) days"
        }
    }

    /// Coerce a stored value to an offered option, falling back to **Never** —
    /// the direction that deletes nothing. A corrupt or stale plist value must
    /// never be read as some arbitrary period and start destroying history.
    public static func sanitize(_ days: Int) -> Int {
        dayOptions.contains(days) ? days : defaultDays
    }

    /// The epoch-ms cutoff for a sweep at `now`, or nil when nothing expires.
    /// A non-positive period yields nil rather than a cutoff at or after `now`,
    /// which would sweep the entire history.
    public static func cutoffMs(now: Int64, days: Int) -> Int64? {
        guard days > 0 else { return nil }
        return now - Int64(days) * msPerDay
    }
}

/// What a proposed retention period would do — the question the confirmation is
/// asking. Only a **shortening** (including Never → a period) starts deleting
/// things; lengthening the period or choosing Never deletes nothing and applies
/// silently, the same rule Stage 4 uses for raising a cap.
///
/// No count is named. The shell would need a dry-run pass to know one, and
/// Stage 4's byte case already set the precedent of naming the change rather
/// than a number.
public enum ClipdRetentionChange: Equatable {
    case none
    case shortens(toDays: Int)

    public var messageText: String {
        switch self {
        case .none:
            return ""
        case .shortens(let days):
            return "Delete entries older than \(ClipdRetention.label(forDays: days))?"
        }
    }

    /// Deliberately promises neither permanence nor recoverability, and states
    /// the pinned exemption — a pinned entry never expires, so this is not a
    /// blanket guarantee that nothing older survives. A test pins all of that.
    public var informativeText: String {
        switch self {
        case .none:
            return ""
        case .shortens:
            return "Clipd removes older entries from your history now, and keeps "
                + "doing so as entries age. Pinned entries never expire, so some "
                + "older entries can remain."
        }
    }
}

/// Whether moving from `currentDays` to `proposedDays` would start deleting
/// entries. Both are day counts with 0 meaning never.
public func clipdRetentionChange(currentDays: Int,
                                 proposedDays: Int) -> ClipdRetentionChange {
    guard proposedDays > 0 else { return .none }              // Never deletes nothing
    guard currentDays <= 0 || proposedDays < currentDays else { return .none }
    return .shortens(toDays: proposedDays)
}

/// The confirmation shown when clear-on-quit is switched ON. There is
/// deliberately no confirmation at quit time — the user opted in here, and a
/// dialog on every quit is the kind people learn to dismiss without reading.
///
/// It names the three things that surprise people: it keeps pinned entries
/// (the core's clear is clear-unpinned), it is best-effort, and it can make
/// quitting slow because clearing rewrites the log.
public enum ClipdClearOnQuit {
    public static let messageText = "Clear Clipd’s history every time you quit?"
    public static let informativeText =
        "Each time Clipd quits normally it removes every unpinned entry from your "
        + "history. Pinned entries are kept. This is best-effort — a force quit, a "
        + "crash, or a sudden logout skips it — and on a large history, quitting "
        + "can take a moment."
}
