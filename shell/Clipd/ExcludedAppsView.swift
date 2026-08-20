import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ClipdKit

/// The editable list of apps whose copies Clipd skips by source app. Lives in the
/// Clipd target rather than ClipdKit because it needs NSWorkspace/NSOpenPanel —
/// the same reason ClipdLoginItem sits in SettingsView.swift.
///
/// The view holds no list logic: add/remove/de-dupe are ClipdSettings' job, so the
/// stored list has exactly one owner.
struct ExcludedAppsView: View {
    @ObservedObject var settings: ClipdSettings
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            List(settings.excludedSourceApps, id: \.self, selection: $selection) { bundleID in
                ExcludedAppRow(bundleID: bundleID)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 104)

            HStack(spacing: 10) {
                Button(action: addApp) { Image(systemName: "plus") }
                    .help("Choose an app to exclude")
                // Removal is trivially reversible (re-add via the picker), so it
                // needs no confirmation — unlike deleting a pinned entry.
                Button(action: removeSelected) { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    .help("Stop excluding the selected app")
                Spacer()
            }
            .buttonStyle(.bordered)
        }
    }

    /// Pick a real app rather than asking the user to type `com.apple.Passwords`
    /// by hand; the bundle id comes from the chosen bundle itself.
    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose an app whose copies Clipd should skip."
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            // An app bundle without an identifier can't be matched against the
            // frontmost app, so there is nothing useful to store for it.
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
            settings.addExcludedApp(bundleID)
        }
    }

    private func removeSelected() {
        guard let selection else { return }
        settings.removeExcludedApp(selection)
        self.selection = nil
    }
}

/// One row: the app's display name over its bundle id. An app that isn't installed
/// (or was since removed) shows only its bundle id, so the rule stays readable and
/// the user can still keep or delete it.
private struct ExcludedAppRow: View {
    let bundleID: String

    var body: some View {
        let name = clipdAppDisplayName(bundleID: bundleID)
        VStack(alignment: .leading, spacing: 1) {
            Text(name ?? bundleID)
            if name != nil {
                Text(bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }
}

/// "com.apple.Passwords" → "Passwords", or nil when the app can't be resolved.
func clipdAppDisplayName(bundleID: String) -> String? {
    guard let url = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: bundleID) else { return nil }
    return FileManager.default.displayName(atPath: url.path)
}
