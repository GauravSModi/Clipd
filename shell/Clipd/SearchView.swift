import SwiftUI
import AppKit
import ClipdKit

/// The unified search panel (PRD FR3+FR4 merged): a query field over a list of
/// matches. Empty query shows the most recent entries; Enter activates the
/// highlighted row; ⌘1–9 jump to the Nth recent; a click activates that row.
/// Each row may show a content-type affordance (open link / compose / swatch).
/// Arrow-key navigation is driven from AppDelegate's local key monitor.
struct SearchView: View {
    @ObservedObject var model: SearchModel
    @FocusState private var queryFocused: Bool

    var body: some View {
        let now = clipdNowMs()
        VStack(spacing: 0) {
            TextField("Search clipboard history…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($queryFocused)
                // Enter is handled by AppDelegate's key monitor (focus-independent),
                // so there's no `.onSubmit` here — see installKeyMonitor().
                .onChange(of: model.query) { _ in model.refresh() }

            Divider()

            if model.results.isEmpty {
                Spacer()
                Text(model.query.isEmpty ? "No clipboard history yet" : "No matches")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                resultsList(now: now)
            }

            Divider()
            Text("Stored locally in plain text. Concealed/transient copies are skipped, but the history is not encrypted.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 540, height: 420)
        .background(recentShortcutButtons)
        .onAppear { queryFocused = true }
        // Re-grab focus every time the panel is shown: the app layer bumps
        // focusNonce after the panel becomes key. `.onAppear` alone fires only on
        // the first open (the panel is reused, never released), and too early.
        .onChange(of: model.focusNonce) { _ in queryFocused = true }
    }

    private func resultsList(now: Int64) -> some View {
        let pinnedCount = model.pinnedCount
        let total = model.results.count
        return ScrollViewReader { proxy in
            List {
                if pinnedCount > 0 {
                    Section(header: Text("Pinned")) {
                        rows(in: 0..<pinnedCount, now: now)
                    }
                    if pinnedCount < total {
                        Section(header: Text("Recent")) {
                            rows(in: pinnedCount..<total, now: now)
                        }
                    }
                } else {
                    rows(in: 0..<total, now: now)
                }
            }
            .listStyle(.plain)
            .onChange(of: model.selectedIndex) { proxy.scrollTo($0, anchor: .center) }
        }
    }

    /// Render rows for a flat index range into `model.results`. Indices stay flat
    /// (across both sections) so keyboard selection and ⌘1–9 are unaffected.
    @ViewBuilder
    private func rows(in range: Range<Int>, now: Int64) -> some View {
        ForEach(range, id: \.self) { index in
            let match = model.results[index]
            row(match, now: now)
                .id(index)
                .contentShape(Rectangle())
                .listRowBackground(index == model.selectedIndex
                                   ? Color.accentColor.opacity(0.20)
                                   : Color.clear)
                .onTapGesture {
                    // ⌘-click copies only; a plain click pastes back.
                    let copy = NSEvent.modifierFlags.contains(.command)
                    model.choose(match, copy ? .copy : .paste)
                }
        }
    }

    private func row(_ match: Match, now: Int64) -> some View {
        HStack(alignment: .top, spacing: 8) {
            leading(match)

            VStack(alignment: .leading, spacing: 2) {
                Text(match.text)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(clipdRelativeTime(fromEpochMs: match.timestamp, nowMs: now))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // URL/email/hex affordances are only meaningful for text entries.
            if match.kind == .text {
                affordance(for: match.text)
            }
            pinButton(match)
            deleteButton(match)
        }
        .help(clipdAbsoluteTime(fromEpochMs: match.timestamp))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(match.text), copied \(clipdAbsoluteTime(fromEpochMs: match.timestamp))")
    }

    /// Star toggle: pins / unpins the row (its own hit target, so it doesn't fire
    /// the row's tap-to-paste). The row re-sorts into the Pinned section on pin.
    private func pinButton(_ match: Match) -> some View {
        Button { model.togglePin(match) } label: {
            Image(systemName: match.pinned ? "star.fill" : "star")
                .foregroundStyle(match.pinned ? Color.accentColor : .secondary)
        }
        .buttonStyle(.borderless)
        .help(match.pinned ? "Unpin" : "Pin")
        .accessibilityLabel(match.pinned ? "Unpin" : "Pin")
    }

    /// Per-row delete. Unpinned deletes are instant; deleting a pinned row goes
    /// through the app layer's confirmation (SearchModel.delete decides).
    private func deleteButton(_ match: Match) -> some View {
        Button { model.delete(match) } label: {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Delete")
        .accessibilityLabel("Delete")
    }

    /// A leading icon per kind: an ImageIO-downsampled thumbnail for images, the
    /// system file icon for files, nothing for text.
    @ViewBuilder
    private func leading(_ match: Match) -> some View {
        switch match.kind {
        case .image:
            if let thumb = model.thumbnail(for: match) {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
            } else {
                Image(systemName: "photo")
                    .frame(width: 40, height: 40)
                    .foregroundStyle(.secondary)
            }
        case .file:
            Image(nsImage: NSWorkspace.shared.icon(forFile: match.text))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
        case .text:
            EmptyView()
        }
    }

    /// A trailing affordance for the detected content type. The Buttons are their
    /// own hit targets, so they don't fight the row's tap-to-copy gesture; the hex
    /// swatch is non-interactive. Opening a link/mail activates another app, which
    /// auto-dismisses the panel via windowDidResignKey (expected).
    @ViewBuilder
    private func affordance(for text: String) -> some View {
        switch clipdDetectContentType(text) {
        case .url(let url):
            Button { NSWorkspace.shared.open(url) } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Open link")
            .accessibilityLabel("Open link")
        case .email(let url):
            Button { NSWorkspace.shared.open(url) } label: {
                Image(systemName: "envelope")
            }
            .buttonStyle(.borderless)
            .help("Compose email")
            .accessibilityLabel("Compose email")
        case .hexColor(let rgb):
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: Double(rgb.red) / 255,
                            green: Double(rgb.green) / 255,
                            blue: Double(rgb.blue) / 255))
                .frame(width: 18, height: 18)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.4)))
                .accessibilityLabel("Color swatch")
        case .plain:
            EmptyView()
        }
    }

    /// Invisible keyboard-shortcut buttons (shortcuts work regardless of
    /// visibility): ⌘1–9 paste the Nth recent, and ⌘↵ copies the selection
    /// without pasting. The .command modifier means plain digit/return keys still
    /// type / submit in the field.
    private var recentShortcutButtons: some View {
        ZStack {
            ForEach(1...9, id: \.self) { n in
                Button("") { model.chooseRecent(n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
            Button("") { model.chooseSelected(.copy) }
                .keyboardShortcut(.return, modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
