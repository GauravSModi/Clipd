import AppKit
import Foundation
import ClipdKit

/// View model for the search panel. Holds no history logic of its own — it asks
/// HistoryController to search (empty query → most recent) and writes a chosen
/// entry back to the pasteboard via the kit.
final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published var results: [Match] = []
    /// Highlighted row; arrow keys move it, Enter activates it. A fresh list starts
    /// it where clipdDefaultSelection says: on the newest copy when the panel
    /// opens (which can sit below older starred rows), on the top match for a
    /// search.
    @Published var selectedIndex = 0
    /// Bumped by the app layer each time the panel is shown. The view watches it
    /// and re-grabs keyboard focus for the search field. We can't rely on
    /// SwiftUI's `.onAppear` alone: the panel is reused (never released), so
    /// `.onAppear` fires only on the very first open — and even then the panel
    /// isn't key yet, so the focus request is dropped. A changing value the view
    /// can observe lets us re-focus on every open, after the panel is key.
    @Published var focusNonce = 0

    let controller: HistoryController
    /// Image thumbnails keyed by blob id. ImageIO downsamples on first access; the
    /// cache survives across redraws so we don't re-decode every keystroke.
    private var thumbnailCache: [String: NSImage] = [:]

    /// Called when an entry is activated with the requested action (paste vs
    /// copy). The app layer owns the paste mechanics (prior-app reactivation,
    /// Accessibility check, ⌘V synthesis) and the panel dismissal.
    var onActivate: ((Match, ClipdPasteAction) -> Void)?

    /// Called to confirm deleting a *pinned* row before it happens (the app layer
    /// owns the AppKit alert). On confirmation it calls back into performDelete.
    /// Unpinned deletes are instant and never go through here.
    var onConfirmDelete: ((Match) -> Void)?

    init(controller: HistoryController) {
        self.controller = controller
    }

    /// Re-run the search and keep the highlight where it was (clamped). For when
    /// the rows themselves change — pin, delete, clear — and the user's place in
    /// the list still means something.
    func refresh() {
        runSearch()
        selectedIndex = clipdClampedSelection(selectedIndex, count: results.count)
    }

    /// The query changed (or the panel opened): re-run the search and start the
    /// highlight fresh. The old row position means nothing in a new list — kept,
    /// it would land on an arbitrary row.
    func queryDidChange() {
        runSearch()
        selectedIndex = clipdDefaultSelection(query: query, results: results)
    }

    /// Reset to the freshly-opened state: empty query, newest copy highlighted.
    func reset() {
        query = ""
        queryDidChange()
    }

    private func runSearch() {
        results = (try? controller.search(query, maxResults: 50)) ?? []
    }

    /// Move the highlight (delta -1 for ↑, +1 for ↓), clamped to the result range.
    func moveSelection(by delta: Int) {
        selectedIndex = clipdMovedSelection(selectedIndex, by: delta, count: results.count)
    }

    /// Activate the highlighted row (Enter pastes, ⌘↵ copies).
    func chooseSelected(_ action: ClipdPasteAction = .paste) {
        guard results.indices.contains(selectedIndex) else { return }
        choose(results[selectedIndex], action)
    }

    /// Activate the Nth recent row for a ⌘1–9 shortcut (no-op when out of range).
    func chooseRecent(_ n: Int, _ action: ClipdPasteAction = .paste) {
        guard let index = clipdRecentIndex(forShortcut: n, count: results.count) else { return }
        choose(results[index], action)
    }

    func choose(_ match: Match, _ action: ClipdPasteAction = .paste) {
        onActivate?(match, action)
    }

    /// Number of leading pinned results — the boundary the view uses to draw the
    /// "Pinned" section (the core returns pinned matches as a contiguous prefix).
    var pinnedCount: Int { clipdPinnedPrefixCount(results) }

    /// Toggle the pin state of a row, then refresh (the row re-sorts into / out of
    /// the pinned section).
    func togglePin(_ match: Match) {
        try? controller.setPinned(match.id, !match.pinned)
        refresh()
    }

    /// Delete a row. Unpinned: instant. Pinned: route through the app layer's
    /// confirmation, which calls performDelete on confirm.
    func delete(_ match: Match) {
        if match.pinned {
            onConfirmDelete?(match)
        } else {
            performDelete(match)
        }
    }

    /// Actually delete (after any confirmation) and refresh.
    func performDelete(_ match: Match) {
        try? controller.delete(id: match.id)
        refresh()
    }

    /// Clear history (keeps pinned entries) and refresh. Confirmation is the app
    /// layer's job before calling this.
    func clearHistory() {
        try? controller.clear()
        refresh()
    }

    /// A bounded thumbnail for an image match, or nil for other kinds / missing
    /// blob / decode failure.
    func thumbnail(for match: Match, maxPixel: Int = 64) -> NSImage? {
        guard match.kind == .image else { return nil }
        if let cached = thumbnailCache[match.id] { return cached }
        guard let data = controller.readBlob(id: match.id),
              let image = clipdThumbnail(from: data, maxPixel: maxPixel) else {
            return nil
        }
        thumbnailCache[match.id] = image
        return image
    }
}
