// Pure index math for keyboard selection in the search panel. Holds no history
// logic (no dedup/scoring/storage) and never touches the core or store — just
// arithmetic on a selected row (plus, for where a fresh list starts, a read of the
// rows' timestamps), kept in the UI-free layer so it's testable. The SwiftUI focus
// wiring that calls these lives in the app and is run-the-app only.

import Foundation

/// Move the selection by `delta` (e.g. -1 for ↑, +1 for ↓), clamped to the
/// valid range. No wrap; an empty list selects 0.
public func clipdMovedSelection(_ index: Int, by delta: Int, count: Int) -> Int {
    clipdClampedSelection(index + delta, count: count)
}

/// Re-clamp a selection to `[0, count-1]` after the result set changes (typing
/// filters the list). An empty list selects 0.
public func clipdClampedSelection(_ index: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return min(max(index, 0), count - 1)
}

/// Map a ⌘1–9 shortcut to the (N-1)th row, or nil when out of range / no such row.
public func clipdRecentIndex(forShortcut n: Int, count: Int) -> Int? {
    guard n >= 1, n <= count else { return nil }
    return n - 1
}

/// Where the highlight starts in a fresh list — the panel opening (empty query) or
/// a new search.
///
/// A search starts on its top match. The empty query starts on the newest copy,
/// found by timestamp rather than position: the core lists starred rows first, so
/// the newest copy can sit below any number of older starred ones. A starred row
/// wins only when it is itself the newest (re-copying an entry, or pasting it from
/// Clipd, bumps its timestamp). Ties keep the earlier row; an empty list selects 0.
public func clipdDefaultSelection(query: String, results: [Match]) -> Int {
    guard query.isEmpty else { return 0 }
    var newest = 0
    for index in results.indices where results[index].timestamp > results[newest].timestamp {
        newest = index
    }
    return newest
}
