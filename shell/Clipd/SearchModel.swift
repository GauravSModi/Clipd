import Foundation
import ClipdKit

/// View model for the search panel. Holds no history logic of its own — it asks
/// HistoryController to search (empty query → most recent) and writes a chosen
/// entry back to the pasteboard via the kit.
final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published var results: [Match] = []

    private let controller: HistoryController

    /// Called after an entry is chosen (copied back), so the panel can dismiss.
    var onChoose: (() -> Void)?

    init(controller: HistoryController) {
        self.controller = controller
    }

    func refresh() {
        results = (try? controller.search(query, maxResults: 50)) ?? []
    }

    /// Reset to the freshly-opened state: empty query showing most recent.
    func reset() {
        query = ""
        refresh()
    }

    func chooseFirst() {
        if let first = results.first { choose(first) }
    }

    func choose(_ match: Match) {
        SystemClipboardWriter.write(match.text)
        onChoose?()
    }
}
