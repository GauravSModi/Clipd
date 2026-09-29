import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ClipdKit

/// The editable list of apps whose copies Clipd skips by source app. Lives in the
/// Clipd target rather than ClipdKit because it needs NSWorkspace/NSOpenPanel —
/// the same reason ClipdLoginItem sits in SettingsView.swift.
///
/// It supplies the rows of a grouped Form section: `body` lists its views with no
/// wrapper, so the enclosing Section draws each one as its own row.
/// CaptureSettingsView owns the section's header and footer.
///
/// The view holds no list logic: add/remove/de-dupe are ClipdSettings' job, so the
/// stored list has exactly one owner.
struct ExcludedAppsView: View {
    @ObservedObject var settings: ClipdSettings

    var body: some View {
        if settings.excludedSourceApps.isEmpty {
            Text("No apps excluded")
                .foregroundStyle(.secondary)
        }
        ForEach(settings.excludedSourceApps, id: \.self) { bundleID in
            // Removal is trivially reversible (re-add via the picker), so it
            // needs no confirmation — unlike deleting a pinned entry.
            ExcludedAppRow(bundleID: bundleID) { settings.removeExcludedApp(bundleID) }
        }
        HStack {
            Spacer()
            Button("Add App…", action: addApp)
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
}

/// One row: the app's icon, its display name over its bundle id, and a remove
/// button. An app that isn't installed (or was since removed) shows only its
/// bundle id beside the generic app icon, so the rule stays readable and the user
/// can still keep or delete it.
private struct ExcludedAppRow: View {
    let bundleID: String
    let onRemove: () -> Void

    var body: some View {
        let name = clipdAppDisplayName(bundleID: bundleID)
        HStack(spacing: 8) {
            Image(nsImage: clipdAppIcon(bundleID: bundleID))
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)  // the name beside it says the same thing
            VStack(alignment: .leading, spacing: 1) {
                Text(name ?? bundleID)
                if name != nil {
                    Text(bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(name ?? bundleID)")
        }
    }
}

/// "com.apple.Passwords" → "Passwords", or nil when the app can't be resolved.
func clipdAppDisplayName(bundleID: String) -> String? {
    guard let url = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: bundleID) else { return nil }
    return FileManager.default.displayName(atPath: url.path)
}

/// The app's Finder icon, or the generic app icon when it can't be resolved — so
/// a rule for an uninstalled app still gets a row that lines up with the rest.
func clipdAppIcon(bundleID: String) -> NSImage {
    guard let url = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: bundleID) else {
        return NSWorkspace.shared.icon(for: .application)
    }
    return NSWorkspace.shared.icon(forFile: url.path)
}
