import SwiftUI
import ClipdKit

/// The unified search panel (PRD FR3+FR4 merged): a query field over a list of
/// matches. Empty query shows the most recent entries; Enter copies the top
/// result; a click copies that row. Both copy back to the system pasteboard.
struct SearchView: View {
    @ObservedObject var model: SearchModel
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search clipboard history…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($queryFocused)
                .onSubmit { model.chooseFirst() }
                .onChange(of: model.query) { _ in model.refresh() }

            Divider()

            if model.results.isEmpty {
                Spacer()
                Text(model.query.isEmpty ? "No clipboard history yet" : "No matches")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(Array(model.results.enumerated()), id: \.offset) { _, match in
                        Text(match.text)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { model.choose(match) }
                    }
                }
                .listStyle(.plain)
            }

            Divider()
            Text("Stored locally in plain text. Concealed/transient copies are skipped, but the history is not encrypted.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 540, height: 420)
        .onAppear { queryFocused = true }
    }
}
