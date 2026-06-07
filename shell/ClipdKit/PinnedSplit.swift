// Pure presentation helper: where does the pinned section end? The core returns
// pinned matches as a contiguous leading run (pinned-first ordering), so the
// view draws a "Pinned" section over the prefix and "Recent" over the rest. Like
// SelectionIndex, this holds no history logic and never touches the core/store.

import Foundation

/// The number of leading pinned matches (the boundary between the pinned section
/// and the rest). Stops at the first unpinned match, matching the core's
/// pinned-first ordering.
public func clipdPinnedPrefixCount(_ matches: [Match]) -> Int {
    var count = 0
    for match in matches {
        if match.pinned { count += 1 } else { break }
    }
    return count
}
