// Pure presentation helpers for showing a copy timestamp in the search panel.
// They hold no history logic (no dedup/scoring/storage) and never touch the
// core or store — formatting only, kept in the UI-free layer so it's testable.

import Foundation

/// Compact, locale-free "time ago" for a copy timestamp, relative to `nowMs`
/// (both epoch ms). Clock skew — a timestamp ahead of now — clamps to "just now".
public func clipdRelativeTime(fromEpochMs ts: Int64, nowMs: Int64) -> String {
    let deltaMs = nowMs - ts
    guard deltaMs >= 60_000 else { return "just now" }

    let minutes = deltaMs / 60_000
    if minutes < 60 { return "\(minutes)m ago" }

    let hours = minutes / 60
    if hours < 24 { return "\(hours)h ago" }

    let days = hours / 24
    if days < 7 { return "\(days)d ago" }

    return "\(days / 7)w ago"
}

/// Exact copy time for the row tooltip + accessibility label. Locale- and
/// timezone-dependent, so its exact string is not asserted in tests.
public func clipdAbsoluteTime(fromEpochMs ts: Int64) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: Date(timeIntervalSince1970: Double(ts) / 1000))
}
