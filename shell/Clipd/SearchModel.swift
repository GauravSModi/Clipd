import Foundation
import ClipdKit

/// View model for the search panel. Holds no history logic of its own — it asks
/// HistoryController to search (empty query → most recent) and writes a chosen
/// entry back to the pasteboard via the kit.
final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published var results: [Match] = []
    /// Highlighted row; arrow keys move it, Enter activates it. Defaults to 0 so
    /// Enter on a fresh panel still takes the top result.
    @Published var selectedIndex = 0

    private let controller: HistoryController

    /// Called when an entry is activated with the requested action (paste vs
    /// copy). The app layer owns the paste mechanics (prior-app reactivation,
    /// Accessibility check, ⌘V synthesis) and the panel dismissal.
    var onActivate: ((Match, ClipdPasteAction) -> Void)?

    init(controller: HistoryController) {
        self.controller = controller
    }

    func refresh() {
        results = (try? controller.search(query, maxResults: 50)) ?? []
        // Keep the selection valid as typing narrows the list.
        selectedIndex = clipdClampedSelection(selectedIndex, count: results.count)
    }

    /// Reset to the freshly-opened state: empty query showing most recent.
    func reset() {
        query = ""
        selectedIndex = 0
        refresh()
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
}
