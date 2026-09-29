// HistoryLimits — the pure pieces behind the History settings tab: the bounds the
// UI enforces, the verdict on what the entries field holds, and the decision
// about whether a proposed pair of caps would actually evict anything (which is
// what gates the confirmation alert).
//
// Pure and UI-free like the other kit helpers. It produces display strings the
// same way RelativeTime does, so the alert's wording can be pinned by a test —
// that copy has to stay honest, and the rule is subtle enough to be worth a test
// rather than a comment (see ClipdLimitReduction below).
//
// It holds no eviction logic: the C++ ClipStore is and stays the sole eviction
// authority. This only predicts whether calling the setter would evict, so the
// shell knows when to ask first.

import Foundation

public enum ClipdHistoryLimits {
    /// The count range the UI offers. Deliberately bounded with no "unlimited"
    /// option: clipd.h documents max_entries 0 as no count cap, but a UI that can
    /// produce 0 would also hand ClipdSettings.positiveInt a value it treats as
    /// corrupt. The 0-means-unbounded C contract is unchanged for API callers.
    public static let minEntries = 100
    public static let maxEntries = 100_000

    private static let mb: UInt64 = 1024 * 1024
    private static let gb: UInt64 = 1024 * 1024 * 1024

    /// The storage-budget choices, ascending. A picker rather than a field: a
    /// byte count is not something anyone wants to type, and a fixed option set
    /// can't produce a half-typed value mid-edit. Never contains 0, for the same
    /// reason the count range is bounded.
    public static let byteBudgetOptions: [UInt64] = [
        64 * mb, 128 * mb, 256 * mb, 512 * mb, gb, 2 * gb, 4 * gb,
    ]

    /// The option to show for a stored budget that isn't itself an option (an
    /// older default, or a hand-edited plist). Rounds UP to the next option so a
    /// merely-displayed value never implies a tighter budget than is in force;
    /// nothing is written until the user actually commits a change.
    public static func nearestByteBudget(to bytes: UInt64) -> UInt64 {
        byteBudgetOptions.first { $0 >= bytes } ?? byteBudgetOptions[byteBudgetOptions.count - 1]
    }

    /// Binary units ("64 MB" for 64 MiB), matching how the caps are actually
    /// defined. ByteCountFormatter's default is decimal and would render the same
    /// budget as "68 MB", which then wouldn't match the picker's own label.
    public static func label(forBytes bytes: UInt64) -> String {
        if bytes >= gb, bytes % gb == 0 { return "\(bytes / gb) GB" }
        if bytes >= gb { return "\(rounded(bytes, unit: mb)) MB" }
        if bytes >= mb { return "\(rounded(bytes, unit: mb)) MB" }
        if bytes >= 1024 { return "\(rounded(bytes, unit: 1024)) KB" }
        return "\(bytes) bytes"
    }

    private static func rounded(_ bytes: UInt64, unit: UInt64) -> UInt64 {
        (bytes + unit / 2) / unit
    }

    /// The "Keep at most" field's keystroke filter, run on every edit (typed or
    /// pasted) so the box only ever holds digits. ASCII only on purpose:
    /// `Character.isWholeNumber` also accepts other scripts' digits ("٣", "１"),
    /// which `Int()` can't parse.
    public static func digitsOnly(_ text: String) -> String {
        text.filter { $0.isASCII && $0.isNumber }
    }
}

/// What the "Keep at most" field holds, judged against the count in force — the
/// one decision behind both the field's commit and its caption.
///
/// An out-of-range number is `.invalid` and is refused, never clamped: a clamp
/// saves a number nobody typed, which is how the 2026-09-23 run's cap silently
/// became 100,000.
public enum ClipdEntriesEdit: Equatable {
    /// Nothing to apply: the box is empty (leaving it restores the count in
    /// force) or already holds that count.
    case unchanged
    /// An in-range count that differs from the one in force.
    case valid(Int)
    /// Out of range, or too many digits to be a count at all.
    case invalid

    /// `text` is normally digits already (see `digitsOnly`); anything that still
    /// fails to parse comes out `.invalid`.
    public init(text: String, current: Int) {
        guard !text.isEmpty else { self = .unchanged; return }
        guard let count = Int(text) else { self = .invalid; return }  // overflows Int
        if count == current {
            // Before the range check: a hand-edited count outside the UI's range
            // can sit in the box without a beep every time the user clicks away.
            self = .unchanged
        } else if (ClipdHistoryLimits.minEntries...ClipdHistoryLimits.maxEntries).contains(count) {
            self = .valid(count)
        } else {
            self = .invalid
        }
    }

    /// The line under the field. The box can hold a count that isn't in force
    /// yet (mid-edit, or the window was closed before a commit), so the caption
    /// is what keeps it from ever doing that silently.
    public var caption: String {
        let low = ClipdHistoryLimits.minEntries.formatted()
        let high = ClipdHistoryLimits.maxEntries.formatted()
        switch self {
        case .unchanged: return "\(low)–\(high) entries."
        case .valid: return "Press Return to apply."
        case .invalid: return "Enter a number from \(low) to \(high)."
        }
    }
}

/// What a proposed pair of caps would do to the CURRENT live set — the question
/// the confirmation alert is asking. Compared against live state rather than the
/// old caps, so lowering a cap that is still above the live count comes out
/// `.none` and applies silently, as does raising one.
///
/// The counts are **upper bounds**, never exact: pinned entries are exempt from
/// both caps, and ClipdStats carries no pinned count, so the real number of
/// removed entries can be smaller. A byte reduction gets no count at all — the
/// shell knows only the summed byte total, not the per-entry sizes.
public enum ClipdLimitReduction: Equatable {
    case none
    case count(upTo: Int, newMax: Int)
    case bytes(liveBytes: UInt64, newMax: UInt64)
    case both(upTo: Int, newMaxEntries: Int, liveBytes: UInt64, newMaxBytes: UInt64)

    public var messageText: String {
        switch self {
        case .none:
            return ""
        case .count(_, let newMax):
            return "Keep only \(Self.grouped(newMax)) entries?"
        case .bytes(_, let newMax):
            return "Reduce the storage budget to \(ClipdHistoryLimits.label(forBytes: newMax))?"
        case .both:
            return "Reduce Clipd’s history limits?"
        }
    }

    /// The honest line is "removed from your history now". It must promise
    /// NEITHER permanence nor recoverability: an evicted entry's log record
    /// survives until the next compaction (so "permanently deleted" would be
    /// wrong), and it is dropped for good at that point (so offering to restore
    /// it would be wrong too). A test pins both halves of that.
    public var informativeText: String {
        switch self {
        case .none:
            return ""
        case .count(let upTo, _):
            return "Up to \(Self.grouped(upTo)) entries will be removed from your "
                + "history now. Pinned entries are kept."
        case .bytes(let liveBytes, let newMax):
            return "Clipd’s history is using \(ClipdHistoryLimits.label(forBytes: liveBytes)) "
                + "right now. Entries beyond the new "
                + "\(ClipdHistoryLimits.label(forBytes: newMax)) budget are removed from "
                + "your history immediately. Pinned entries are kept."
        case .both(let upTo, _, let liveBytes, let newMaxBytes):
            return "Up to \(Self.grouped(upTo)) entries will be removed from your history "
                + "now, and the storage budget drops from "
                + "\(ClipdHistoryLimits.label(forBytes: liveBytes)) of current usage to "
                + "\(ClipdHistoryLimits.label(forBytes: newMaxBytes)). Pinned entries are kept."
        }
    }

    private static func grouped(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? String(count)
    }
}

/// Whether applying `maxEntries`/`maxBytes` to a live set of `liveCount` entries
/// totalling `liveBytes` would evict anything — and if so, what to say about it.
/// A 0 cap means unbounded (the clipd.h contract), so it never evicts.
public func clipdLimitReduction(liveCount: Int, liveBytes: UInt64,
                                maxEntries: Int, maxBytes: UInt64) -> ClipdLimitReduction {
    let overCount = maxEntries > 0 && liveCount > maxEntries
    let overBytes = maxBytes > 0 && liveBytes > maxBytes
    switch (overCount, overBytes) {
    case (false, false):
        return .none
    case (true, false):
        return .count(upTo: liveCount - maxEntries, newMax: maxEntries)
    case (false, true):
        return .bytes(liveBytes: liveBytes, newMax: maxBytes)
    case (true, true):
        return .both(upTo: liveCount - maxEntries, newMaxEntries: maxEntries,
                     liveBytes: liveBytes, newMaxBytes: maxBytes)
    }
}
